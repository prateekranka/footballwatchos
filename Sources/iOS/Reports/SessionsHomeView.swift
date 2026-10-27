import SwiftUI

private enum SessionHistoryDestination: Hashable {
    case allSessions
}

/// The Sessions destination: this week's load as the hero, one focus to
/// work on next, then the latest session and recent history.
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

    private var snapshot: PerformanceCoachV1.TrainingSnapshot {
        PerformanceCoachV1.snapshot(records: model.sessions)
    }

    private var focusTip: PerformanceCoachV1.Tip? {
        PerformanceCoachV1.tips(records: model.sessions, snapshot: snapshot).first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PerformanceTheme.sectionSpacing) {
                header

                if model.isLibraryLoading {
                    ProgressView("Loading sessions")
                        .frame(maxWidth: .infinity, minHeight: 160)
                        .accessibilityIdentifier("sessions-loading")
                } else if let latest {
                    WeekHeroCard(snapshot: snapshot)
                    actions
                    if let focusTip {
                        focusSection(focusTip)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Latest session")
                        LatestSessionCard(record: latest)
                    }
                    if !recent.isEmpty {
                        recentSection
                    } else {
                        seeAllLink
                    }
                } else {
                    emptyState
                    actions
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
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, model.hasLoadedSessions else { return }
            Task {
                await model.refresh()
                await model.prepareVisualSummaries(budget: 1)
            }
        }
    }

    private var header: some View {
        Text("Sessions")
            .font(PerformanceTheme.screenTitle)
            .foregroundStyle(PerformanceTheme.primaryText)
            .accessibilityAddTraits(.isHeader)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button { showsAddSession = true } label: {
                Label("Add session", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundStyle(PerformanceTheme.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(PerformanceTheme.accent)
            .accessibilityIdentifier("add-session")

            SyncStatusPill()
        }
    }

    private func focusSection(_ tip: PerformanceCoachV1.Tip) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Your focus")
                NavigationLink {
                    CoachingPlanView()
                } label: {
                    Text("Full plan")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(PerformanceTheme.accent)
                }
                .buttonStyle(PressableStyle())
                .fixedSize()
            }
            CoachTipCard(tip: tip)
        }
    }

    private var seeAllLink: some View {
        NavigationLink(value: SessionHistoryDestination.allSessions) {
            Text("See all")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PerformanceTheme.accent)
        }
        .buttonStyle(PressableStyle())
        .accessibilityHint("Shows every session")
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Recent")
                seeAllLink
            }

            VStack(spacing: 10) {
                ForEach(recent) { record in
                    RecentSessionRow(record: record)
                }
            }
        }
    }

    private var waitingOnWatch: Int { model.watchStatus?.waiting ?? 0 }

    private var watchHasSessionsComing: Bool {
        model.isReceivingFromWatch || waitingOnWatch > 0
    }

    /// The title alone carries the state; the Add session button and the
    /// sync pill below it are the next steps.
    private var emptyStateTitle: String {
        if model.isReceivingFromWatch { return "Receiving your first session" }
        if waitingOnWatch > 0 {
            return waitingOnWatch == 1 ? "1 session on the way" : "\(waitingOnWatch) sessions on the way"
        }
        return "No sessions yet"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: watchHasSessionsComing ? "applewatch.radiowaves.left.and.right" : "figure.soccer")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(PerformanceTheme.highlight)
                .accessibilityHidden(true)
            Text(emptyStateTitle)
                .font(.title2.weight(.bold))
        }
        .heroSurface(padding: 22)
        .accessibilityElement(children: .combine)
    }
}

/// This week at a glance on the green hero surface: sessions, minutes,
/// distance, streak, and an eight-week minutes chart.
struct WeekHeroCard: View {
    @Environment(\.dynamicTypeSize) private var textSize
    let snapshot: PerformanceCoachV1.TrainingSnapshot

    var body: some View {
        let week = snapshot.thisWeek
        VStack(alignment: .leading, spacing: 16) {
            let headerLayout = textSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout())
            headerLayout {
                Text("THIS WEEK")
                    .font(.caption.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.8))
                if !textSize.isAccessibilitySize { Spacer() }
                if snapshot.streakWeeks > 0 {
                    Label(
                        "\(snapshot.streakWeeks)-week streak",
                        systemImage: "flame.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.18), in: Capsule())
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            AdaptiveMetricGroup {
                HeroStat(
                    value: week.map { "\($0.sessionCount)" } ?? "—",
                    caption: (week?.sessionCount ?? 0) == 1 ? "session" : "sessions",
                    emphasised: true
                )
                .accessibilityIdentifier("week-stat-sessions")
                HeroStat(value: week?.minutes.map { "\(Int($0.rounded()))" } ?? "—", caption: "minutes")
                    .accessibilityIdentifier("week-stat-minutes")
                HeroStat(
                    value: SessionRowFormatting.distanceLabel(meters: week?.distanceMeters),
                    caption: "distance"
                )
                .accessibilityIdentifier("week-stat-distance")
            }

            WeeklyLoadChart(weeks: snapshot.weeks, onHero: true)
                .frame(height: 96)
                .accessibilityIdentifier("week-load-chart")
        }
        .heroSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("week-hero")
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
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        NavigationLink(value: record.sessionID) {
            VStack(alignment: .leading, spacing: 14) {
                headerLayout {
                    if !textSize.isAccessibilitySize {
                        IconBadge(
                            systemName: record.sessionEnvelope.footballType.symbolName,
                            tint: PerformanceTheme.accent,
                            size: 40
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SessionRowFormatting.dayLabel(record.startedAt))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(PerformanceTheme.primaryText)
                        Text(
                            "\(SessionRowFormatting.timeLabel(record.startedAt)) · "
                                + SessionRowFormatting.typeAndSource(record)
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    if !textSize.isAccessibilitySize { Spacer() }
                    StateTag.ifNotCompleted(SessionRowFormatting.state(record))
                }

                AdaptiveMetricGroup {
                    StatBlock(
                        value: SessionRowFormatting.durationLabel(
                            SessionRowFormatting.summaryDuration(record)
                        ),
                        caption: "Duration",
                        icon: "timer"
                    )
                    StatBlock(
                        value: SessionRowFormatting.distanceLabel(
                            meters: SessionRowFormatting.summaryDistance(record)
                        ),
                        caption: "Distance",
                        icon: "point.topleft.down.to.point.bottomright.curvepath"
                    )
                    StatBlock(
                        value: SessionRowFormatting.heartRateLabel(
                            SessionRowFormatting.summaryAverageHeartRate(record)
                        ),
                        caption: "Avg heart rate",
                        icon: "heart.fill",
                        tint: PerformanceTheme.heartRate
                    )
                }

                SessionFingerprintView(
                    fingerprint: model.visualSummaries[record.sessionID]?.fingerprint
                )
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
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        NavigationLink(value: record.sessionID) {
            VStack(alignment: .leading, spacing: 10) {
                rowLayout {
                    if !textSize.isAccessibilitySize {
                        IconBadge(
                            systemName: record.sessionEnvelope.footballType.symbolName,
                            tint: record.isManualEntry ? Color.secondary : PerformanceTheme.accent,
                            size: 32
                        )
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(SessionRowFormatting.dayLabel(record.startedAt))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(PerformanceTheme.primaryText)
                            StateTag.ifNotCompleted(SessionRowFormatting.state(record))
                        }
                        Text(
                            "\(SessionRowFormatting.timeLabel(record.startedAt)) · "
                                + SessionRowFormatting.typeAndSource(record)
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    /// Completed is the normal case, so lists tag only the exceptions.
    @ViewBuilder
    static func ifNotCompleted(_ state: SessionRowFormatting.SessionState) -> some View {
        if state != .completed { StateTag(state: state) }
    }

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
    var icon: String?
    var tint: Color = PerformanceTheme.accent
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
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
