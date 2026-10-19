import SwiftUI

private enum SessionHistoryDestination: Hashable {
    case allSessions
}

/// The Sessions destination: latest session featured, recent history beneath
/// it, sync as one compact line. Hierarchy follows the approved concept:
/// the newest recording is the hero, everything else is quieter.
struct SessionsHomeView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAddSession = false

    private var latest: FileSessionRepository.SessionRecord? {
        model.sessions.first
    }

    private var recent: [FileSessionRepository.SessionRecord] {
        Array(model.sessions.dropFirst().prefix(3))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                header

                if let latest {
                    LatestSessionCard(record: latest)
                    recentSection
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .scrollBounceBehavior(.basedOnSize)
        .overlay(alignment: .bottom) {
            if let message = model.message, !model.repositoryUnavailable {
                Text(message)
                    .font(.footnote)
                    .padding(12)
                    .background(.regularMaterial, in: Capsule())
                    .padding()
                    .accessibilityElement(children: .combine)
            }
        }
        .navigationDestination(for: UUID.self) { sessionID in
            SessionOverviewScreen(sessionID: sessionID)
        }
        .navigationDestination(for: SessionHistoryDestination.self) { _ in
            AllSessionsView()
        }
        .sheet(isPresented: $showsAddSession) { AddSessionView() }
        .task {
            await model.refresh()
            await model.prepareVisualSummaries(budget: 1)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await model.refresh()
                await model.prepareVisualSummaries(budget: 1)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FOOTBALL PERFORMANCE")
                .font(.caption.weight(.bold))
                .foregroundStyle(PerformanceTheme.accent)
                .tracking(0.8)
                .accessibilityHidden(true)

            Text("Your sessions")
                .font(PerformanceTheme.screenTitle)
                .foregroundStyle(PerformanceTheme.primaryText)

            Text("The latest recording, then your history.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            SyncStatusPill()

            Button { showsAddSession = true } label: {
                Label("Add session", systemImage: "plus")
                    .foregroundStyle(PerformanceTheme.onAccent)
            }
            .buttonStyle(.borderedProminent)
            .tint(PerformanceTheme.accent)
            .accessibilityIdentifier("add-session")
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(PerformanceTheme.primaryText)
                Spacer()
                NavigationLink(value: SessionHistoryDestination.allSessions) {
                    Text("See all")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PerformanceTheme.accent)
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Shows every session")
            }

            VStack(spacing: 12) {
                ForEach(recent) { record in
                    RecentSessionRow(record: record)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "applewatch")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text(model.isReceivingFromWatch ? "Receiving your first session" : "No sessions yet")
                    .font(.headline)
                    .foregroundStyle(PerformanceTheme.primaryText)
                Text(
                    model.isReceivingFromWatch
                        ? "Your Apple Watch is transferring a recording now."
                        : "Start a Football Session on your watch, or add a manual log on this iPhone."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .accessibilityElement(children: .combine)
    }
}

/// The featured latest-session card. Stats and status come only from the
/// stored record; missing evidence shows an explicit dash.
private struct LatestSessionCard: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @Environment(\.dynamicTypeSize) private var textSize
    let record: FileSessionRepository.SessionRecord

    var body: some View {
        let headerLayout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        NavigationLink(value: record.sessionID) {
            VStack(alignment: .leading, spacing: 14) {
                headerLayout {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SessionRowFormatting.dayLabel(record.startedAt))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PerformanceTheme.primaryText)
                        Text(SessionRowFormatting.timeLabel(record.startedAt))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !textSize.isAccessibilitySize { Spacer() }
                    StateTag(state: SessionRowFormatting.state(record))
                }

                Text(SessionRowFormatting.typeAndSource(record))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                AdaptiveMetricGroup {
                    StatBlock(
                        value: SessionRowFormatting.durationLabel(
                            SessionRowFormatting.summaryDuration(record)
                        ),
                        caption: "Duration"
                    )
                    StatBlock(
                        value: SessionRowFormatting.distanceLabel(
                            meters: SessionRowFormatting.summaryDistance(record)
                        ),
                        caption: "Distance"
                    )
                    StatBlock(
                        value: SessionRowFormatting.heartRateLabel(
                            SessionRowFormatting.summaryAverageHeartRate(record)
                        ),
                        caption: "Avg heart rate"
                    )
                }

                SessionFingerprintView(
                    fingerprint: model.visualSummaries[record.sessionID]?.fingerprint
                )

                if let observation = model.visualSummaries[record.sessionID]?.observation {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(PerformanceTheme.accent)
                            .padding(.top, 1)
                        Text(observation.sentence)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .performanceCard()
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Opens the session overview")
        .onAppear {
            model.requestVisualSummary(for: record.sessionID)
        }
    }
}

/// One compact history row: date on the left, recorded stats on the right,
/// fingerprint underneath. Never shows a UUID.
struct RecentSessionRow: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel
    @Environment(\.dynamicTypeSize) private var textSize
    let record: FileSessionRepository.SessionRecord

    var body: some View {
        let rowLayout = textSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        NavigationLink(value: record.sessionID) {
            VStack(alignment: .leading, spacing: 10) {
                rowLayout {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SessionRowFormatting.dayLabel(record.startedAt))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PerformanceTheme.primaryText)
                        Text(
                            "\(SessionRowFormatting.timeLabel(record.startedAt)) · "
                                + SessionRowFormatting.typeAndSource(record)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if !record.isManualEntry {
                            Text(SessionRowFormatting.state(record).label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !textSize.isAccessibilitySize { Spacer() }
                    VStack(alignment: textSize.isAccessibilitySize ? .leading : .trailing, spacing: 1) {
                        Text(SessionRowFormatting.durationLabel(
                            SessionRowFormatting.summaryDuration(record)
                        ))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(PerformanceTheme.primaryText)
                        Text(
                            SessionRowFormatting.distanceLabel(
                                meters: SessionRowFormatting.summaryDistance(record)
                            ) + "  ·  " + SessionRowFormatting.heartRateLabel(
                                SessionRowFormatting.summaryAverageHeartRate(record)
                            )
                        )
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    }
                }

                SessionFingerprintView(
                    fingerprint: model.visualSummaries[record.sessionID]?.fingerprint
                )
                .frame(height: 24, alignment: .bottom)
            }
            .performanceCard(padding: 14)
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Opens the session overview")
        .onAppear {
            model.requestVisualSummary(for: record.sessionID)
        }
    }
}

/// Completed / Interrupted / Incomplete tag. Color never carries the meaning
/// alone; the text always names the state.
struct StateTag: View {
    let state: SessionRowFormatting.SessionState

    var body: some View {
        Text(state.label)
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
            .accessibilityAddTraits(.isStaticText)
    }

    private var tint: Color {
        switch state {
        case .completed: return PerformanceTheme.accent
        case .interrupted, .incompletePackage: return PerformanceTheme.warning
        }
    }
}

/// A labeled stat used on cards. Values are pre-formatted; missing evidence
/// arrives already rendered as "—".
struct StatBlock: View {
    let value: String
    let caption: String
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PerformanceTheme.primaryText)
                .lineLimit(textSize.isAccessibilitySize ? nil : 1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Every session, compact rows. Reached through "See all".
struct AllSessionsView: View {
    @EnvironmentObject private var model: PhoneSessionLibraryModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.sessions) { record in
                    RecentSessionRow(record: record)
                }
            }
            .padding(.horizontal, PerformanceTheme.screenInset)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("All sessions")
        .navigationBarTitleDisplayMode(.inline)
    }
}
