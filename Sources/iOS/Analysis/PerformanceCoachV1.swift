import Foundation

/// Turns the player's own sessions into training load, consistency, and
/// concrete ways to improve physically.
///
/// Everything here is deterministic and rule-based so every tip can show the
/// numbers it rests on. Personal tips cite the player's recorded values;
/// general football-fitness guidance is labelled as such and only fills in
/// when the player's data has nothing more specific to say.
enum PerformanceCoachV1 {

    // MARK: - Types

    struct WeekBucket: Identifiable, Equatable, Sendable {
        let weekStart: Date
        let sessionCount: Int
        let minutes: Double?
        /// `nil` when no session that week recorded distance.
        let distanceMeters: Double?

        var id: Date { weekStart }
    }

    struct TrainingSnapshot: Equatable, Sendable {
        /// Oldest first; the last bucket is the current week.
        let weeks: [WeekBucket]
        let sessionsLast28Days: Int
        /// Consecutive weeks with at least one session. The current week
        /// does not break a streak until it is over.
        let streakWeeks: Int
        /// Minutes played in the last seven days.
        let acuteMinutes: Double?
        /// Average weekly minutes over the 28 days before the last seven.
        /// `nil` when that window holds no sessions.
        let chronicWeeklyMinutes: Double?

        var thisWeek: WeekBucket? { weeks.last }

        /// Acute:chronic load ratio. Around 0.8–1.3 is a steady build.
        var loadRatio: Double? {
            guard let acuteMinutes, let chronicWeeklyMinutes, chronicWeeklyMinutes >= 30 else { return nil }
            return acuteMinutes / chronicWeeklyMinutes
        }
    }

    enum Focus: String, Sendable {
        case consistency
        case load
        case recovery
        case endurance
        case intensity
        case speed
        case strength
        case workRate

        var title: String {
            switch self {
            case .consistency: return "Consistency"
            case .load: return "Training load"
            case .recovery: return "Recovery"
            case .endurance: return "Endurance"
            case .intensity: return "Intensity"
            case .speed: return "Speed"
            case .strength: return "Strength"
            case .workRate: return "Work rate"
            }
        }

        var symbolName: String {
            switch self {
            case .consistency: return "calendar"
            case .load: return "gauge.with.dots.needle.67percent"
            case .recovery: return "bed.double.fill"
            case .endurance: return "lungs.fill"
            case .intensity: return "flame.fill"
            case .speed: return "bolt.fill"
            case .strength: return "figure.strengthtraining.traditional"
            case .workRate: return "figure.run"
            }
        }
    }

    enum Tone: Sendable {
        /// Something is going well; keep doing it.
        case positive
        /// A clear opportunity to get better.
        case improve
        /// Back off or protect yourself.
        case caution
    }

    struct Drill: Equatable, Sendable {
        let name: String
        let prescription: String
    }

    struct Tip: Identifiable, Equatable, Sendable {
        let id: String
        let focus: Focus
        let tone: Tone
        let title: String
        /// Why this tip appears. Personal tips quote recorded numbers.
        let evidence: String
        let drill: Drill?
        /// Lower sorts first.
        let priority: Int
        /// `true` when the tip is general guidance, not derived from the
        /// player's own recordings.
        var isGeneral: Bool = false
    }

    // MARK: - Session basics

    static func minutes(_ record: FileSessionRepository.SessionRecord) -> Double? {
        record.recordedDurationSeconds.map { $0 / 60 }
    }

    // MARK: - Load and consistency

    static func snapshot(
        records: [FileSessionRepository.SessionRecord],
        now: Date = .now,
        weekCount: Int = 8,
        calendar: Calendar = .current
    ) -> TrainingSnapshot {
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        let weekStarts: [Date] = (0..<max(1, weekCount)).reversed().compactMap { offset in
            calendar.date(byAdding: .weekOfYear, value: -offset, to: currentWeekStart)
        }

        var grouped: [Date: [FileSessionRepository.SessionRecord]] = [:]
        for record in records where record.startedAt <= now && record.completion.lifecycle == .completed {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: record.startedAt)?.start else { continue }
            grouped[start, default: []].append(record)
        }

        let weeks = weekStarts.map { start -> WeekBucket in
            let inWeek = grouped[start] ?? []
            let durations = inWeek.compactMap { minutes($0) }
            let distances = inWeek.compactMap { $0.completion.summary?.distance?.value }
            return WeekBucket(
                weekStart: start,
                sessionCount: inWeek.count,
                minutes: durations.count == inWeek.count ? durations.reduce(0, +) : nil,
                distanceMeters: distances.isEmpty || distances.count != inWeek.count ? nil : distances.reduce(0, +)
            )
        }

        // Streak over every week with sessions, not only the charted ones.
        var streak = 0
        var cursor = currentWeekStart
        if grouped[cursor]?.isEmpty ?? true,
           let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) {
            cursor = previous
        }
        while !(grouped[cursor]?.isEmpty ?? true) {
            streak += 1
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previous
        }

        let today = calendar.startOfDay(for: now)
        let acuteStart = calendar.date(byAdding: .day, value: -6, to: today)!
        let chronicStart = calendar.date(byAdding: .day, value: -34, to: today)!
        let last28Start = calendar.date(byAdding: .day, value: -27, to: today)!

        var acute = 0.0
        var chronic = 0.0
        var chronicWeeks = Set<Int>()
        var acuteComplete = true
        var chronicComplete = true
        var last28 = 0
        for record in records where record.startedAt <= now && record.completion.lifecycle == .completed {
            if record.startedAt >= last28Start { last28 += 1 }
            let played = minutes(record)
            if record.startedAt >= acuteStart {
                if let played { acute += played } else { acuteComplete = false }
            } else if record.startedAt >= chronicStart {
                guard let played else { chronicComplete = false; continue }
                chronic += played
                guard played >= 10 else { continue }
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: record.startedAt), to: acuteStart).day ?? 0
                chronicWeeks.insert((days - 1) / 7)
            }
        }

        return TrainingSnapshot(
            weeks: weeks,
            sessionsLast28Days: last28,
            streakWeeks: streak,
            acuteMinutes: acuteComplete ? acute : nil,
            chronicWeeklyMinutes: chronicComplete && chronicWeeks.count >= 3 && chronic / 4 >= 30 ? chronic / 4 : nil
        )
    }

    // MARK: - Tips across sessions

    /// Ranked tips from the whole history. `records` are newest first, as
    /// the library publishes them.
    static func comparisonNotes(records: [FileSessionRepository.SessionRecord]) -> [String] {
        guard let latest = records.first(where: BaselineEngineV1.isValidSession) else { return [] }
        var notes: [String] = []
        if BaselineEngineV1.distancePerMinute(latest) == nil {
            notes.append("Work-rate comparison unavailable — distance coverage is limited or may be undercounted.")
        }
        if BaselineEngineV1.averageHeartRate(latest) == nil {
            notes.append("HR comparison unavailable — regular samples and at least 70% whole-session coverage are needed.")
        }
        return notes
    }

    static func tips(
        records: [FileSessionRepository.SessionRecord],
        snapshot: TrainingSnapshot,
        includeGeneral: Bool = true
    ) -> [Tip] {
        guard !records.isEmpty else { return [] }
        var tips: [Tip] = []

        // Consistency.
        let recent = snapshot.sessionsLast28Days
        if recent < 4 {
            tips.append(Tip(
                id: "consistency-build",
                focus: .consistency,
                tone: .improve,
                title: "Build a twice-a-week rhythm",
                evidence: "\(recent) \(recent == 1 ? "session" : "sessions") in the last 4 weeks. Football fitness builds from regular exposure, so two or more sessions a week moves the needle fastest.",
                drill: Drill(
                    name: "Add a 25-minute conditioning day",
                    prescription: "On a non-football day: 10 min easy jog, 6 × 30 s strides with 90 s walk back, 5 min easy cool-down."
                ),
                priority: 20
            ))
        } else if recent >= 8 {
            tips.append(Tip(
                id: "consistency-strong",
                focus: .consistency,
                tone: .positive,
                title: "Consistency is your superpower",
                evidence: "\(recent) sessions in the last 4 weeks. Keep at least one lighter day between hard ones so the work turns into fitness.",
                drill: nil,
                priority: 60
            ))
        }

        // Load spikes and drops.
        if let ratio = snapshot.loadRatio, let chronic = snapshot.chronicWeeklyMinutes, let acute = snapshot.acuteMinutes {
            if ratio > 1.5 {
                tips.append(Tip(
                    id: "load-spike",
                    focus: .load,
                    tone: .caution,
                    title: "Your load jumped in the last 7 days",
                    evidence: "\(Int(acute.rounded())) min in the last 7 days against a usual \(Int(chronic.rounded())) min a week. Sudden spikes are when muscle injuries tend to happen.",
                    drill: Drill(
                        name: "Protect the next 48 hours",
                        prescription: "Keep the next session light, or swap it for 20 min mobility and an easy bike. Aim for 8+ hours of sleep."
                    ),
                    priority: 10
                ))
            } else if ratio < 0.5, chronic >= 60 {
                tips.append(Tip(
                    id: "load-drop",
                    focus: .load,
                    tone: .improve,
                    title: "Ease back in after a quiet week",
                    evidence: "\(Int(acute.rounded())) min in the last 7 days against a usual \(Int(chronic.rounded())) min a week.",
                    drill: Drill(
                        name: "Rebuild gradually",
                        prescription: "Return at about 70% of your usual minutes this week, then add roughly 10% a week."
                    ),
                    priority: 30
                ))
            }
        }

        // Work rate and heart-rate efficiency against the personal baseline.
        if let latest = records.first(where: BaselineEngineV1.isValidSession) {
            let pool = records.filter { $0.sessionID != latest.sessionID }
            let distanceBaseline = BaselineEngineV1.baseline(
                for: .distancePerMinute,
                priorSessions: pool,
                currentStartedAt: latest.startedAt
            )
            let heartRateBaseline = BaselineEngineV1.baseline(
                for: .averageHeartRate,
                priorSessions: pool,
                currentStartedAt: latest.startedAt
            )
            let workRate = BaselineEngineV1.distancePerMinute(latest)
            let heartRate = BaselineEngineV1.averageHeartRate(latest)

            var workRateDelta: Double?
            if case .established(let base, _) = distanceBaseline, base >= 40, let workRate {
                workRateDelta = (workRate - base) / base
                let percent = Int((abs(workRateDelta ?? 0) * 100).rounded())
                if let delta = workRateDelta, delta < -0.08 {
                    tips.append(Tip(
                        id: "work-rate-down",
                        focus: .workRate,
                        tone: .improve,
                        title: "Lift your work rate",
                        evidence: "Your latest session covered \(Int(workRate.rounded())) m/min, \(percent)% below your baseline of \(Int(base.rounded())) m/min.",
                        drill: Drill(
                            name: "Tempo intervals",
                            prescription: "Twice a week: 6 × 3 min at a hard but steady pace (you can say a few words), 90 s easy jog between."
                        ),
                        priority: 15
                    ))
                } else if let delta = workRateDelta, delta > 0.08 {
                    tips.append(Tip(
                        id: "work-rate-up",
                        focus: .workRate,
                        tone: .positive,
                        title: "Work rate is up",
                        evidence: "\(Int(workRate.rounded())) m/min in your latest session, \(percent)% above your baseline of \(Int(base.rounded())) m/min.",
                        drill: nil,
                        priority: 50
                    ))
                }
            }

            if case .established(let baseHeartRate, _) = heartRateBaseline, baseHeartRate > 0,
               let heartRate, let workRateDelta {
                let heartRateDelta = (heartRate - baseHeartRate) / baseHeartRate
                if workRateDelta >= -0.03, heartRateDelta <= -0.03 {
                    tips.append(Tip(
                        id: "engine-fitter",
                        focus: .endurance,
                        tone: .positive,
                        title: "Your engine is getting fitter",
                        evidence: "You covered as much ground or more at \(Int(heartRate.rounded())) bpm on average, below your usual \(Int(baseHeartRate.rounded())) bpm.",
                        drill: nil,
                        priority: 40
                    ))
                } else if heartRateDelta > 0.05, workRateDelta < 0 {
                    tips.append(Tip(
                        id: "heart-rate-high",
                        focus: .recovery,
                        tone: .caution,
                        title: "Heart rate ran high for the work done",
                        evidence: "Average \(Int(heartRate.rounded())) bpm against a usual \(Int(baseHeartRate.rounded())) bpm, while covering less ground. Fatigue, heat, or poor sleep are common causes.",
                        drill: Drill(
                            name: "Recovery day",
                            prescription: "20–30 min of very easy movement, plenty of fluids, and a full night's sleep before your next hard session."
                        ),
                        priority: 12
                    ))
                }
            }
        }

        if includeGeneral {
            tips.append(contentsOf: generalTips)
        }

        return tips.sorted { $0.priority < $1.priority }
    }

    /// Foundations every footballer benefits from. Shown after personal tips.
    static let generalTips: [Tip] = [
        Tip(
            id: "general-repeated-sprints",
            focus: .speed,
            tone: .improve,
            title: "Train repeated sprints",
            evidence: "Matches are decided by how well you repeat short sprints late on.",
            drill: Drill(
                name: "Repeated-sprint sets",
                prescription: "Once a week after a warm-up: 2 sets of 6 × 20–30 m sprints, 20 s walk between reps, 4 min between sets."
            ),
            priority: 70,
            isGeneral: true
        ),
        Tip(
            id: "general-strength",
            focus: .strength,
            tone: .improve,
            title: "Strength protects your hamstrings",
            evidence: "Eccentric hamstring work is one of the best-supported ways to cut muscle injuries in football.",
            drill: Drill(
                name: "Injury-proofing circuit",
                prescription: "Twice a week: 3 × 5 Nordic hamstring curls, 3 × 8 split squats each leg, 3 × 30 s Copenhagen plank each side."
            ),
            priority: 80,
            isGeneral: true
        ),
    ]

    // MARK: - One session

    struct ZoneShare: Identifiable, Equatable, Sendable {
        /// 1 (easy) ... 5 (max).
        let zone: Int
        let seconds: Double

        var id: Int { zone }

        var name: String {
            switch zone {
            case 1: return "Easy"
            case 2: return "Steady"
            case 3: return "Tempo"
            case 4: return "Hard"
            default: return "Max"
            }
        }

        /// Fraction of max heart rate where the zone starts.
        var lowerFraction: Double {
            switch zone {
            case 1: return 0
            case 2: return 0.6
            case 3: return 0.7
            case 4: return 0.8
            default: return 0.9
            }
        }
    }

    struct SessionInsights: Equatable, Sendable {
        let heartRateMax: Double
        /// Five entries, zone 1 first. All zero when no heart rate exists.
        let zones: [ZoneShare]
        let peakHeartRate: Double?
        let firstHalfDistancePerMinute: Double?
        let secondHalfDistancePerMinute: Double?
        let highIntensityEffortCount: Int?
        let medianRecoveryBetweenEffortsS: Double?
        let sprintCount: Int
        let evidenceNotes: [String]
        var takeaways: [Tip] = []

        var zoneSeconds: Double { zones.reduce(0) { $0 + $1.seconds } }

        /// Share of heart-rate time at or above 80% of max.
        var highIntensityShare: Double? {
            let total = zoneSeconds
            guard total > 0 else { return nil }
            return zones.filter { $0.zone >= 4 }.reduce(0) { $0 + $1.seconds } / total
        }

        /// Positive when the second half was slower than the first.
        var workRateFade: Double? {
            guard let first = firstHalfDistancePerMinute, let second = secondHalfDistancePerMinute,
                  first >= 40 else { return nil }
            return (first - second) / first
        }
    }

    static func heartRateMax(age: Int?, observedPeak: Double?) -> Double {
        if let age, (10...90).contains(age) {
            return 208 - 0.7 * Double(age)
        }
        return 190
    }

    static func insights(
        for detail: FileSessionRepository.SessionDetail,
        age: Int?
    ) -> SessionInsights {
        let record = detail.record
        let heartSamples = detail.heartRateSnapshots.map { (timestamp: $0.timestamp, value: $0.value) }
        let distanceSamples = detail.distanceSnapshots.map { (timestamp: $0.timestamp, value: $0.value) }
        let lastRecordedAt = record.evidence?.durationSeconds.map { record.startedAt.addingTimeInterval($0) }
            ?? (detail.heartRateSnapshots + detail.distanceSnapshots).map(\.timestamp).max()
        let evidence = SessionEvidenceV1.evaluate(
            envelope: record.sessionEnvelope, completion: record.completion, lastRecordedAt: lastRecordedAt,
            heartRate: heartSamples, distance: distanceSamples
        )
        let heartRate = SessionEvidenceV1.acceptedHeartRate(
            heartSamples, start: record.startedAt, duration: evidence.durationSeconds ?? 0
        ).map { (timestamp: $0.timestamp, bpm: $0.value) }
        let peak = heartRate.map(\.bpm).max()
        let maxHeartRate = heartRateMax(age: age, observedPeak: peak)
        let zones = evidence.hasWholeSessionHeartRate
            ? zoneShares(heartRate: heartRate, heartRateMax: maxHeartRate) : []
        let halves = record.completion.lifecycle == .completed ? halfDistancePerMinute(detail) : nil

        var effortCount: Int?
        var effortInterval: Double?
        if evidence.hasEffortCoverage {
            let workRest = SessionAnalystV1.workRest(heartRate: heartRate, high: 0.85 * maxHeartRate)
            effortCount = workRest.highIntensityEffortCount
            effortInterval = workRest.medianRecoveryBetweenEffortsS
        }
        var notes: [String] = []
        if record.completion.lifecycle != .completed {
            notes.append("Interrupted recording — only recorded time is shown. This fragment does not count as an outing or support coaching comparisons.")
        } else {
            if !evidence.hasWholeSessionHeartRate {
                notes.append("HR coverage is too sparse or starts too late. Zones need at least 50% of the session clock and 60 accepted samples.")
            }
            if evidence.averageHeartRate == nil {
                notes.append("HR comparison unavailable — needs at least 70% coverage and regular samples. Readings above 200 bpm are excluded from coaching.")
            }
            if !evidence.hasEffortCoverage {
                notes.append("Hard efforts unavailable — needs regular HR samples, at least 80% coverage, and gaps capped at 20 seconds.")
            }
            if halves == nil {
                notes.append("Distance coverage is too limited for work-rate or fade advice. Both halves need coverage without gaps over 2 minutes; very low recorded distance may be undercounted.")
            }
        }

        var insights = SessionInsights(
            heartRateMax: maxHeartRate,
            zones: zones,
            peakHeartRate: peak,
            firstHalfDistancePerMinute: halves?.first,
            secondHalfDistancePerMinute: halves?.second,
            highIntensityEffortCount: effortCount,
            medianRecoveryBetweenEffortsS: effortInterval,
            sprintCount: detail.sprintEvents.count,
            evidenceNotes: notes
        )
        insights.takeaways = takeaways(for: insights)
        return insights
    }

    static func zoneShares(
        heartRate: [(timestamp: Date, bpm: Double)],
        heartRateMax: Double
    ) -> [ZoneShare] {
        var seconds = [Double](repeating: 0, count: 5)
        if heartRateMax > 0 {
            for index in heartRate.indices.dropFirst() {
                let interval = heartRate[index].timestamp.timeIntervalSince(heartRate[index - 1].timestamp)
                guard interval > 0, interval <= 90 else { continue }
                let fraction = heartRate[index - 1].bpm / heartRateMax
                let zone: Int
                switch fraction {
                case ..<0.6: zone = 0
                case ..<0.7: zone = 1
                case ..<0.8: zone = 2
                case ..<0.9: zone = 3
                default: zone = 4
                }
                seconds[zone] += interval
            }
        }
        return seconds.enumerated().map { ZoneShare(zone: $0.offset + 1, seconds: $0.element) }
    }

    static func halfDistancePerMinute(
        _ detail: FileSessionRepository.SessionDetail
    ) -> (first: Double, second: Double)? {
        let start = detail.record.startedAt
        guard let duration = detail.record.evidence?.durationSeconds,
              detail.record.completion.lifecycle == .completed,
              let points = SessionEvidenceV1.distancePoints(
                detail.distanceSnapshots.map { ($0.timestamp, $0.value) }, start: start, duration: duration
              ), let first = points.first, let last = points.last else { return nil }
        let midpoint = start.addingTimeInterval(duration / 2)
        guard let before = points.last(where: { $0.timestamp <= midpoint }),
              let after = points.first(where: { $0.timestamp >= midpoint }) else { return nil }
        let interval = after.timestamp.timeIntervalSince(before.timestamp)
        let fraction = interval > 0 ? midpoint.timeIntervalSince(before.timestamp) / interval : 0
        let middleMeters = before.value + (after.value - before.value) * fraction
        let halfMinutes = duration / 120
        let firstRate = (middleMeters - first.value) / halfMinutes
        let secondRate = (last.value - middleMeters) / halfMinutes
        guard firstRate >= 40, secondRate >= 40 else { return nil }
        return (firstRate, secondRate)
    }

    static func takeaways(for insights: SessionInsights) -> [Tip] {
        var tips: [Tip] = []

        if let fade = insights.workRateFade,
           let first = insights.firstHalfDistancePerMinute,
           let second = insights.secondHalfDistancePerMinute {
            if fade > 0.15 {
                tips.append(Tip(
                    id: "session-fade",
                    focus: .endurance,
                    tone: .improve,
                    title: "You faded in the second half",
                    evidence: "Distance per minute dropped from \(Int(first.rounded())) to \(Int(second.rounded())) m/min (−\(Int((fade * 100).rounded()))%).",
                    drill: Drill(
                        name: "4 × 4 intervals",
                        prescription: "Twice a week: 4 × 4 min hard running at about 85–90% of max heart rate, 3 min easy jog between. Builds the engine that holds pace late."
                    ),
                    priority: 10
                ))
            } else if fade < 0.05 {
                tips.append(Tip(
                    id: "session-held-pace",
                    focus: .endurance,
                    tone: .positive,
                    title: "You held your pace",
                    evidence: "\(Int(first.rounded())) m/min in the first half, \(Int(second.rounded())) m/min in the second.",
                    drill: nil,
                    priority: 50
                ))
            }
        }

        let coveredMinutes = insights.zoneSeconds / 60
        if let share = insights.highIntensityShare, coveredMinutes >= 20 {
            let percent = Int((share * 100).rounded())
            if share < 0.10 {
                tips.append(Tip(
                    id: "session-low-intensity",
                    focus: .intensity,
                    tone: .improve,
                    title: "Push harder in short bursts",
                    evidence: "Only \(percent)% of recorded HR time was above 80% of your max heart rate. Football rewards repeated high-intensity actions.",
                    drill: Drill(
                        name: "15-45 sprints",
                        prescription: "Twice a week: 2 sets of 8 × 15 s fast running, 45 s jog between, 3 min rest between sets."
                    ),
                    priority: 20
                ))
            } else if share > 0.45 {
                tips.append(Tip(
                    id: "session-high-intensity",
                    focus: .endurance,
                    tone: .caution,
                    title: "A lot of time in the red",
                    evidence: "\(percent)% of recorded HR time was above 80% of your max heart rate. A bigger aerobic base lets you recover between efforts.",
                    drill: Drill(
                        name: "Zone 2 base run",
                        prescription: "Once a week: 30–40 min at an easy, conversational pace (about 60–70% of max heart rate)."
                    ),
                    priority: 15
                ))
            }
        }

        return Array(tips.sorted { $0.priority < $1.priority }.prefix(3))
    }
}
