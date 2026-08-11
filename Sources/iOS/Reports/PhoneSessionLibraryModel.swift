import Foundation
import SwiftUI

@MainActor
final class PhoneSessionLibraryModel: ObservableObject {
    @Published private(set) var sessions: [FileSessionRepository.SessionRecord] = []
    @Published private(set) var watchDiagnostics: [WatchDiagnosticReportV1] = []
    @Published private(set) var selectedDetail: FileSessionRepository.SessionDetail?
    @Published private(set) var exportURL: URL?
    @Published private(set) var message: String?
    @Published private(set) var isLoading = false

    private let repository: FileSessionRepository?
    private let diagnosticRepository: PhoneDiagnosticRepository?

    init(runtime: PhoneTransferRuntime = .shared) {
        self.repository = runtime.repository
        self.diagnosticRepository = runtime.diagnosticRepository
        self.message = runtime.startupErrorDescription.map { _ in
            "Local iPhone storage is unavailable. No session status can be shown."
        }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        if let repository {
            do {
                try await repository.reconcileOnStartup()
                sessions = await repository.sessions()
            } catch {
                message = "Local iPhone storage could not be reconciled, so this library may be incomplete."
                sessions = await repository.sessions()
            }
        }
        if let diagnosticRepository {
            watchDiagnostics = await diagnosticRepository.reports()
        }
        if let selectedID = selectedDetail?.record.sessionID {
            await loadDetail(for: selectedID, clearMessage: false)
        }
    }

    func loadDetail(for sessionID: UUID, clearMessage: Bool = true) async {
        guard let repository else { return }
        if clearMessage { message = nil }
        do {
            selectedDetail = try await repository.detail(for: sessionID)
            exportURL = nil
        } catch {
            message = "This iPhone copy could not be read. It has not been exported."
        }
    }

    func prepareExactExport() async {
        guard let repository, let sessionID = selectedDetail?.record.sessionID else { return }
        message = nil
        do {
            exportURL = try await repository.verifiedExportURL(for: sessionID)
        } catch {
            exportURL = nil
            message = "The stored package no longer matches its recorded digest, so export is unavailable."
        }
    }

    func deleteIPhoneCopy() async {
        guard let repository, let sessionID = selectedDetail?.record.sessionID else { return }
        do {
            _ = try await repository.deleteIPhoneCopy(for: sessionID)
            selectedDetail = nil
            exportURL = nil
            await refresh()
        } catch {
            message = "The iPhone copy could not be deleted. It remains on this device."
        }
    }
}
