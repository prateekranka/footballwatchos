@preconcurrency import WatchConnectivity
import Foundation

/// The iPhone WatchConnectivity boundary. It keeps framework-owned objects in
/// the delegate callback and sends only stable Foundation values to the
/// repository actor.
final class PhoneWatchConnectivityCoordinator: NSObject, WCSessionDelegate, @unchecked Sendable {
    private let repository: FileSessionRepository
    private let diagnosticRepository: PhoneDiagnosticRepository
    private let configuration: FileSessionRepository.Configuration
    private let session: WCSession

    init(
        repository: FileSessionRepository,
        diagnosticRepository: PhoneDiagnosticRepository,
        configuration: FileSessionRepository.Configuration,
        session: WCSession = .default
    ) {
        self.repository = repository
        self.diagnosticRepository = diagnosticRepository
        self.configuration = configuration
        self.session = session
        super.init()
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        requeueDurableReceipts()
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
        Task { [weak self, repository] in
            do {
                try await repository.reconcileOnStartup()
                self?.requeueDurableReceipts()
            } catch {
                let failureDescription = String(describing: error)
                NSLog("FootballPerformance could not reconcile iPhone packages: %@", failureDescription)
            }
        }
    }

    private func importStagedDelivery(_ deliveryID: String) {
        let repository = repository
        Task { [weak self, repository] in
            let outcome = await repository.importStaged(deliveryID: deliveryID)
            guard let payload = outcome.receiptPayload else { return }
            self?.queueReceipt(payload)
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

/// Constructs the local repository once and starts WatchConnectivity from the
/// app's initializer, before the first scene becomes visible.
final class PhoneTransferRuntime: @unchecked Sendable {
    static let shared = PhoneTransferRuntime()

    let repository: FileSessionRepository?
    let diagnosticRepository: PhoneDiagnosticRepository?
    private let coordinator: PhoneWatchConnectivityCoordinator?
    let startupErrorDescription: String?

    private init() {
        do {
            let configuration = try FileSessionRepository.Configuration.applicationSupport()
            let repository = try FileSessionRepository(configuration: configuration)
            let diagnosticRepository = try PhoneDiagnosticRepository(
                rootDirectory: configuration.rootDirectory
            )
            self.repository = repository
            self.diagnosticRepository = diagnosticRepository
            self.coordinator = PhoneWatchConnectivityCoordinator(
                repository: repository,
                diagnosticRepository: diagnosticRepository,
                configuration: configuration
            )
            self.startupErrorDescription = nil
        } catch {
            self.repository = nil
            self.diagnosticRepository = nil
            self.coordinator = nil
            self.startupErrorDescription = String(describing: error)
        }
    }

    func start() {
        coordinator?.activate()
        coordinator?.reconcileAndRequeueAtStartup()
    }
}
