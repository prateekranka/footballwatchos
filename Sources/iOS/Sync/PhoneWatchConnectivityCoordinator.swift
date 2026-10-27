@preconcurrency import WatchConnectivity
import Foundation

/// The iPhone WatchConnectivity boundary. It keeps framework-owned objects in
/// the delegate callback and sends only stable Foundation values to the
/// repository actor.
final class PhoneWatchConnectivityCoordinator: NSObject, WCSessionDelegate, @unchecked Sendable {
    /// Posted when a Watch package file arrives at the iPhone (before import).
    static let sessionReceivedNotification = Notification.Name(
        "com.prateekranka.footballperformance.sessionReceived"
    )
    /// Posted after a Watch package has been durably imported on the iPhone.
    static let sessionImportedNotification = Notification.Name(
        "com.prateekranka.footballperformance.sessionImported"
    )
    /// Posted once for every received file, whatever happened to it. A repeat
    /// or rejected file never posts `sessionImportedNotification`, so
    /// "receiving" must end here instead.
    static let deliveryFinishedNotification = Notification.Name(
        "com.prateekranka.footballperformance.deliveryFinished"
    )
    /// Posted when the Watch reports a new count of its saved sessions.
    static let watchStatusNotification = Notification.Name(
        "com.prateekranka.footballperformance.watchStatus"
    )

    private let repository: FileSessionRepository
    private let diagnosticRepository: PhoneDiagnosticRepository
    private let pipelinePushService: PipelinePushService
    private let sessionPushOutbox: SessionPushOutbox
    private let configuration: FileSessionRepository.Configuration
    private let session: WCSession
    @MainActor private var contextGeneration: UInt64 = 0

    init(
        repository: FileSessionRepository,
        diagnosticRepository: PhoneDiagnosticRepository,
        configuration: FileSessionRepository.Configuration,
        pipelinePushService: PipelinePushService = PipelinePushService(),
        sessionPushOutbox: SessionPushOutbox = SessionPushOutbox(),
        session: WCSession = .default
    ) {
        self.repository = repository
        self.diagnosticRepository = diagnosticRepository
        self.pipelinePushService = pipelinePushService
        self.sessionPushOutbox = sessionPushOutbox
        self.configuration = configuration
        self.session = session
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        requeueDurableReceipts()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerProfileMayHaveChanged),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
    }

    @objc private func playerProfileMayHaveChanged() {
        sendContext()
    }

    /// Application context keeps only the latest value and reaches the Watch
    /// the next time it runs, so an age change or a library change made while
    /// the Watch is away still arrives. Each update replaces the whole
    /// dictionary, so every key is sent every time.
    private func sendContext() {
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.contextGeneration &+= 1
            let generation = self.contextGeneration
            let known = await self.repository.knownSessionIDs()
            guard self.contextGeneration == generation else { return }
            self.updateContext(knownSessionIDs: known)
        }
    }

    @MainActor
    private func updateContext(knownSessionIDs: Set<UUID>?) {
        guard session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else { return }
        let age = UserDefaults.standard.integer(forKey: "playerAge")
        let maximum = age > 0 ? PerformanceCoachV1.heartRateMax(age: age, observedPeak: nil) : 0
        var context: [String: Any] = [PlayerProfileContextV1.maximumHeartRateKey: maximum]

        let previous = PhoneLibraryContextV1.decode(context: session.applicationContext)
        if let knownSessionIDs {
            // A new time only when the list changed: the Watch resends any
            // session whose receipt is older than this time.
            let library: PhoneLibraryContextV1
            if let previous, previous.knownSessionIDs == knownSessionIDs {
                library = previous
            } else {
                library = PhoneLibraryContextV1(knownSessionIDs: knownSessionIDs, generatedAt: Date())
            }
            context.merge(library.contextEntries) { _, new in new }
        } else if let previous {
            context.merge(previous.contextEntries) { _, new in new }
        }

        guard !NSDictionary(dictionary: session.applicationContext).isEqual(to: context) else { return }
        try? session.updateApplicationContext(context)
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // Do not transfer the framework error across an actor boundary. The
        // descriptive value is intentionally local diagnostic information.
        _ = error.map { String(describing: $0) }
        requeueDurableReceipts()
        sendContext()
        storeWatchStatus(from: session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        storeWatchStatus(from: applicationContext)
    }

    private func storeWatchStatus(from context: [String: Any]) {
        guard let status = WatchSyncStatusV1.decode(context: context) else { return }
        if let stored = WatchSyncStatusStore.load(), stored.updatedAt >= status.updatedAt { return }
        WatchSyncStatusStore.save(status)
        NotificationCenter.default.post(name: Self.watchStatusNotification, object: nil)
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        sendContext()
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let deliveryID = UUID().uuidString.lowercased()
        let sourceURL = file.fileURL
        let envelopeData: Data?
        if let metadata = file.metadata?[SessionTransferCodecV1.metadataKey] as? Data {
            envelopeData = metadata
        } else {
            envelopeData = nil
        }

        NotificationCenter.default.post(name: Self.sessionReceivedNotification, object: nil)

        do {
            // This move is synchronous by design: WatchConnectivity can remove
            // its temporary source URL immediately after this callback returns.
            try FileSessionRepository.stageReceivedFileSynchronously(
                from: sourceURL,
                envelopeData: envelopeData,
                deliveryID: deliveryID,
                configuration: configuration
            )
        } catch {
            // `Error` is framework/implementation-owned and is not captured by
            // the task below. There is no package to acknowledge if staging
            // itself did not finish.
            let failureDescription = String(describing: error)
            NSLog("FootballPerformance could not stage a Watch package: %@", failureDescription)
            NotificationCenter.default.post(name: Self.deliveryFinishedNotification, object: nil)
            return
        }

        importStagedDelivery(deliveryID)
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let payload = userInfo[WatchDiagnosticTransferCodecV1.reportKey] as? Data else {
            return
        }

        let report: WatchDiagnosticReportV1
        do {
            report = try WatchDiagnosticTransferCodecV1.decodeReport(payload)
        } catch {
            NSLog("FootballPerformance rejected an invalid Watch diagnostic payload")
            return
        }

        let diagnosticRepository = diagnosticRepository
        Task { [weak self, diagnosticRepository] in
            do {
                let receiptPayload = try await diagnosticRepository.store(report)
                self?.queueDiagnosticReceipt(receiptPayload)
            } catch {
                NSLog("FootballPerformance could not persist a Watch diagnostic report")
            }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {
        // iOS pairing transitions can move the session through inactive before
        // deactivation. Existing staged files and durable receipts stay local.
    }

    func sessionDidDeactivate(_ session: WCSession) {
        // WCSession requires a fresh activation after deactivation on iPhone.
        session.activate()
    }

    func reconcileAndRequeueAtStartup() {
        let repository = repository
        let outbox = sessionPushOutbox
        Task { [weak self, repository, outbox] in
            do {
                try await repository.reconcileOnStartup()
                let sessions = await repository.sessions()
                for session in sessions where !session.isManualEntry {
                    await outbox.enqueue(
                        sessionID: session.sessionID,
                        repository: repository
                    )
                }
                Task { await outbox.retryAll() }
                self?.requeueDurableReceipts()
                self?.sendContext()
            } catch {
                let failureDescription = String(describing: error)
                NSLog("FootballPerformance could not reconcile iPhone packages: %@", failureDescription)
            }
        }
    }

    private func importStagedDelivery(_ deliveryID: String) {
        let repository = repository
        let outbox = sessionPushOutbox
        Task { [weak self, repository, outbox] in
            let outcome = await repository.importStaged(deliveryID: deliveryID)
            NotificationCenter.default.post(name: Self.deliveryFinishedNotification, object: nil)
            guard let payload = outcome.receiptPayload else { return }
            self?.queueReceipt(payload)
            if case let .imported(record, _) = outcome {
                NotificationCenter.default.post(name: Self.sessionImportedNotification, object: nil)
                self?.sendContext()
                await outbox.enqueue(sessionID: record.sessionID, repository: repository)
                Task { await outbox.pushOne() }
            }
        }
    }

    private func requeueDurableReceipts() {
        let repository = repository
        let diagnosticRepository = diagnosticRepository
        Task { [weak self, repository, diagnosticRepository] in
            let payloads = await repository.durableReceiptPayloads()
            for payload in payloads {
                self?.queueReceipt(payload)
            }
            let diagnosticPayloads = await diagnosticRepository.durableReceiptPayloads()
            for payload in diagnosticPayloads {
                self?.queueDiagnosticReceipt(payload)
            }
        }
    }

    private func queueReceipt(_ payload: Data) {
        // This happens only for a receipt read back from durable storage or
        // returned after the repository persisted it.
        session.transferUserInfo([SessionTransferCodecV1.receiptKey: payload])
    }

    private func queueDiagnosticReceipt(_ payload: Data) {
        session.transferUserInfo([WatchDiagnosticTransferCodecV1.receiptKey: payload])
    }
}

/// The last Watch status survives relaunch, so the iPhone can say what the
/// Watch still holds before the Watch next checks in.
enum WatchSyncStatusStore {
    static func load(defaults: UserDefaults = .standard) -> WatchSyncStatusV1? {
        guard let data = defaults.data(forKey: WatchSyncStatusV1.contextKey) else { return nil }
        return try? WatchSyncStatusV1.decode(data)
    }

    static func save(_ status: WatchSyncStatusV1, defaults: UserDefaults = .standard) {
        guard let data = try? status.encoded() else { return }
        defaults.set(data, forKey: WatchSyncStatusV1.contextKey)
    }
}

/// Constructs the local repository once and starts WatchConnectivity from the
/// app's initializer, before the first scene becomes visible.
final class PhoneTransferRuntime: @unchecked Sendable {
    static let shared = PhoneTransferRuntime()

    let repository: FileSessionRepository?
    let diagnosticRepository: PhoneDiagnosticRepository?
    let pipelinePushService: PipelinePushService?
    let sessionPushOutbox: SessionPushOutbox?
    private let coordinator: PhoneWatchConnectivityCoordinator?
    let startupErrorDescription: String?

    private init() {
        do {
            var configuration = try FileSessionRepository.Configuration.applicationSupport()
            #if DEBUG && targetEnvironment(simulator)
            let isolatedTesting = UserDefaults.standard.bool(forKey: "FP_UI_QA")
            if isolatedTesting {
                configuration = FileSessionRepository.Configuration(
                    rootDirectory: configuration.rootDirectory.deletingLastPathComponent()
                        .appendingPathComponent("FootballPerformanceQA", isDirectory: true)
                )
            }
            #endif
            let repository = try FileSessionRepository(configuration: configuration)
            let diagnosticRepository = try PhoneDiagnosticRepository(
                rootDirectory: configuration.rootDirectory
            )
            #if DEBUG && targetEnvironment(simulator)
            if isolatedTesting {
                self.repository = repository
                self.diagnosticRepository = diagnosticRepository
                self.pipelinePushService = nil
                self.sessionPushOutbox = nil
                self.coordinator = nil
                self.startupErrorDescription = nil
                return
            }
            #endif
            let pipelinePushService = PipelinePushService()
            let sessionPushOutbox = SessionPushOutbox(repository: repository)
            self.repository = repository
            self.diagnosticRepository = diagnosticRepository
            self.pipelinePushService = pipelinePushService
            self.sessionPushOutbox = sessionPushOutbox
            self.coordinator = PhoneWatchConnectivityCoordinator(
                repository: repository,
                diagnosticRepository: diagnosticRepository,
                configuration: configuration,
                pipelinePushService: pipelinePushService,
                sessionPushOutbox: sessionPushOutbox
            )
            self.startupErrorDescription = nil
        } catch {
            self.repository = nil
            self.diagnosticRepository = nil
            self.pipelinePushService = nil
            self.sessionPushOutbox = nil
            self.coordinator = nil
            self.startupErrorDescription = String(describing: error)
        }
    }

    func start() {
        coordinator?.activate()
        coordinator?.reconcileAndRequeueAtStartup()
    }
}
