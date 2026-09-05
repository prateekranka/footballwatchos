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
        case uploading
        case needsAttention
        case pendingUploads(count: Int)
        case upToDate
        case waitingForFirst
        case storageUnavailable
    }

    let kind: Kind
    let detail: String?

    var title: String {
        switch kind {
        case .receiving:
            return "Receiving from Apple Watch…"
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
        }
    }

    var symbolName: String {
        switch kind {
        case .receiving: return "applewatch.radiowaves.left.and.right"
        case .uploading: return "icloud.and.arrow.up"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .pendingUploads: return "icloud.and.arrow.up"
        case .upToDate: return "checkmark.icloud"
        case .waitingForFirst: return "tray"
        case .storageUnavailable: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .receiving, .uploading: return PerformanceTheme.accent
        case .needsAttention, .storageUnavailable: return PerformanceTheme.warning
        case .pendingUploads: return .secondary
        case .upToDate: return PerformanceTheme.accent
        case .waitingForFirst: return .secondary
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
                        row(
                            "Sessions on this iPhone",
                            value: "\(model.sessions.count)"
                        )
                        row(
                            "Receiving now",
                            value: model.isReceivingFromWatch ? "Yes" : "No"
                        )
                    }

                    section(title: "Private backup") {
                        if model.outboxAvailable {
                            row(
                                "Uploaded",
                                value: "\(model.outboxPushedCount) of \(model.sessions.count)"
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
                                "Backup is not configured on this iPhone. Your sessions remain safe on this device and on your Watch."
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
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
    }

    /// Presents raw transport errors as sentences a reader can act on. The
    /// original text stays in the durable outbox state; only the display
    /// changes, and unknown errors pass through untouched.
    static func friendlyBackupError(_ message: String) -> String {
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
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, PerformanceTheme.cardInset)
        .padding(.vertical, 11)
    }
}
