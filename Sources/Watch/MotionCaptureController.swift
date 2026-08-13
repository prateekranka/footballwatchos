import Combine
import CoreMotion
import Foundation

struct MotionStreamMetrics: Sendable, Equatable {
    let reportedHz: Double?
    let sampleCount: Int
    let batchCount: Int
    let maxGap: TimeInterval
    let lastError: String?

    static let empty = MotionStreamMetrics(
        reportedHz: nil,
        sampleCount: 0,
        batchCount: 0,
        maxGap: 0,
        lastError: nil
    )
}

struct MotionCaptureSnapshot: Sendable, Equatable {
    let sourceLabel: String
    let sourceDetail: String
    let accelerometer: MotionStreamMetrics
    let deviceMotion: MotionStreamMetrics

    var reportedAccelerometerHz: Double? { accelerometer.reportedHz }
    var reportedDeviceMotionHz: Double? { deviceMotion.reportedHz }

    static let idle = MotionCaptureSnapshot(
        sourceLabel: "Motion capture idle",
        sourceDetail: "No diagnostic stream is running.",
        accelerometer: .empty,
        deviceMotion: .empty
    )
}

struct MotionCapturePlan: Sendable, Equatable {
    let source: MotionCaptureSourceV1
    let accelerometerAvailability: StreamAvailabilityV1
    let deviceMotionAvailability: StreamAvailabilityV1
    let sourceLabel: String
    let sourceDetail: String
}

struct MotionCaptureDrainResult: Sendable, Equatable {
    let snapshot: MotionCaptureSnapshot
    let diagnostics: CaptureDiagnosticsV1
    let storageFailure: String?
}

enum MotionCaptureRuntimeMode: Sendable, Equatable {
    case fullSensors
    case healthKitOnly
}

private enum MotionPersistenceEvent: Sendable {
    case accelerometer(AccelerometerBatchV1)
    case deviceMotion(DeviceMotionBatchV1)
}

/// A continuation can accept a bounded batch directly on Core Motion's queue.
/// One consumer task serializes writer calls, avoiding one task per sample.
private final class MotionPackageIngress: @unchecked Sendable {
    private let continuation: AsyncStream<MotionPersistenceEvent>.Continuation
    private let failureBox: MotionStorageFailureBox

    init(
        writer: SessionPackageWriter,
        failureBox: MotionStorageFailureBox
    ) {
        self.failureBox = failureBox
        let pair = AsyncStream<MotionPersistenceEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        continuation = pair.continuation
        Task {
            for await event in pair.stream {
                do {
                    switch event {
                    case .accelerometer(let batch):
                        try await writer.appendAccelerometerBatch(batch)
                    case .deviceMotion(let batch):
                        try await writer.appendDeviceMotionBatch(batch)
                    }
                } catch {
                    failureBox.record(error.localizedDescription)
                }
            }
            do {
                try await writer.synchronizeNow()
            } catch {
                failureBox.record(error.localizedDescription)
            }
            failureBox.finish()
        }
    }

    func yield(_ event: MotionPersistenceEvent) {
        guard case .enqueued = continuation.yield(event) else {
            // A dropped event is still a capture-quality failure even though it
            // is not a file-system error; it prevents a full-capture claim.
            failureBox.record("Bounded motion persistence buffer dropped a batch.")
            return
        }
    }

    func finish() {
        continuation.finish()
    }
}

/// `AsyncStream` does not expose its consumer task. This small locked box lets
/// stop await the completion signal without handing reference-type CM objects
/// across an actor boundary.
private final class MotionStorageFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: String?
    private var isFinished = false
    private var waiters: [CheckedContinuation<String?, Never>] = []

    func record(_ message: String) {
        lock.lock()
        if failure == nil {
            failure = message
        }
        lock.unlock()
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let failure = failure
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: failure) }
    }

    func waitForFinish() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                let failure = failure
                lock.unlock()
                continuation.resume(returning: failure)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// Collects foreground fallback samples on the serial Core Motion callback
/// queue. It emits at most one persisted batch for every 50 samples rather
/// than scheduling a Task for every 50 Hz callback.
private final class FallbackBatchBuffer<Sample: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumSampleCount: Int
    private var samples: [Sample] = []

    init(maximumSampleCount: Int = 50) {
        self.maximumSampleCount = maximumSampleCount
        samples.reserveCapacity(maximumSampleCount)
    }

    func append(_ sample: Sample) -> [Sample]? {
        lock.lock()
        samples.append(sample)
        defer { lock.unlock() }
        guard samples.count >= maximumSampleCount else { return nil }
        let fullBatch = samples
        samples.removeAll(keepingCapacity: true)
        return fullBatch
    }

    func drain() -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        let remaining = samples
        samples.removeAll(keepingCapacity: true)
        return remaining
    }
}

/// A broken foreground stream can call back repeatedly with no sample. Report
/// its diagnostic once instead of creating an unbounded series of actor hops.
private final class FallbackErrorGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didReport = false

    func takeFirst(_ errorDescription: String?) -> String? {
        guard let errorDescription else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard !didReport else { return nil }
        didReport = true
        return errorDescription
    }
}

@MainActor
final class MotionCaptureController: ObservableObject {
    @Published private(set) var snapshot: MotionCaptureSnapshot = .idle

    private let runtimeMode: MotionCaptureRuntimeMode

    private let fallbackMotionManager = CMMotionManager()
    private let fallbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.prateekranka.footballperformance.motion-fallback"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private var batchedSensorManager: CMBatchedSensorManager?
    private var captureID = UUID()
    private var accelerometerState = StreamState()
    private var deviceMotionState = StreamState()
    private var plan: MotionCapturePlan?
    private var ingress: MotionPackageIngress?
    private var failureBox: MotionStorageFailureBox?
    private var fallbackAccelerometerBuffer = FallbackBatchBuffer<AccelerometerSampleV1>()
    private var fallbackDeviceMotionBuffer = FallbackBatchBuffer<DeviceMotionSampleV1>()
    private var fallbackAccelerometerErrorGate = FallbackErrorGate()
    private var fallbackDeviceMotionErrorGate = FallbackErrorGate()

    init(runtimeMode: MotionCaptureRuntimeMode = .fullSensors) {
        self.runtimeMode = runtimeMode
    }

    func makeCapturePlan() -> MotionCapturePlan {
        if runtimeMode == .healthKitOnly {
            return MotionCapturePlan(
                source: .unavailable(reason: .serviceUnavailable),
                accelerometerAvailability: .unavailable(reason: .serviceUnavailable),
                deviceMotionAvailability: .unavailable(reason: .serviceUnavailable),
                sourceLabel: "HealthKit-only safe mode",
                sourceDetail: "Wrist motion is paused while start-crash diagnostics run. Heart rate and GPS distance still record."
            )
        }

        if CMBatchedSensorManager.isAccelerometerSupported,
           CMBatchedSensorManager.isDeviceMotionSupported {
            return MotionCapturePlan(
                source: .batchedCoreMotion,
                accelerometerAvailability: .available,
                deviceMotionAvailability: .available,
                sourceLabel: "Batched Core Motion",
                sourceDetail: "Batched accelerometer and device-motion samples are retained in the private package."
            )
        }

        let accelerometerAvailability: StreamAvailabilityV1 = fallbackMotionManager.isAccelerometerAvailable
            ? .available
            : .unavailable(reason: .hardwareUnsupported)
        let deviceMotionAvailability: StreamAvailabilityV1 = fallbackMotionManager.isDeviceMotionAvailable
            ? .available
            : .unavailable(reason: .hardwareUnsupported)
        let source: MotionCaptureSourceV1 = fallbackMotionManager.isAccelerometerAvailable
            || fallbackMotionManager.isDeviceMotionAvailable
            ? .foregroundFallback
            : .unavailable(reason: .hardwareUnsupported)
        return MotionCapturePlan(
            source: source,
            accelerometerAvailability: accelerometerAvailability,
            deviceMotionAvailability: deviceMotionAvailability,
            sourceLabel: source == .foregroundFallback
                ? "Foreground diagnostic fallback"
                : "Motion capture unavailable",
            sourceDetail: source == .foregroundFallback
                ? "50 Hz foreground diagnostic fallback; it is not a background capture guarantee."
                : "This Watch does not provide a supported motion capture path."
        )
    }

    func start(writer: SessionPackageWriter, plan: MotionCapturePlan) {
        stopActiveStreams()
        let captureID = UUID()
        self.captureID = captureID
        self.plan = plan
        accelerometerState = StreamState(initialAvailability: plan.accelerometerAvailability)
        deviceMotionState = StreamState(initialAvailability: plan.deviceMotionAvailability)
        fallbackAccelerometerBuffer = FallbackBatchBuffer()
        fallbackDeviceMotionBuffer = FallbackBatchBuffer()
        fallbackAccelerometerErrorGate = FallbackErrorGate()
        fallbackDeviceMotionErrorGate = FallbackErrorGate()

        let failureBox = MotionStorageFailureBox()
        self.failureBox = failureBox
        ingress = MotionPackageIngress(writer: writer, failureBox: failureBox)
        publishSnapshot()
        WatchLog.motion.info("start: plan source \(String(describing: plan.source), privacy: .public)")

        switch plan.source {
        case .batchedCoreMotion:
            startBatchedCapture(captureID: captureID)
        case .foregroundFallback:
            startForegroundDiagnosticFallback(captureID: captureID)
        case .unavailable:
            break
        }
    }

    /// Stops hardware delivery, flushes every locally buffered fallback sample,
    /// then waits for the single persistence consumer to synchronize the writer.
    func stopAndDrain() async -> MotionCaptureDrainResult {
        let activeID = captureID
        stopActiveStreams()

        if let plan, plan.source == .foregroundFallback {
            let accelerometerSamples = fallbackAccelerometerBuffer.drain()
            if !accelerometerSamples.isEmpty {
                receiveAccelerometerBatch(
                    accelerometerSamples,
                    reportedHz: 50,
                    errorDescription: nil,
                    captureID: activeID,
                    source: .foregroundFallback
                )
            }
            let deviceMotionSamples = fallbackDeviceMotionBuffer.drain()
            if !deviceMotionSamples.isEmpty {
                receiveDeviceMotionBatch(
                    deviceMotionSamples,
                    reportedHz: 50,
                    errorDescription: nil,
                    captureID: activeID,
                    source: .foregroundFallback
                )
            }
        }

        captureID = UUID()
        ingress?.finish()
        let storageFailure = await failureBox?.waitForFinish()
        let diagnostics = makeDiagnostics()
        let result = MotionCaptureDrainResult(
            snapshot: snapshot,
            diagnostics: diagnostics,
            storageFailure: storageFailure
        )
        ingress = nil
        failureBox = nil
        return result
    }

    func stop() {
        captureID = UUID()
        stopActiveStreams()
        ingress?.finish()
        ingress = nil
        failureBox = nil
    }

    private func startBatchedCapture(captureID: UUID) {
        let manager = CMBatchedSensorManager()
        batchedSensorManager = manager

        manager.startAccelerometerUpdates { [weak self, weak manager] samples, error in
            let mappedSamples = (samples ?? []).map { sample in
                AccelerometerSampleV1(
                    timestamp: sample.timestamp,
                    acceleration: Vector3V1(
                        x: sample.acceleration.x,
                        y: sample.acceleration.y,
                        z: sample.acceleration.z
                    )
                )
            }
            let errorDescription = error?.localizedDescription
            let frequency = manager?.accelerometerDataFrequency
            let reportedHz = frequency.flatMap { $0 > 0 ? Double($0) : nil }
            Task { @MainActor [weak self] in
                self?.receiveAccelerometerBatch(
                    mappedSamples,
                    reportedHz: reportedHz,
                    errorDescription: errorDescription,
                    captureID: captureID,
                    source: .batchedCoreMotion
                )
            }
        }

        manager.startDeviceMotionUpdates { [weak self, weak manager] samples, error in
            let mappedSamples = (samples ?? []).map { sample in
                DeviceMotionSampleV1(
                    timestamp: sample.timestamp,
                    userAcceleration: Vector3V1(
                        x: sample.userAcceleration.x,
                        y: sample.userAcceleration.y,
                        z: sample.userAcceleration.z
                    ),
                    gravity: Vector3V1(
                        x: sample.gravity.x,
                        y: sample.gravity.y,
                        z: sample.gravity.z
                    ),
                    rotationRate: Vector3V1(
                        x: sample.rotationRate.x,
                        y: sample.rotationRate.y,
                        z: sample.rotationRate.z
                    )
                )
            }
            let errorDescription = error?.localizedDescription
            let frequency = manager?.deviceMotionDataFrequency
            let reportedHz = frequency.flatMap { $0 > 0 ? Double($0) : nil }
            Task { @MainActor [weak self] in
                self?.receiveDeviceMotionBatch(
                    mappedSamples,
                    reportedHz: reportedHz,
                    errorDescription: errorDescription,
                    captureID: captureID,
                    source: .batchedCoreMotion
                )
            }
        }
    }

    private func startForegroundDiagnosticFallback(captureID: UUID) {
        let requestedHz = 50.0
        let updateInterval = 1.0 / requestedHz
        fallbackMotionManager.accelerometerUpdateInterval = updateInterval
        fallbackMotionManager.deviceMotionUpdateInterval = updateInterval

        if fallbackMotionManager.isAccelerometerAvailable {
            fallbackMotionManager.startAccelerometerUpdates(to: fallbackQueue) { [weak self] sample, error in
                let mappedSample = sample.map {
                    AccelerometerSampleV1(
                        timestamp: $0.timestamp,
                        acceleration: Vector3V1(
                            x: $0.acceleration.x,
                            y: $0.acceleration.y,
                            z: $0.acceleration.z
                        )
                    )
                }
                let errorDescription = error?.localizedDescription
                guard let mappedSample else {
                    if let firstError = self?.fallbackAccelerometerErrorGate.takeFirst(errorDescription) {
                        Task { @MainActor [weak self] in
                            self?.receiveAccelerometerBatch(
                                [],
                                reportedHz: requestedHz,
                                errorDescription: firstError,
                                captureID: captureID,
                                source: .foregroundFallback
                            )
                        }
                    }
                    return
                }

                guard let batch = self?.fallbackAccelerometerBuffer.append(mappedSample) else { return }
                Task { @MainActor [weak self] in
                    self?.receiveAccelerometerBatch(
                        batch,
                        reportedHz: requestedHz,
                        errorDescription: errorDescription,
                        captureID: captureID,
                        source: .foregroundFallback
                    )
                }
            }
        } else {
            accelerometerState.record(
                timestamps: [],
                reportedHz: nil,
                errorDescription: "Accelerometer is unavailable for the foreground diagnostic fallback.",
                countsAsBatch: false
            )
        }

        if fallbackMotionManager.isDeviceMotionAvailable {
            fallbackMotionManager.startDeviceMotionUpdates(to: fallbackQueue) { [weak self] sample, error in
                let mappedSample = sample.map {
                    DeviceMotionSampleV1(
                        timestamp: $0.timestamp,
                        userAcceleration: Vector3V1(
                            x: $0.userAcceleration.x,
                            y: $0.userAcceleration.y,
                            z: $0.userAcceleration.z
                        ),
                        gravity: Vector3V1(
                            x: $0.gravity.x,
                            y: $0.gravity.y,
                            z: $0.gravity.z
                        ),
                        rotationRate: Vector3V1(
                            x: $0.rotationRate.x,
                            y: $0.rotationRate.y,
                            z: $0.rotationRate.z
                        )
                    )
                }
                let errorDescription = error?.localizedDescription
                guard let mappedSample else {
                    if let firstError = self?.fallbackDeviceMotionErrorGate.takeFirst(errorDescription) {
                        Task { @MainActor [weak self] in
                            self?.receiveDeviceMotionBatch(
                                [],
                                reportedHz: requestedHz,
                                errorDescription: firstError,
                                captureID: captureID,
                                source: .foregroundFallback
                            )
                        }
                    }
                    return
                }

                guard let batch = self?.fallbackDeviceMotionBuffer.append(mappedSample) else { return }
                Task { @MainActor [weak self] in
                    self?.receiveDeviceMotionBatch(
                        batch,
                        reportedHz: requestedHz,
                        errorDescription: errorDescription,
                        captureID: captureID,
                        source: .foregroundFallback
                    )
                }
            }
        } else {
            deviceMotionState.record(
                timestamps: [],
                reportedHz: nil,
                errorDescription: "Device motion is unavailable for the foreground diagnostic fallback.",
                countsAsBatch: false
            )
        }
        publishSnapshot()
    }

    private func stopActiveStreams() {
        batchedSensorManager?.stopAccelerometerUpdates()
        batchedSensorManager?.stopDeviceMotionUpdates()
        batchedSensorManager = nil
        fallbackMotionManager.stopAccelerometerUpdates()
        fallbackMotionManager.stopDeviceMotionUpdates()
    }

    private func receiveAccelerometerBatch(
        _ samples: [AccelerometerSampleV1],
        reportedHz: Double?,
        errorDescription: String?,
        captureID: UUID,
        source: MotionCaptureSourceV1
    ) {
        guard captureID == self.captureID else { return }
        accelerometerState.record(
            timestamps: samples.map(\.timestamp),
            reportedHz: reportedHz,
            errorDescription: errorDescription,
            countsAsBatch: true
        )
        if !samples.isEmpty {
            ingress?.yield(.accelerometer(AccelerometerBatchV1(source: source, samples: samples)))
        }
        publishSnapshot()
    }

    private func receiveDeviceMotionBatch(
        _ samples: [DeviceMotionSampleV1],
        reportedHz: Double?,
        errorDescription: String?,
        captureID: UUID,
        source: MotionCaptureSourceV1
    ) {
        guard captureID == self.captureID else { return }
        deviceMotionState.record(
            timestamps: samples.map(\.timestamp),
            reportedHz: reportedHz,
            errorDescription: errorDescription,
            countsAsBatch: true
        )
        if !samples.isEmpty {
            ingress?.yield(.deviceMotion(DeviceMotionBatchV1(source: source, samples: samples)))
        }
        publishSnapshot()
    }

    private func makeDiagnostics() -> CaptureDiagnosticsV1 {
        let accelerometer = accelerometerState.metrics
        let deviceMotion = deviceMotionState.metrics
        let combinedGap = max(accelerometer.maxGap, deviceMotion.maxGap)
        return CaptureDiagnosticsV1(
            recordedAt: Date(),
            source: plan?.source ?? .unavailable(reason: .captureNotStarted),
            accelerometerAvailability: accelerometerState.finalAvailability,
            deviceMotionAvailability: deviceMotionState.finalAvailability,
            accelerometerSampleCount: accelerometerState.sampleCount,
            deviceMotionSampleCount: deviceMotionState.sampleCount,
            accelerometerReportedHz: accelerometer.reportedHz,
            deviceMotionReportedHz: deviceMotion.reportedHz,
            accelerometerBatchCount: accelerometer.batchCount,
            deviceMotionBatchCount: deviceMotion.batchCount,
            accelerometerLastError: accelerometer.lastError,
            deviceMotionLastError: deviceMotion.lastError,
            maximumObservedGap: combinedGap > 0 ? combinedGap : nil
        )
    }

    private func publishSnapshot() {
        snapshot = MotionCaptureSnapshot(
            sourceLabel: plan?.sourceLabel ?? MotionCaptureSnapshot.idle.sourceLabel,
            sourceDetail: plan?.sourceDetail ?? MotionCaptureSnapshot.idle.sourceDetail,
            accelerometer: accelerometerState.metrics,
            deviceMotion: deviceMotionState.metrics
        )
    }
}

private struct StreamState {
    private(set) var availability: StreamAvailabilityV1
    private(set) var reportedHz: Double?
    private(set) var sampleCount = 0
    private(set) var batchCount = 0
    private(set) var maxGap: TimeInterval = 0
    private(set) var lastTimestamp: TimeInterval?
    private(set) var lastError: String?

    init(initialAvailability: StreamAvailabilityV1 = .unavailable(reason: .captureNotStarted)) {
        self.availability = initialAvailability
    }

    var metrics: MotionStreamMetrics {
        MotionStreamMetrics(
            reportedHz: reportedHz,
            sampleCount: sampleCount,
            batchCount: batchCount,
            maxGap: maxGap,
            lastError: lastError
        )
    }

    var finalAvailability: StreamAvailabilityV1 {
        guard case .available = availability, sampleCount == 0 else { return availability }
        return .insufficient(reason: .noSamples)
    }

    mutating func record(
        timestamps: [TimeInterval],
        reportedHz: Double?,
        errorDescription: String?,
        countsAsBatch: Bool
    ) {
        if let reportedHz {
            self.reportedHz = reportedHz
        }
        if let errorDescription {
            lastError = errorDescription
            availability = .unavailable(reason: .sourceError)
        }
        if countsAsBatch {
            batchCount += 1
        }

        for timestamp in timestamps {
            if let lastTimestamp, timestamp >= lastTimestamp {
                maxGap = max(maxGap, timestamp - lastTimestamp)
            }
            self.lastTimestamp = timestamp
            sampleCount += 1
        }
    }
}
