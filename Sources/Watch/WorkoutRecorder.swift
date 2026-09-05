import Combine
@preconcurrency import HealthKit
import Foundation
import WatchKit

struct FootballSessionSummary: Equatable, Sendable {
    let sessionID: UUID
    let transferKey: WatchTransferOutboxKeyV1?
    let duration: TimeInterval
    let distanceMeters: Double
    let averageHeartRate: Double?
    let motion: MotionCaptureSnapshot
    let healthKitSaveOutcome: HealthKitSaveOutcomeV1
    /// Non-nil means the private package sealed but it must not be described as
    /// a complete high-quality capture.
    let captureQualityError: String?
}

@MainActor
final class WorkoutRecorder: NSObject, ObservableObject {
    enum Phase: Equatable {
        case authorizing
        case idle
        case countdown(Int)
        case starting
        case active
        case finishing
        case saved(FootballSessionSummary)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .authorizing
    @Published private(set) var currentHeartRate: Double?
    @Published private(set) var distanceMeters: Double = 0
    @Published private(set) var averageHeartRate: Double?
    @Published private(set) var startedAt: Date?
    /// Current recovery/transfer aggregate backing the Session Recovery screen.
    /// Nil means the aggregate could not be read yet.
    @Published private(set) var recoveryAggregate: SessionRecoveryAggregateV1?
    /// Transient feedback from the last Recover Sessions run.
    @Published private(set) var recoveryMessage: String?
    /// Per-session log for the Session Recovery screen. Carries human-readable
    /// identity (start time + duration); never the opaque package filename.
    @Published private(set) var recoveryLog: [SessionRecoveryLogEntryV1] = []
    @Published private(set) var isRecovering = false

    let motionCapture = MotionCaptureController()
    let syncCoordinator: WatchSyncCoordinator
    private let diagnosticJournal: WatchDiagnosticJournal?

    private let healthStore = HKHealthStore()
    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!
    private let activeEnergyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!

    private var repository: WatchSessionRepository?
    private var packageWriter: SessionPackageWriter?
    private var sessionID: UUID?
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var countdownTask: Task<Void, Never>?
    private var metricTail: Task<Void, Never>?
    private var finishingWatchdogTask: Task<Void, Never>?
    let launchRecoverySync: LaunchRecoverySync
    private var didRequestAuthorization = false
    private var finishRequested = false
    private var storageQualityError: String?
    private var stateGenerationObservation: AnyCancellable?

    /// Draft sprint detection; thresholds are validated via Calibration Sessions.
    private let sprintDetector = SprintDetectorV1(threshold: SprintCalibrationStore.current())
    private var lastSprintFlush: Date?

    /// Upper bound on a legitimate seal: HealthKit end callbacks plus drain
    /// plus final flash writes complete well inside this on a healthy watch.
    static let finishingWatchdogTimeout: TimeInterval = 90

    init(
        syncCoordinator: WatchSyncCoordinator = .shared,
        diagnosticJournal: WatchDiagnosticJournal? = WatchDiagnosticRuntime.shared.journal,
        launchRecoverySync: LaunchRecoverySync? = nil
    ) {
        self.syncCoordinator = syncCoordinator
        self.diagnosticJournal = diagnosticJournal
        self.launchRecoverySync = launchRecoverySync ?? LaunchRecoverySync.live()
        super.init()
        // Receipts, framework completions, and enqueues all bump the sync
        // coordinator's state generation. Refreshing here keeps the recovery
        // aggregate (and the home badge) truthful even while the Session
        // Recovery screen is not visible.
        stateGenerationObservation = syncCoordinator.$stateGeneration
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.refreshRecoveryAggregate()
                }
            }
    }

    /// Feeds raw motion magnitudes to the sprint detector. The controller
    /// fills `detectorMagnitudes` on its delivery queue; the recorder drains
    /// it here on the main actor at builder-update rate (1-5 Hz) so the
    /// detector stays main-actor-confined. Raw acceleration is
    /// gravity-subtracted (|a| − 9.81); device-motion userAcceleration is
    /// already gravity-free. The same batches are persisted to the package,
    /// so the raw streams remain available for later comparison.
    private func drainDetectorMagnitudes() {
        let magnitudes = motionCapture.detectorMagnitudes.drain()
        guard !magnitudes.isEmpty else { return }
        for value in magnitudes {
            sprintDetector.consumeAccelerationMagnitude(value.magnitude, at: value.timestamp)
        }
    }

    func prepare() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true

        do {
            let repository = try WatchSessionRepository()
            self.repository = repository
            WatchLog.recorder.info("prepare: WatchSessionRepository created")
            auditInterruptedPackages(repository)
        } catch {
            WatchLog.recorder.logError("prepare: repository init failed", error: error)
            phase = .failed("Private Watch storage could not start: \(error.localizedDescription)")
            return
        }

        guard HKHealthStore.isHealthDataAvailable() else {
            WatchLog.recorder.error("prepare: HealthKit unavailable on this Watch")
            phase = .failed("Health data is unavailable on this Watch.")
            return
        }

        phase = .authorizing
        let shareTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
        let readTypes: Set<HKObjectType> = [
            heartRateType,
            distanceType,
            activeEnergyType,
            HKObjectType.workoutType(),
        ]

        healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { [weak self] success, error in
            let failure = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    WatchLog.recorder.info("prepare: HealthKit authorization granted")
                    self.phase = .idle
                    self.startUIQAAutomationIfRequested()
                } else {
                    WatchLog.recorder.logError(
                        "prepare: HealthKit authorization denied",
                        error: error
                    )
                    self.phase = .failed(failure ?? "Health access was not granted.")
                }
            }
        }
    }

    /// Simulator QA hook, DEBUG builds only. `FP_UI_QA_AUTOSTART=1` begins
    /// the normal countdown without a tap so screenshots of the recording
    /// flow can be captured headlessly. `FP_UI_QA_AUTOFINISH_SECONDS`
    /// finishes an active session after that many seconds. Production
    /// devices never set these variables, and Release builds omit the code.
    #if DEBUG
    private func startUIQAAutomationIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FP_UI_QA_AUTOSTART"] == "1" else { return }
        WatchLog.recorder.info("ui-qa: autostart requested")
        startCountdown()
        if let finishAfter = environment["FP_UI_QA_AUTOFINISH_SECONDS"],
           let seconds = TimeInterval(finishAfter), seconds > 0 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, case .active = self.phase else { return }
                WatchLog.recorder.info("ui-qa: autofinish requested")
                self.finish()
            }
        }
    }
    #else
    private func startUIQAAutomationIfRequested() {}
    #endif

    func startCountdown() {
        guard phase == .idle else { return }
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.recordDiagnostic("countdown_started")
            WatchLog.recorder.info("countdown: started")

            for value in stride(from: 3, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                self.phase = .countdown(value)
                let tickStartedAt = ContinuousClock.now
                await self.recordDiagnostic("countdown_tick", detail: String(value))
                WKInterfaceDevice.current().play(.click)
                try? await Task.sleep(for: .seconds(1))
                let tickElapsed = tickStartedAt.duration(to: .now)
                WatchLog.capture(
                    WatchLog.recorder,
                    "countdown: tick \(value) took \(tickElapsed)"
                )
            }

            guard !Task.isCancelled else { return }
            await self.recordDiagnostic("countdown_completed")
            WatchLog.capture(WatchLog.recorder, "countdown: completed")
            await self.beginWorkout()
        }
    }

    func cancelCountdown() {
        guard case .countdown = phase else { return }
        countdownTask?.cancel()
        countdownTask = nil
        phase = .idle
    }

    func finish() {
        guard phase == .active, let builder, let session else { return }
        finishRequested = true
        phase = .finishing
        let endDate = Date()
        beginFinishingWatchdog()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.recordDiagnostic("finish_requested")
            let motionResult = await self.motionCapture.stopAndDrain()
            await self.metricTail?.value
            session.end()
            builder.endCollection(withEnd: endDate) { [weak self] success, error in
                let errorDescription = error?.localizedDescription
                Task { @MainActor [weak self] in
                    self?.handleEndCollection(
                        success: success,
                        errorDescription: errorDescription,
                        builder: builder,
                        endDate: endDate,
                        motionResult: motionResult
                    )
                }
            }
        }
    }

    func resetAfterResult() {
        guard case .saved = phase else { return }
        clearSessionState()
        phase = .idle
    }

    func retryAfterFailure() {
        guard case .failed = phase else { return }
        clearSessionState()
        didRequestAuthorization = false
        prepare()
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, date.timeIntervalSince(startedAt))
    }

    private func beginWorkout() async {
        guard let repository else {
            WatchLog.recorder.error("beginWorkout: repository is nil")
            phase = .failed("Private Watch storage is not ready.")
            return
        }
        await recordDiagnostic("start_attempt_created", armed: true)
        phase = .starting
        WatchLog.capture(WatchLog.recorder, "beginWorkout: start_attempt_created")

        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .soccer
        configuration.locationType = .outdoor
        await recordDiagnostic("workout_configuration_created")
        WatchLog.capture(WatchLog.recorder, "beginWorkout: configuration soccer/outdoor")

        do {
            let session = try HKWorkoutSession(
                healthStore: healthStore,
                configuration: configuration
            )
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self
            await recordDiagnostic("health_session_constructed")
            WatchLog.capture(WatchLog.recorder, "beginWorkout: HKWorkoutSession constructed")

            self.session = session
            self.builder = builder
            self.finishRequested = false
            self.storageQualityError = nil

            // The durable package is created BEFORE the workout session
            // starts. File creation and the initial synchronize are the only
            // blocking flash writes in the startup path; completing them
            // before startActivity means the session-start window never
            // contends with the user lowering their wrist and watchOS
            // suspending or terminating the app.
            let startDate = Date()
            await recordDiagnostic("package_writer_requested")
            logFreeCapacity(context: "before package writer")
            let sessionID = UUID()
            let motionPlan = motionCapture.makeCapturePlan()
            let envelope = SessionEnvelopeV1(
                sessionID: sessionID,
                createdAt: Date(),
                startedAt: startDate,
                captureSource: motionPlan.source,
                initialAccelerometerAvailability: motionPlan.accelerometerAvailability,
                initialDeviceMotionAvailability: motionPlan.deviceMotionAvailability
            )

            let writer: SessionPackageWriter
            do {
                writer = try await repository.startWriter(envelope: envelope)
            } catch {
                WatchLog.recorder.logError(
                    "beginWorkout: startWriter failed (session never started)",
                    error: error
                )
                await recordDiagnostic(
                    "package_writer_failed",
                    detail: Self.diagnosticErrorCode(error),
                    armed: false
                )
                session.end()
                fail("Private session storage could not start: \(error.localizedDescription)")
                return
            }
            self.packageWriter = writer
            self.sessionID = sessionID
            sprintDetector.reset()
            lastSprintFlush = nil
            await recordDiagnostic("package_writer_created")
            WatchLog.capture(WatchLog.recorder, "beginWorkout: package writer created")

            await recordDiagnostic("health_start_requested")
            session.startActivity(with: startDate)
            await recordDiagnostic("health_start_returned")
            WatchLog.capture(WatchLog.recorder, "beginWorkout: startActivity returned")
            await recordDiagnostic("builder_collection_requested")
            builder.beginCollection(withStart: startDate) { [weak self] success, error in
                let failure = error?.localizedDescription
                let diagnosticError = Self.diagnosticErrorCode(error)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard success else {
                        WatchLog.recorder.logError(
                            "beginWorkout: beginCollection failed",
                            error: error
                        )
                        await self.recordDiagnostic(
                            "builder_collection_failed",
                            detail: diagnosticError,
                            armed: false
                        )
                        session.end()
                        self.fail(failure ?? "The Watch could not start collecting workout data.")
                        return
                    }
                    await self.recordDiagnostic("builder_collection_succeeded")
                    WatchLog.capture(WatchLog.recorder, "beginWorkout: beginCollection succeeded")
                    await self.attachHealthMetadata(
                        builder: builder,
                        writer: writer,
                        motionPlan: motionPlan,
                        sessionID: sessionID,
                        startDate: startDate
                    )
                }
            }
        } catch {
            WatchLog.recorder.logError(
                "beginWorkout: HK session construction failed",
                error: error
            )
            await recordDiagnostic(
                "health_session_construction_failed",
                detail: Self.diagnosticErrorCode(error),
                armed: false
            )
            fail(error.localizedDescription)
        }
    }

    /// Logs how much free space the Watch has left, to distinguish a full-disk
    /// failure from a suspension kill.
    private func logFreeCapacity(context: String) {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let directory = applicationSupport.appendingPathComponent("FootballCapture", isDirectory: true)
        if let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: directory.path
        ),
        let free = attributes[.systemFreeSize] as? NSNumber {
            WatchLog.capture(
                WatchLog.recorder,
                "\(context): free capacity \(free.int64Value) bytes"
            )
        }
    }

    /// HealthKit metadata is attached after collection starts. The package
    /// writer already exists (created before `startActivity`), so this path
    /// performs no blocking file I/O.
    private func attachHealthMetadata(
        builder: HKLiveWorkoutBuilder,
        writer: SessionPackageWriter,
        motionPlan: MotionCapturePlan,
        sessionID: UUID,
        startDate: Date
    ) async {
        let metadata: [String: Any] = [
            "com.prateekranka.footballperformance.session-id": sessionID.uuidString,
            HKMetadataKeyExternalUUID: sessionID.uuidString,
        ]
        await recordDiagnostic("health_metadata_requested")
        builder.addMetadata(metadata) { [weak self] success, error in
            let errorDescription = error?.localizedDescription
            let diagnosticError = Self.diagnosticErrorCode(error)
            Task { @MainActor [weak self] in
                await self?.recordDiagnostic(
                    success ? "health_metadata_succeeded" : "health_metadata_failed",
                    detail: success ? nil : diagnosticError
                )
                await self?.activateDurableCapture(
                    writer: writer,
                    motionPlan: motionPlan,
                    startDate: startDate,
                    metadataError: success ? nil : (errorDescription ?? "HealthKit did not accept the session marker.")
                )
            }
        }
    }

    private func activateDurableCapture(
        writer: SessionPackageWriter,
        motionPlan: MotionCapturePlan,
        startDate: Date,
        metadataError: String?
    ) async {
        guard phase == .starting, packageWriter != nil else { return }
        if let metadataError {
            do {
                try await writer.appendQualityEvent(
                    CaptureQualityEventV1(
                        timestamp: Date(),
                        level: .warning,
                        code: "healthkit_session_marker_unavailable",
                        detail: metadataError
                    )
                )
            } catch {
                recordStorageQualityError(error.localizedDescription)
            }
        }

        startedAt = startDate
        await recordDiagnostic("active_phase_requested")
        phase = .active
        await recordDiagnostic("active_phase_entered")
        await recordDiagnostic("motion_start_requested")
        motionCapture.start(writer: writer, plan: motionPlan)
        await recordDiagnostic("motion_start_returned")
        await recordDiagnostic("start_haptic_requested")
        WKInterfaceDevice.current().play(.start)
        await recordDiagnostic("start_haptic_returned")
        await recordDiagnostic("active_ready")
    }

    private func handleEndCollection(
        success: Bool,
        errorDescription: String?,
        builder: HKLiveWorkoutBuilder,
        endDate: Date,
        motionResult: MotionCaptureDrainResult
    ) {
        guard success else {
            Task { @MainActor [weak self] in
                await self?.sealPackage(
                    builder: builder,
                    workout: nil,
                    endDate: endDate,
                    healthOutcome: .failed(message: errorDescription ?? "HealthKit could not end collection."),
                    motionResult: motionResult,
                    requestedLifecycle: .completed,
                    additionalQualityError: nil
                )
            }
            return
        }

        builder.finishWorkout { [weak self] workout, error in
            let errorDescription = error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                let healthOutcome: HealthKitSaveOutcomeV1
                if let errorDescription {
                    healthOutcome = .failed(message: errorDescription)
                } else {
                    // HealthKit documents this locked-device state: a nil
                    // workout with nil error is still a successful finish.
                    healthOutcome = .saved(workoutUUID: workout?.uuid)
                }
                await self.sealPackage(
                    builder: builder,
                    workout: workout,
                    endDate: endDate,
                    healthOutcome: healthOutcome,
                    motionResult: motionResult,
                    requestedLifecycle: .completed,
                    additionalQualityError: nil
                )
            }
        }
    }

    /// The private package is the source of the Watch's saved claim. HealthKit
    /// is recorded separately, so its failure never erases a recoverable local
    /// session package.
    private func sealPackage(
        builder: HKLiveWorkoutBuilder,
        workout: HKWorkout?,
        endDate: Date,
        healthOutcome: HealthKitSaveOutcomeV1,
        motionResult: MotionCaptureDrainResult,
        requestedLifecycle: SessionLifecycleV1,
        additionalQualityError: String?
    ) async {
        guard let writer = packageWriter, let sessionID else {
            phase = .failed("Private session storage was unavailable before the session could be sealed.")
            return
        }

        var storageErrors = [String]()
        var qualityMessages = [String]()
        if let storageQualityError {
            storageErrors.append(storageQualityError)
            qualityMessages.append(storageQualityError)
        }
        if let motionFailure = motionResult.storageFailure {
            storageErrors.append(motionFailure)
            qualityMessages.append(motionFailure)
        }
        if let additionalQualityError { qualityMessages.append(additionalQualityError) }

        if !qualityMessages.isEmpty {
            do {
                try await writer.appendQualityEvent(
                    CaptureQualityEventV1(
                        timestamp: Date(),
                        level: .error,
                        code: "capture_quality_error",
                        detail: qualityMessages.joined(separator: " ")
                    )
                )
            } catch {
                storageErrors.append(error.localizedDescription)
                qualityMessages.append(error.localizedDescription)
            }
        }

        do {
            try await writer.appendCaptureDiagnostics(motionResult.diagnostics)
        } catch {
            storageErrors.append(error.localizedDescription)
            qualityMessages.append(error.localizedDescription)
        }

        // Seal sprint detection results before the completion frame.
        drainDetectorMagnitudes()
        let finalSprintBatch = sprintDetector.finalBatch()
        if !finalSprintBatch.events.isEmpty {
            do {
                try await writer.appendSprintBatch(finalSprintBatch)
            } catch {
                storageErrors.append(error.localizedDescription)
                qualityMessages.append(error.localizedDescription)
            }
        }

        let lifecycle: SessionLifecycleV1
        if storageErrors.isEmpty {
            lifecycle = requestedLifecycle
        } else {
            lifecycle = .interrupted(reason: .storageFailure)
        }
        let packageSummary = makePackageSummary(builder: builder, workout: workout, endDate: endDate)
        let completion = SessionCompletionV1(
            endedAt: endDate,
            lifecycle: lifecycle,
            summary: packageSummary,
            healthKitSaveOutcome: healthOutcome
        )

        let sealedURL: URL
        do {
            sealedURL = try await writer.complete(completion)
        } catch {
            WatchLog.recorder.logError("sealPackage: complete() failed", error: error)
            await recordDiagnostic(
                "package_seal_failed",
                detail: Self.diagnosticErrorCode(error),
                armed: false
            )
            phase = .failed("Private session storage could not be sealed: \(error.localizedDescription)")
            WKInterfaceDevice.current().play(.failure)
            return
        }

        await recordDiagnostic("package_sealed", armed: false)
        WatchLog.recorder.info(
            "sealPackage: sealed \(sealedURL.lastPathComponent, privacy: .public)"
        )
        let syncResult = await syncCoordinator.enqueueSealedPackage(at: sealedURL)
        let summary = FootballSessionSummary(
            sessionID: sessionID,
            transferKey: syncResult.key,
            duration: packageSummary.duration?.value ?? 0,
            distanceMeters: packageSummary.distance?.value ?? 0,
            averageHeartRate: packageSummary.averageHeartRate?.value,
            motion: motionResult.snapshot,
            healthKitSaveOutcome: healthOutcome,
            captureQualityError: qualityMessages.first
        )
        self.session = nil
        self.builder = nil
        self.packageWriter = nil
        self.startedAt = nil
        self.metricTail = nil
        cancelFinishingWatchdog()
        self.phase = .saved(summary)
        WKInterfaceDevice.current().play(.success)
    }

    private func makePackageSummary(
        builder: HKLiveWorkoutBuilder,
        workout: HKWorkout?,
        endDate: Date
    ) -> SessionSummaryMetricsV1 {
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())
        let heartRate = builder.statistics(for: heartRateType)?.averageQuantity()?.doubleValue(for: heartRateUnit)
        let builderDistance = builder.statistics(for: distanceType)?.sumQuantity()?.doubleValue(for: .meter())
        let builderEnergy = builder.statistics(for: activeEnergyType)?.sumQuantity()?.doubleValue(for: .kilocalorie())
        let finalDistance = workout?.totalDistance?.doubleValue(for: .meter()) ?? builderDistance
        let finalEnergy = workout?.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? builderEnergy
        let duration = workout?.duration ?? builder.elapsedTime(at: endDate)
        let provenance: MetricProvenanceV1 = workout == nil ? .healthKitLive : .healthKitFinalWorkout

        return SessionSummaryMetricsV1(
            duration: SessionMetricV1(value: max(0, duration), unit: .seconds, provenance: provenance, measuredAt: endDate),
            distance: finalDistance.map {
                SessionMetricV1(value: $0, unit: .meters, provenance: provenance, measuredAt: endDate)
            },
            averageHeartRate: heartRate.map {
                SessionMetricV1(value: $0, unit: .beatsPerMinute, provenance: .healthKitLive, measuredAt: endDate)
            },
            activeEnergy: finalEnergy.map {
                SessionMetricV1(value: $0, unit: .kilocalories, provenance: provenance, measuredAt: endDate)
            }
        )
    }

    private func updateStatistics(for identifiers: [String]) {
        guard let builder, let writer = packageWriter else { return }
        let timestamp = Date()
        let heartRateUnit = HKUnit.count().unitDivided(by: .minute())

        for identifier in identifiers {
            switch identifier {
            case HKQuantityTypeIdentifier.heartRate.rawValue:
                guard let statistics = builder.statistics(for: heartRateType) else { continue }
                let mostRecent = statistics.mostRecentQuantity()?.doubleValue(for: heartRateUnit)
                currentHeartRate = mostRecent
                averageHeartRate = statistics.averageQuantity()?.doubleValue(for: heartRateUnit)
                if let mostRecent {
                    sprintDetector.consumeHeartRate(beatsPerMinute: mostRecent, at: timestamp)
                    enqueueMetricWrite(writer) {
                        try await writer.appendHeartRateSnapshot(
                            HeartRateSnapshotV1(
                                timestamp: timestamp,
                                beatsPerMinute: SessionMetricV1(
                                    value: mostRecent,
                                    unit: .beatsPerMinute,
                                    provenance: .healthKitLive,
                                    measuredAt: timestamp
                                )
                            )
                        )
                    }
                }

            case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
                guard let quantity = builder.statistics(for: distanceType)?.sumQuantity() else { continue }
                let meters = quantity.doubleValue(for: .meter())
                distanceMeters = meters
                sprintDetector.consumeDistance(cumulativeMeters: meters, at: timestamp)
                enqueueMetricWrite(writer) {
                    try await writer.appendDistanceSnapshot(
                        DistanceSnapshotV1(
                            timestamp: timestamp,
                            meters: SessionMetricV1(
                                value: meters,
                                unit: .meters,
                                provenance: .healthKitLive,
                                measuredAt: timestamp
                            )
                        )
                    )
                }

            default:
                continue
            }
        }
        drainDetectorMagnitudes()
        Task { @MainActor [weak self, writer] in
            await self?.flushSprintsIfDue(writer: writer, now: timestamp)
        }
    }

    /// Append a sprint batch at most once per minute while the session is
    /// active, so sprint events survive an interrupted seal.
    private func flushSprintsIfDue(writer: SessionPackageWriter, now: Date) async {
        if let lastSprintFlush, now.timeIntervalSince(lastSprintFlush) < 60 {
            return
        }
        let batch = sprintDetector.flush()
        guard !batch.events.isEmpty else { return }
        do {
            try await writer.appendSprintBatch(batch)
            lastSprintFlush = now
        } catch {
            recordStorageQualityError(error.localizedDescription)
        }
    }

    private func enqueueMetricWrite(
        _ writer: SessionPackageWriter,
        operation: @escaping @Sendable () async throws -> Void
    ) {
        let previous = metricTail
        metricTail = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await operation()
            } catch {
                self?.recordStorageQualityError(error.localizedDescription)
            }
        }
    }

    private func recordStorageQualityError(_ message: String) {
        if storageQualityError == nil {
            storageQualityError = message
        }
    }

    private func handleSessionEndedUnexpectedly() {
        guard !finishRequested, phase == .active, let builder else {
            WatchLog.recorder.warning(
                "handleSessionEndedUnexpectedly: ignored (finishRequested=\(self.finishRequested, privacy: .public), phase=\(String(describing: self.phase), privacy: .public))"
            )
            return
        }
        WatchLog.recorder.warning("handleSessionEndedUnexpectedly: sealing interrupted package")
        finishRequested = true
        phase = .finishing
        beginFinishingWatchdog()
        let endDate = Date()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.recordDiagnostic("workout_ended_unexpectedly")
            let motionResult = await self.motionCapture.stopAndDrain()
            await self.metricTail?.value
            await self.sealPackage(
                builder: builder,
                workout: nil,
                endDate: endDate,
                healthOutcome: .unavailable(reason: .notAttempted),
                motionResult: motionResult,
                requestedLifecycle: .interrupted(reason: .workoutEndedUnexpectedly),
                additionalQualityError: "The workout ended before Finish was held."
            )
        }
    }

    /// A `.finishing` phase must always terminate. The HealthKit end callbacks
    /// (`endCollection`, `finishWorkout`) have no guaranteed invocation, so a
    /// lost callback used to leave the "Saving session" spinner up forever.
    /// The frames are already durable in the `.partial` package by this point,
    /// so the fail-safe surfaces an honest failure; the next launch's audit
    /// recovers the partial and queues it for iPhone transfer.
    private func beginFinishingWatchdog() {
        cancelFinishingWatchdog()
        finishingWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.finishingWatchdogTimeout * 1_000_000_000))
            guard !Task.isCancelled, let self, case .finishing = self.phase else { return }
            await self.recordDiagnostic("finishing_watchdog_fired", armed: false)
            WatchLog.recorder.error("finishingWatchdog: finish did not complete in \(Self.finishingWatchdogTimeout, privacy: .public)s")
            WKInterfaceDevice.current().play(.failure)
            self.phase = .failed(
                "Saving took too long and was stopped. Your session data is safe on the watch and will transfer on the next app launch."
            )
        }
    }

    private func cancelFinishingWatchdog() {
        finishingWatchdogTask?.cancel()
        finishingWatchdogTask = nil
    }

    private func auditInterruptedPackages(_ repository: WatchSessionRepository) {
        Task { @MainActor [weak self] in
            await self?.refreshRecoveryAggregate()
        }
    }

    /// Refreshes the recovery aggregate from repository discovery and the
    /// sync coordinator's cached outbox records. Called on entry to the
    /// Session Recovery screen, after Recover Sessions work, and whenever the
    /// coordinator publishes a new state generation (receipts, framework
    /// completions, enqueues). Bounded memory: discovery lists filenames and
    /// sizes only; no package is read.
    func refreshRecoveryAggregate() async {
        guard let repository else {
            recoveryAggregate = nil
            return
        }
        do {
            let discovered = try await repository.discover()
            recoveryAggregate = SessionRecoveryAggregateV1.compute(
                discovered: discovered,
                outboxRecords: syncCoordinator.outboxRecords()
            )
        } catch {
            recoveryAggregate = nil
            recoveryMessage = "Interrupted session storage could not be checked. Try again later."
        }
    }

    /// Explicit, button-driven recovery: recover + enqueue one partial per
    /// tap, guarded by checkpoints so any death during the work lands in the
    /// diagnostic journal the phone can read.
    func recoverInterruptedSessionsNow() {
        guard !isRecovering, let repository else { return }
        isRecovering = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRecovering = false }
            do {
                let discovered = try await repository.discover()
                var messages: [String] = []
                var entries: [SessionRecoveryLogEntryV1] = []

                for package in discovered where package.kind == .sealed {
                    let url = repository.sessionsDirectory
                        .appendingPathComponent(package.filename, isDirectory: false)
                    let alreadyTracked = await self.syncCoordinator.hasRecord(
                        withDigest: try FootySessionPackageV1.digest(of: url)
                    )
                    guard !alreadyTracked else { continue }
                    await self.launchRecoverySync.submitDiscoveredPackage(at: url)
                    let metadata = try? await repository.sessionMetadata(named: package.filename)
                    let label = SessionDisplayFormatting.sessionLabel(
                        startedAt: metadata?.startedAt,
                        duration: metadata?.duration
                    )
                    let message = "Queued \(label) for transfer."
                    messages.append(message)
                    entries.append(
                        SessionRecoveryLogEntryV1(
                            sessionID: metadata?.sessionID,
                            startedAt: metadata?.startedAt,
                            duration: metadata?.duration,
                            outcome: .queued,
                            message: message
                        )
                    )
                }

                let partialPackages = discovered.filter { $0.kind == .partial }
                for package in partialPackages {
                    do {
                        let recovered: RecoveredSessionPackageV1
                        if let existing = LaunchRecoverySync.recoveredFilename(
                            forPartialNamed: package.filename,
                            discovered: discovered
                        ) {
                            let existingMetadata = try await repository.sessionMetadata(named: existing)
                            recovered = RecoveredSessionPackageV1(
                                originalFilename: package.filename,
                                recoveredFilename: existing,
                                sourceStatus: .tornTail,
                                recoveredDigest: try FootySessionPackageV1.digest(
                                    of: repository.sessionsDirectory
                                        .appendingPathComponent(existing, isDirectory: false)
                                ),
                                startedAt: existingMetadata.startedAt,
                                recordedDuration: existingMetadata.duration
                            )
                        } else {
                            await self.recordDiagnostic("recovery_scan_start", armed: true)
                            recovered = try await repository.recoverPartial(named: package.filename)
                            await self.recordDiagnostic("recovery_scan_done", detail: recovered.recoveredFilename)
                        }
                        await self.recordDiagnostic("recovery_enqueue_start", detail: recovered.recoveredFilename)
                        let url = repository.sessionsDirectory
                            .appendingPathComponent(recovered.recoveredFilename, isDirectory: false)
                        await self.launchRecoverySync.submitDiscoveredPackage(at: url)
                        await self.recordDiagnostic("recovery_enqueue_done", detail: recovered.recoveredFilename)
                        let label = SessionDisplayFormatting.sessionLabel(
                            startedAt: recovered.startedAt,
                            duration: recovered.recordedDuration
                        )
                        let message = "Recovered \(label)."
                        messages.append(message)
                        entries.append(
                            SessionRecoveryLogEntryV1(
                                startedAt: recovered.startedAt,
                                duration: recovered.recordedDuration,
                                outcome: .recovered,
                                message: message
                            )
                        )
                    } catch {
                        await self.recordDiagnostic(
                            "recovery_failed",
                            detail: Self.diagnosticErrorCode(error)
                        )
                        let message = "Could not recover a session: \(error.localizedDescription)"
                        messages.append(message)
                        entries.append(
                            SessionRecoveryLogEntryV1(
                                outcome: .failed,
                                message: message
                            )
                        )
                    }
                }

                if messages.isEmpty {
                    self.recoveryMessage = "Nothing to recover."
                } else {
                    self.recoveryMessage = messages.joined(separator: " ")
                }
                self.recoveryLog = entries
                await self.refreshRecoveryAggregate()
            } catch {
                self.recoveryMessage = "Recovery could not start: \(error.localizedDescription)"
            }
        }
    }

    private func fail(_ message: String) {
        WatchLog.recorder.error("fail: \(message, privacy: .public)")
        countdownTask?.cancel()
        countdownTask = nil
        motionCapture.stop()
        session?.end()
        session = nil
        builder = nil
        startedAt = nil
        phase = .failed(message)
        WKInterfaceDevice.current().play(.failure)
    }

    private func recordDiagnostic(
        _ code: String,
        detail: String? = nil,
        armed: Bool? = nil
    ) async {
        guard let diagnosticJournal else {
            WatchLog.recorder.error(
                "recordDiagnostic: journal unavailable, dropping checkpoint \(code, privacy: .public)"
            )
            return
        }
        do {
            try await diagnosticJournal.checkpoint(code, detail: detail, armed: armed)
        } catch {
            WatchLog.recorder.error(
                "recordDiagnostic: checkpoint \(code, privacy: .public) failed — \(error.localizedDescription, privacy: .public) [\(String(describing: (error as NSError).domain), privacy: .public)#\((error as NSError).code)]"
            )
        }
    }

    nonisolated private static func diagnosticErrorCode(_ error: Error?) -> String? {
        guard let error else { return nil }
        let cocoaError = error as NSError
        return "\(cocoaError.domain)#\(cocoaError.code)"
    }

    private func clearSessionState() {
        countdownTask?.cancel()
        countdownTask = nil
        motionCapture.stop()
        cancelFinishingWatchdog()
        session = nil
        builder = nil
        packageWriter = nil
        sessionID = nil
        metricTail = nil
        currentHeartRate = nil
        averageHeartRate = nil
        distanceMeters = 0
        startedAt = nil
        finishRequested = false
        storageQualityError = nil
    }
}

extension WorkoutRecorder: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .ended else { return }
        Task { @MainActor [weak self] in
            self?.handleSessionEndedUnexpectedly()
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: any Error
    ) {
        Task { @MainActor [weak self] in
            self?.handleSessionEndedUnexpectedly()
        }
    }
}

extension WorkoutRecorder: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let identifiers = collectedTypes.compactMap {
            ($0 as? HKQuantityType)?.identifier
        }
        Task { @MainActor [weak self] in
            self?.updateStatistics(for: identifiers)
        }
    }
}
