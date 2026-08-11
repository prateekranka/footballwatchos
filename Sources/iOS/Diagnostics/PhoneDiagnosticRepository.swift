import Foundation

actor PhoneDiagnosticRepository {
    enum RepositoryError: Error, Sendable, Equatable {
        case conflictingReportIdentity
        case unsupportedStateFormat(Int)
    }

    private struct StoredReceipt: Codable, Sendable, Equatable {
        let receipt: WatchDiagnosticReceiptV1
        let payload: Data
    }

    private struct State: Codable, Sendable, Equatable {
        static let schemaVersion = 1

        let schemaVersion: Int
        var reports: [WatchDiagnosticReportV1]
        var receipts: [UUID: StoredReceipt]

        init(
            reports: [WatchDiagnosticReportV1] = [],
            receipts: [UUID: StoredReceipt] = [:]
        ) {
            self.schemaVersion = Self.schemaVersion
            self.reports = reports
            self.receipts = receipts
        }
    }

    let directory: URL

    private let fileManager: FileManager
    private let stateURL: URL
    private var state: State

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.directory = rootDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
        self.stateURL = self.directory.appendingPathComponent("watch-diagnostics.json", isDirectory: false)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try? (directory as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

        if fileManager.fileExists(atPath: stateURL.path) {
            let decoded = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
            guard decoded.schemaVersion == State.schemaVersion else {
                throw RepositoryError.unsupportedStateFormat(decoded.schemaVersion)
            }
            self.state = decoded
        } else {
            self.state = State()
        }
    }

    func store(
        _ report: WatchDiagnosticReportV1,
        acknowledgedAt: Date = Date()
    ) throws -> Data {
        try report.validate()

        if let existing = state.reports.first(where: { $0.reportID == report.reportID }) {
            guard existing == report else {
                throw RepositoryError.conflictingReportIdentity
            }
            if let receipt = state.receipts[report.reportID] {
                return receipt.payload
            }
        }

        let receipt = WatchDiagnosticReceiptV1(
            reportID: report.reportID,
            acknowledgedAt: acknowledgedAt
        )
        let payload = try WatchDiagnosticTransferCodecV1.encodeReceipt(receipt)
        let previous = state
        if !state.reports.contains(where: { $0.reportID == report.reportID }) {
            state.reports.append(report)
            state.reports = Array(state.reports.sorted { $0.detectedAt > $1.detectedAt }.prefix(50))
        }
        state.receipts[report.reportID] = StoredReceipt(receipt: receipt, payload: payload)

        do {
            try persist()
        } catch {
            state = previous
            throw error
        }
        return payload
    }

    func reports() -> [WatchDiagnosticReportV1] {
        state.reports.sorted { $0.detectedAt > $1.detectedAt }
    }

    func durableReceiptPayloads() -> [Data] {
        state.receipts.values
            .sorted { $0.receipt.acknowledgedAt < $1.receipt.acknowledgedAt }
            .map(\.payload)
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL, options: .atomic)
    }
}
