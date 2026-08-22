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

enum MotionPersistenceEvent: Sendable {
    case accelerometer(AccelerometerBatchV1)
    case deviceMotion(DeviceMotionBatchV1)
}

/// `AsyncStream` does not expose its consumer task. This small locked box lets
/// stop await the completion signal without handing reference-type CM objects
/// across an actor boundary.
final class MotionStorageFailureBox: @unchecked Sendable {
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

/// Serializes motion package writes for one capture.
///
/// b14 post-mortem: the previous consumer (`Task { for await … }`) was created
/// inside a `@MainActor`-reachable initializer, so the task inherited the main
/// actor. Every one of ~100 deliveries per second then executed plist
/// encoding, SHA-256 hashing, and file writes on the main thread, and the
/// process trapped (EXC_BREAKPOINT on CoreMotion's delivery queue) nine
/// seconds after Start. This version creates the consumer with
/// `Task.detached`, so no part of the persistence path ever lands on the main
/// actor. The writer remains an actor, preserving single-writer exclusivity
/// with the heart-rate/distance paths in `WorkoutRecorder`.
///
/// Contract:
/// - `yield(_:)` is thread-safe and never blocks Core Motion's callback queue.
/// - Events persist strictly in yield order (single FIFO consumer).
/// - Overflow of the bounded stream buffer records a quality failure instead
///   of growing without bound.
/// - `finish()` ends intake; the consumer synchronizes the writer exactly once
///   and then signals `failureBox`, so sealing waits for durability.
final class MotionPackageIngress: @unchecked Sendable {
    private let continuation: AsyncStream<MotionPersistenceEvent>.Continuation
    private let failureBox: MotionStorageFailureBox

    init(
        writer: SessionPackageWriter,
        failureBox: MotionStorageFailureBox,
        bufferingLimit: Int = 128
    ) {
        self.failureBox = failureBox
        let pair = AsyncStream<MotionPersistenceEvent>.makeStream(
            of: MotionPersistenceEvent.self,
            bufferingPolicy: .bufferingNewest(bufferingLimit)
        )
        continuation = pair.continuation

        // Detached on purpose: an inheriting task would adopt the caller's
        // main-actor isolation and repeat the b14 crash. The writer actor
        // serializes the actual writes; this loop adds no concurrency of its
        // own beyond waiting on the stream.
        Task.detached(priority: .utility) { [failureBox] in
            for await event in pair.stream {
                do {
                    switch event {
                    case .accelerometer(let batch):
                        try await writer.appendAccelerometerBatch(batch)
                    case .deviceMotion(let batch):
                        try await writer.appendDeviceMotionBatch(batch)
                    }
                } catch {
                    // First failure wins; later failures cannot undo it.
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

    /// Called from sensor callback queues. Never blocks the caller.
    func yield(_ event: MotionPersistenceEvent) {
        guard case .enqueued = continuation.yield(event) else {
            // A dropped event is a capture-quality failure even though it is
            // not a file-system error; it prevents a full-capture claim.
            failureBox.record("Bounded motion persistence buffer dropped a batch.")
            return
        }
    }

    func finish() {
        continuation.finish()
    }
}

/// Lock-protected per-stream delivery statistics. Sensor callbacks mutate on
/// Core Motion queues; the main actor reads copies for snapshots and final
/// diagnostics.
final class MotionStreamStatsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stats = MotionDeliveryStats()

    func record(
        timestamps: [TimeInterval],
        reportedHz: Double?,
        errorDescription: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        stats.record(
            timestamps: timestamps,
            reportedHz: reportedHz,
            errorDescription: errorDescription
        )
    }

    func currentMetrics() -> MotionStreamMetrics {
        lock.lock()
        defer { lock.unlock() }
        return stats.asMetrics
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stats.sampleCount
    }

    var maxGap: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return stats.maxGap
    }

    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return stats.lastError
    }

    var reportedHz: Double? {
        lock.lock()
        defer { lock.unlock() }
        return stats.reportedHz
    }
}

struct MotionDeliveryStats {
    private(set) var reportedHz: Double?
    private(set) var sampleCount = 0
    private(set) var batchCount = 0
    private(set) var maxGap: TimeInterval = 0
    private(set) var lastError: String?

    mutating func record(
        timestamps: [TimeInterval],
        reportedHz: Double?,
        errorDescription: String?
    ) {
        if let reportedHz {
            self.reportedHz = reportedHz
        }
        if let errorDescription {
            lastError = errorDescription
        }
        batchCount += 1
        for timestamp in timestamps {
            if let lastTimestamp, timestamp >= lastTimestamp {
                maxGap = max(maxGap, timestamp - lastTimestamp)
            }
            self.lastTimestamp = timestamp
            sampleCount += 1
        }
    }

    private var lastTimestamp: TimeInterval?

    var asMetrics: MotionStreamMetrics {
        MotionStreamMetrics(
            reportedHz: reportedHz,
            sampleCount: sampleCount,
            batchCount: batchCount,
            maxGap: maxGap,
            lastError: lastError
        )
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
    private let accelerometerStats = MotionStreamStatsBox()
    private let deviceMotionStats = MotionStreamStatsBox()
    private var plan: MotionCapturePlan?
    private var ingress: MotionPackageIngress?
    private var failureBox: MotionStorageFailureBox?
    private var fallbackAccelerometerBuffer = FallbackBatchBuffer<AccelerometerSampleV1>()
    private var fallbackDeviceMotionBuffer = FallbackBatchBuffer<DeviceMotionSampleV1>()
    private var fallbackAccelerometerErrorGate = FallbackErrorGate()
    private var fallbackDeviceMotionErrorGate = FallbackErrorGate()
    private var snapshotRefreshTimer: Timer?

    init() {}

    func makeCapturePlan() -> MotionCapturePlan {
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
        stopSnapshotTimer()
        let captureID = UUID()
        self.captureID = captureID
        self.plan = plan
        accelerometerStats.reset()
        deviceMotionStats.reset()
        fallbackAccelerometerBuffer = FallbackBatchBuffer()
        fallbackDeviceMotionBuffer = FallbackBatchBuffer()
        fallbackAccelerometerErrorGate = FallbackErrorGate()
        fallbackDeviceMotionErrorGate = FallbackErrorGate()

        let failureBox = MotionStorageFailureBox()
        self.failureBox = failureBox
        ingress = MotionPackageIngress(writer: writer, failureBox: failureBox)

        // UI refreshes on a 2 Hz timer instead of per delivery. Sensor traffic
        // never publishes to the main actor directly.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishSnapshotFromStats()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapshotRefreshTimer = timer
        publishSnapshotFromStats()
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
        stopSnapshotTimer()
        publishSnapshotFromStats()
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
        stopSnapshotTimer()
        ingress?.finish()
        ingress = nil
        failureBox = nil
    }

    // MARK: - Batched Core Motion
    //
    // Hot-path rules (learned from the b14 crash):
    // 1. The handler does exactly three things: map, record stats, yield to
    //    the ingress. Everything expensive happens elsewhere.
    // 2. Manager properties are read once at start, never inside the handler;
    //    touching a CMBatchedSensorManager from its own data-delivery queue is
    //    not documented as safe, so the handlers capture plain values only.
    // 3. No Task creation and no main-actor hops per delivery.

    private func startBatchedCapture(captureID: UUID) {
        let manager = CMBatchedSensorManager()
        batchedSensorManager = manager
        let ingress = ingress
        let accelerometerStats = self.accelerometerStats
        let deviceMotionStats = self.deviceMotionStats
        let accelerometerHz = Double(manager.accelerometerDataFrequency)
        let deviceMotionHz = Double(manager.deviceMotionDataFrequency)

        _ = captureID // Streams are stopped via stopActiveStreams(); late events after stop carry no state.

        manager.startAccelerometerUpdates { samples, error in
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
            accelerometerStats.record(
                timestamps: mappedSamples.map(\.timestamp),
                reportedHz: accelerometerHz > 0 ? accelerometerHz : nil,
                errorDescription: errorDescription
            )
            if !mappedSamples.isEmpty {
                ingress?.yield(.accelerometer(
                    AccelerometerBatchV1(source: .batchedCoreMotion, samples: mappedSamples)
                ))
            }
        }

        manager.startDeviceMotionUpdates { samples, error in
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
            deviceMotionStats.record(
                timestamps: mappedSamples.map(\.timestamp),
                reportedHz: deviceMotionHz > 0 ? deviceMotionHz : nil,
                errorDescription: errorDescription
            )
            if !mappedSamples.isEmpty {
                ingress?.yield(.deviceMotion(
                    DeviceMotionBatchV1(source: .batchedCoreMotion, samples: mappedSamples)
                ))
            }
        }
    }

    // MARK: - Foreground diagnostic fallback (simulator-only path)

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
            accelerometerStats.record(
                timestamps: [],
                reportedHz: nil,
                errorDescription: "Accelerometer is unavailable for the foreground diagnostic fallback."
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
            deviceMotionStats.record(
                timestamps: [],
                reportedHz: nil,
                errorDescription: "Device motion is unavailable for the foreground diagnostic fallback."
            )
        }
        publishSnapshotFromStats()
    }

    // MARK: - Shared receive path (fallback batches arrive on the main actor)

    private func receiveAccelerometerBatch(
        _ samples: [AccelerometerSampleV1],
        reportedHz: Double?,
        errorDescription: String?,
        captureID: UUID,
        source: MotionCaptureSourceV1
    ) {
        guard captureID == self.captureID else { return }
        accelerometerStats.record(
            timestamps: samples.map(\.timestamp),
            reportedHz: reportedHz,
            errorDescription: errorDescription
        )
        if !samples.isEmpty {
            ingress?.yield(.accelerometer(AccelerometerBatchV1(source: source, samples: samples)))
        }
    }

    private func receiveDeviceMotionBatch(
        _ samples: [DeviceMotionSampleV1],
        reportedHz: Double?,
        errorDescription: String?,
        captureID: UUID,
        source: MotionCaptureSourceV1
    ) {
        guard captureID == self.captureID else { return }
        deviceMotionStats.record(
            timestamps: samples.map(\.timestamp),
            reportedHz: reportedHz,
            errorDescription: errorDescription
        )
        if !samples.isEmpty {
            ingress?.yield(.deviceMotion(DeviceMotionBatchV1(source: source, samples: samples)))
        }
    }

    // MARK: - Diagnostics and snapshots

    private func makeDiagnostics() -> CaptureDiagnosticsV1 {
        func availability(
            planned: StreamAvailabilityV1?,
            metrics: MotionStreamMetrics
        ) -> StreamAvailabilityV1 {
            if metrics.lastError != nil {
                return .unavailable(reason: .sourceError)
            }
            switch planned {
            case .available where metrics.sampleCount == 0:
                return .insufficient(reason: .noSamples)
            case .some(let value):
                return value
            case nil:
                return .unavailable(reason: .captureNotStarted)
            }
        }

        let accelerometer = accelerometerStats.currentMetrics()
        let deviceMotion = deviceMotionStats.currentMetrics()
        let combinedGap = max(accelerometer.maxGap, deviceMotion.maxGap)
        return CaptureDiagnosticsV1(
            recordedAt: Date(),
            source: plan?.source ?? .unavailable(reason: .captureNotStarted),
            accelerometerAvailability: availability(
                planned: plan?.accelerometerAvailability,
                metrics: accelerometer
            ),
            deviceMotionAvailability: availability(
                planned: plan?.deviceMotionAvailability,
                metrics: deviceMotion
            ),
            accelerometerSampleCount: accelerometer.sampleCount,
            deviceMotionSampleCount: deviceMotion.sampleCount,
            accelerometerReportedHz: accelerometer.reportedHz,
            deviceMotionReportedHz: deviceMotion.reportedHz,
            accelerometerBatchCount: accelerometer.batchCount,
            deviceMotionBatchCount: deviceMotion.batchCount,
            accelerometerLastError: accelerometer.lastError,
            deviceMotionLastError: deviceMotion.lastError,
            maximumObservedGap: combinedGap > 0 ? combinedGap : nil
        )
    }

    private func publishSnapshotFromStats() {
        snapshot = MotionCaptureSnapshot(
            sourceLabel: plan?.sourceLabel ?? MotionCaptureSnapshot.idle.sourceLabel,
            sourceDetail: plan?.sourceDetail ?? MotionCaptureSnapshot.idle.sourceDetail,
            accelerometer: accelerometerStats.currentMetrics(),
            deviceMotion: deviceMotionStats.currentMetrics()
        )
    }

    private func stopSnapshotTimer() {
        snapshotRefreshTimer?.invalidate()
        snapshotRefreshTimer = nil
    }

    private func stopActiveStreams() {
        batchedSensorManager?.stopAccelerometerUpdates()
        batchedSensorManager?.stopDeviceMotionUpdates()
        batchedSensorManager = nil
        fallbackMotionManager.stopAccelerometerUpdates()
        fallbackMotionManager.stopDeviceMotionUpdates()
    }
}

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

extension MotionStreamStatsBox {
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        stats = MotionDeliveryStats()
    }
}
