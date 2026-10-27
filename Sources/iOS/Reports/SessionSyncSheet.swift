import SwiftUI

/// A compact, truthful sync status for the Sessions header. One line, no
/// technical vocabulary; the detail lives in the sheet it opens.
struct SyncStatusPill: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @State private var showsSheet = false

    var body: some View {
        Button {
            showsSheet = true
        } label: {
            HStack(spacing: 6) {
                if showsLiveActivity {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: status.symbolName)
                        .font(.caption)
                        .foregroundStyle(status.tint)
                }
                Text(status.title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PerformanceTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(Capsule().strokeBorder(.separator.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("Sync status: \(status.title)")
        .accessibilityHint("Shows transfer and backup details")
        .sheet(isPresented: $showsSheet) {
            SessionSyncSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var showsLiveActivity: Bool {
        model.isReceivingFromWatch || model.outboxProgressDetail != nil
    }

    private var status: SyncPresentation {
        SyncPresentation(model: model)
    }
}

/// How sync state presents right now. Built from the library model's
/// published state; errors always outrank quiet success.
struct SyncPresentation: Equatable {
    enum Kind: Equatable {
        case receiving
        case waitingOnWatch(count: Int)
        case watchNeedsAction(count: Int)
        case uploading
        case needsAttention
        case pendingUploads(count: Int)
        case upToDate
        case waitingForFirst
        case storageUnavailable
        case manualLogsOnly
    }

    let kind: Kind
    let detail: String?

    var title: String {
        switch kind {
        case .receiving:
            return "Receiving a session from Apple Watch…"
        case .waitingOnWatch(let count):
            return count == 1 ? "1 session still on Apple Watch" : "\(count) sessions still on Apple Watch"
        case .watchNeedsAction(let count):
            return count == 1 ? "1 Watch session needs attention" : "\(count) Watch sessions need attention"
        case .uploading:
            return "Backing up…"
        case .needsAttention:
            return "Backup needs attention"
        case .pendingUploads(let count):
            return count == 1 ? "1 session waiting to back up" : "\(count) sessions waiting to back up"
        case .upToDate:
            return "Up to date"
        case .waitingForFirst:
            return "Waiting for your first session"
        case .storageUnavailable:
            return "Storage unavailable"
        case .manualLogsOnly:
            return "Manual logs saved on iPhone"
        }
    }

    var symbolName: String {
        switch kind {
        case .receiving: return "applewatch.radiowaves.left.and.right"
        case .waitingOnWatch: return "applewatch.radiowaves.left.and.right"
        case .watchNeedsAction: return "applewatch.slash"
        case .uploading: return "icloud.and.arrow.up"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .pendingUploads: return "icloud.and.arrow.up"
        case .upToDate: return "checkmark.icloud"
        case .waitingForFirst: return "tray"
        case .storageUnavailable: return "exclamationmark.triangle.fill"
        case .manualLogsOnly: return "iphone"
        }
    }

    var tint: Color {
        switch kind {
        case .receiving, .uploading, .waitingOnWatch: return PerformanceTheme.accent
        case .needsAttention, .storageUnavailable, .watchNeedsAction: return PerformanceTheme.warning
        case .pendingUploads: return .secondary
        case .upToDate: return PerformanceTheme.accent
        case .waitingForFirst: return .secondary
        case .manualLogsOnly: return .secondary
        }
    }

    @MainActor
    init(model: PhoneSessionLibraryModel) {
        if model.repositoryUnavailable {
            self.init(kind: .storageUnavailable, detail: model.message)
            return
        }
        if model.isReceivingFromWatch {
            self.init(kind: .receiving, detail: nil)
            return
        }
        // Getting sessions off the Watch matters more than the backup, so
        // Watch states outrank backup states.
        if let status = model.watchStatus {
            if status.waiting > 0 {
                self.init(kind: .waitingOnWatch(count: status.waiting), detail: nil)
                return
            }
            if status.failed + status.needsRecovery > 0 {
                self.init(kind: .watchNeedsAction(count: status.failed + status.needsRecovery), detail: nil)
                return
            }
        }
        if let error = model.outboxLastError {
            self.init(kind: .needsAttention, detail: error)
            return
        }
        if let progressDetail = model.outboxProgressDetail {
            self.init(kind: .uploading, detail: progressDetail)
            return
        }
        if model.outboxPendingCount > 0 {
            self.init(kind: .pendingUploads(count: model.outboxPendingCount), detail: nil)
            return
        }
        if model.sessions.isEmpty {
            self.init(kind: .waitingForFirst, detail: nil)
            return
        }
        if model.sessions.allSatisfy(\.isManualEntry) {
            self.init(kind: .manualLogsOnly, detail: nil)
            return
        }
        self.init(kind: .upToDate, detail: nil)
    }

    init(kind: Kind, detail: String?) {
        self.kind = kind
        self.detail = detail
    }
}

/// The focused sync screen behind the pill: Watch transfer state, iPhone
/// import state, backup queue and progress, and errors with a retry.
struct SessionSyncSheet: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRetrying = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                    section(title: "Apple Watch") {
                        watchStatusCard
                        if let status = model.watchStatus {
                            row("Saved on your Watch", value: "\(status.savedOnWatch)")
                            row("Still to send", value: "\(status.waiting)")
                            if let count = status.notRequestedByPhone, count > 0 {
                                row("No resend needed", value: "\(count)")
                            }
                            if status.failed > 0 {
                                row("Did not send", value: "\(status.failed)")
                            }
                            if status.needsRecovery > 0 {
                                row("Need Recover on Watch", value: "\(status.needsRecovery)")
                            }
                        }
                        row(
                            "Sessions on this iPhone",
                            value: "\(model.sessions.filter { !$0.isManualEntry }.count)"
                        )
                        if let status = model.watchStatus {
                            row("Watch last reported", value: Self.relative(status.updatedAt))
                        }
                        if let delivered = model.lastWatchDeliveryAt {
                            row("Last file received", value: Self.relative(delivered))
                        }
                    }

                    section(title: "Private backup") {
                        if model.outboxAvailable {
                            row(
                                "Uploaded",
                                value: "\(model.outboxPushedCount) of \(model.sessions.filter { !$0.isManualEntry }.count)"
                            )
                            row(
                                "Waiting to upload",
                                value: "\(model.outboxPendingCount)"
                            )
                            if let detail = model.outboxProgressDetail {
                                HStack {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Uploading — \(detail)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if let error = model.outboxLastError {
                                Label(
                                    Self.friendlyBackupError(error),
                                    systemImage: "exclamationmark.triangle.fill"
                                )
                                .font(.subheadline)
                                .foregroundStyle(PerformanceTheme.warning)
                            }
                            Button {
                                Task {
                                    isRetrying = true
                                    await model.retryPendingUploads()
                                    isRetrying = false
                                }
                            } label: {
                                if isRetrying {
                                    HStack {
                                        ProgressView()
                                        Text("Retrying…")
                                    }
                                } else {
                                    Label("Retry waiting uploads", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(isRetrying || model.outboxPendingCount == 0)
                        } else {
                            Text(
                                "Backup is not configured on this iPhone. Watch recordings keep their Watch copy. Manual logs stay on this iPhone."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                    }

                    section(title: "Manual logs") {
                        row("Saved on this iPhone", value: "\(model.sessions.filter(\.isManualEntry).count)")
                        Text("Manual logs do not upload or create a Watch copy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(PerformanceTheme.cardInset)
                    }

                    if let message = model.message {
                        Label(message, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, PerformanceTheme.screenInset)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        .modifier(SimulatorQAEnvironment(model: model))
        #endif
    }

    private var watchStatusCard: some View {
        let summary = WatchTransferSummary(
            isReceiving: model.isReceivingFromWatch,
            status: model.watchStatus
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if model.isReceivingFromWatch {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: summary.symbolName)
                        .foregroundStyle(summary.isWarning ? PerformanceTheme.warning : PerformanceTheme.accent)
                        .accessibilityHidden(true)
                }
                Text(summary.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress = summary.progress {
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .tint(PerformanceTheme.accent)
                    .accessibilityLabel("\(progress.done) of \(progress.total) Watch sessions on this iPhone")
                Text("\(progress.done) of \(progress.total) Watch sessions are on this iPhone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(summary.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PerformanceTheme.cardInset)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync-watch-status")
    }

    private static func relative(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named))
    }

    /// Presents raw transport errors as sentences a reader can act on. The
    /// original text stays in the durable outbox state; only the display
    /// changes, and unknown errors pass through untouched.
    static func friendlyBackupError(_ message: String) -> String {
        if message.contains("missingToken") {
            return "Backup is not set up in this version of the app. Your sessions stay safe on this iPhone."
        }
        if message.contains("401") || message.lowercased().contains("unauthorized") {
            return "The backup service rejected access to this iPhone's credential."
        }
        if message.contains("404") {
            return "The backup service could not be found for this session store."
        }
        if message.lowercased().contains("offline")
            || message.lowercased().contains("network")
            || message.lowercased().contains("connect") {
            return "The backup service was unreachable. Your sessions remain safe on this iPhone."
        }
        return message
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .performanceCard(padding: 0)
            .padding(.horizontal, PerformanceTheme.cardInset)
            .padding(.vertical, 4)
        }
    }

    private func row(_ title: String, value: String) -> some View {
        AdaptiveDetailRow(title: title, value: value)
        .padding(.horizontal, PerformanceTheme.cardInset)
        .padding(.vertical, 11)
    }
}

/// What the Watch transfer is doing, in words, for the Sync sheet. Built from
/// the Watch's own report, because the iPhone cannot see a transfer until
/// the file lands.
struct WatchTransferSummary: Equatable {
    struct Progress: Equatable {
        let done: Int
        let total: Int
    }

    let headline: String
    let explanation: String
    let symbolName: String
    let isWarning: Bool
    let progress: Progress?

    init(isReceiving: Bool, status: WatchSyncStatusV1?) {
        progress = status.flatMap { status in
            status.savedOnWatch > 0 ? Progress(done: status.onIPhone, total: status.savedOnWatch) : nil
        }

        if isReceiving {
            headline = "Receiving a session now"
            explanation = "Sessions arrive one at a time. Each one is checked and saved before the next."
            symbolName = "applewatch.radiowaves.left.and.right"
            isWarning = false
            return
        }
        guard let status else {
            headline = "No report from your Watch yet"
            explanation = "Open the app on your Watch. It then tells this iPhone what it has to send."
            symbolName = "applewatch"
            isWarning = false
            return
        }
        if status.waiting > 0 {
            headline = status.waiting == 1
                ? "1 session still on your Watch"
                : "\(status.waiting) sessions still on your Watch"
            explanation = "Your Watch sends them in the background, one at a time. Keep it near this iPhone with Bluetooth on. If nothing arrives, open the app on your Watch."
            symbolName = "applewatch.radiowaves.left.and.right"
            isWarning = false
            return
        }
        if status.needsRecovery > 0 {
            headline = status.needsRecovery == 1
                ? "1 recording stopped early"
                : "\(status.needsRecovery) recordings stopped early"
            explanation = "On your Watch, open Session Recovery and tap Recover. The Watch then sends them here."
            symbolName = "exclamationmark.triangle.fill"
            isWarning = true
            return
        }
        if status.failed > 0 {
            headline = status.failed == 1 ? "1 session did not send" : "\(status.failed) sessions did not send"
            explanation = "The Watch tries again the next time you open the app on it."
            symbolName = "exclamationmark.triangle.fill"
            isWarning = true
            return
        }
        if (status.notRequestedByPhone ?? 0) > 0 {
            headline = "No more Watch sessions to send"
            explanation = "The iPhone already knows some sessions or you deleted its copies. Their files stay on your Watch."
        } else {
            headline = status.savedOnWatch == 0 ? "No sessions on your Watch" : "All Watch sessions are here"
            explanation = "Your Watch has nothing left to send."
        }
        symbolName = "checkmark.circle.fill"
        isWarning = false
    }
}
