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
        let minutes: Double
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
        let acuteMinutes: Double
        /// Average weekly minutes over the 28 days before the last seven.
        /// `nil` when that window holds no sessions.
        let chronicWeeklyMinutes: Double?

        var thisWeek: WeekBucket? { weeks.last }

        /// Acute:chronic load ratio. Around 0.8–1.3 is a steady build.
        var loadRatio: Double? {
            guard let chronicWeeklyMinutes, chronicWeeklyMinutes > 0 else { return nil }
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

    /// Minutes for one session: the recorded or entered duration, otherwise
    /// the span between start and end.
    static func minutes(_ record: FileSessionRepository.SessionRecord) -> Double {
        if let seconds = record.completion.summary?.duration?.value, seconds.isFinite, seconds > 0 {
            return seconds / 60
        }
        return max(0, record.completion.endedAt.timeIntervalSince(record.startedAt) / 60)
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
        for record in records where record.startedAt <= now {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: record.startedAt)?.start else { continue }
            grouped[start, default: []].append(record)
        }

        let weeks = weekStarts.map { start -> WeekBucket in
            let inWeek = grouped[start] ?? []
            let distances = inWeek.compactMap { $0.completion.summary?.distance?.value }
            return WeekBucket(
                weekStart: start,
                sessionCount: inWeek.count,
                minutes: inWeek.reduce(0) { $0 + minutes($1) },
                distanceMeters: distances.isEmpty ? nil : distances.reduce(0, +)
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

        let day: TimeInterval = 86_400
        let acuteStart = now.addingTimeInterval(-7 * day)
        let chronicStart = now.addingTimeInterval(-35 * day)
        let last28Start = now.addingTimeInterval(-28 * day)

        var acute = 0.0
        var chronic = 0.0
        var chronicSessions = 0
        var last28 = 0
        for record in records where record.startedAt <= now {
            let played = minutes(record)
            if record.startedAt > acuteStart {
                acute += played
            } else if record.startedAt > chronicStart {
                chronic += played
                chronicSessions += 1
            }
            if record.startedAt > last28Start { last28 += 1 }
        }

        return TrainingSnapshot(
            weeks: weeks,
            sessionsLast28Days: last28,
            streakWeeks: streak,
            acuteMinutes: acute,
            chronicWeeklyMinutes: chronicSessions > 0 ? chronic / 4 : nil
        )
    }

    // MARK: - Tips across sessions

    /// Ranked tips from the whole history. `records` are newest first, as
    /// the library publishes them.
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
        if let ratio = snapshot.loadRatio, let chronic = snapshot.chronicWeeklyMinutes {
            if ratio > 1.5 {
                tips.append(Tip(
                    id: "load-spike",
                    focus: .load,
                    tone: .caution,
                    title: "Your load jumped this week",
                    evidence: "\(Int(snapshot.acuteMinutes.rounded())) min in the last 7 days against a usual \(Int(chronic.rounded())) min a week. Sudden spikes are when muscle injuries tend to happen.",
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
                    evidence: "\(Int(snapshot.acuteMinutes.rounded())) min in the last 7 days against a usual \(Int(chronic.rounded())) min a week.",
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
            let heartRate = latest.completion.summary?.averageHeartRate?.value

            var workRateDelta: Double?
            if case .established(let base, _) = distanceBaseline, base > 0, let workRate {
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
                  first > 0 else { return nil }
            return (first - second) / first
        }
    }

    /// Max heart rate from age (Tanaka: 208 − 0.7 × age) when known, else the
    /// higher of the highest recorded reading and a conservative 190 bpm.
    static func heartRateMax(age: Int?, observedPeak: Double?) -> Double {
        if let age, (10...90).contains(age) {
            return 208 - 0.7 * Double(age)
        }
        return max(observedPeak ?? 0, 190)
    }

    static func insights(
        for detail: FileSessionRepository.SessionDetail,
        age: Int?
    ) -> SessionInsights {
        let heartRate = detail.heartRateSnapshots
            .map { (timestamp: $0.timestamp, bpm: $0.value) }
            .filter { $0.bpm > 0 }
            .sorted { $0.timestamp < $1.timestamp }
        let peak = heartRate.map(\.bpm).max()
        let maxHeartRate = heartRateMax(age: age, observedPeak: peak)

        let zones = zoneShares(heartRate: heartRate, heartRateMax: maxHeartRate)
        let halves = halfDistancePerMinute(detail)

        var effortCount: Int?
        var medianRecovery: Double?
        if heartRate.count >= 2 {
            let workRest = SessionAnalystV1.workRest(heartRate: heartRate, high: 0.85 * maxHeartRate)
            effortCount = workRest.highIntensityEffortCount
            medianRecovery = workRest.medianRecoveryBetweenEffortsS
        }

        var insights = SessionInsights(
            heartRateMax: maxHeartRate,
            zones: zones,
            peakHeartRate: peak,
            firstHalfDistancePerMinute: halves?.first,
            secondHalfDistancePerMinute: halves?.second,
            highIntensityEffortCount: effortCount,
            medianRecoveryBetweenEffortsS: medianRecovery,
            sprintCount: detail.sprintEvents.count
        )
        insights.takeaways = takeaways(for: insights)
        return insights
    }

    /// Time-weighted seconds per zone. Gaps over two minutes are missing
    /// evidence and count toward no zone.
    static func zoneShares(
        heartRate: [(timestamp: Date, bpm: Double)],
        heartRateMax: Double
    ) -> [ZoneShare] {
        var seconds = [Double](repeating: 0, count: 5)
        if heartRateMax > 0 {
            for index in heartRate.indices.dropFirst() {
                let interval = heartRate[index].timestamp.timeIntervalSince(heartRate[index - 1].timestamp)
                guard interval > 0, interval <= 120 else { continue }
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

    /// Distance per minute in each half of the recorded distance span, from
    /// cumulative distance snapshots. `nil` when either half is under five
    /// minutes or has too few readings to compare.
    static func halfDistancePerMinute(
        _ detail: FileSessionRepository.SessionDetail
    ) -> (first: Double, second: Double)? {
        let points = detail.distanceSnapshots
            .filter { $0.timestamp >= detail.record.startedAt }
            .sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 4, let firstPoint = points.first, let lastPoint = points.last else { return nil }
        let span = lastPoint.timestamp.timeIntervalSince(firstPoint.timestamp)
        guard span >= 600 else { return nil }
        let midpoint = firstPoint.timestamp.addingTimeInterval(span / 2)
        guard let middle = points.last(where: { $0.timestamp <= midpoint }) else { return nil }

        let firstMinutes = middle.timestamp.timeIntervalSince(firstPoint.timestamp) / 60
        let secondMinutes = lastPoint.timestamp.timeIntervalSince(middle.timestamp) / 60
        guard firstMinutes >= 5, secondMinutes >= 5 else { return nil }
        let firstMeters = max(0, middle.value - firstPoint.value)
        let secondMeters = max(0, lastPoint.value - middle.value)
        return (firstMeters / firstMinutes, secondMeters / secondMinutes)
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
                    evidence: "Only \(percent)% of the session was above 80% of your max heart rate. Football rewards repeated high-intensity actions.",
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
                    evidence: "\(percent)% of the session was above 80% of your max heart rate. A bigger aerobic base lets you recover between efforts.",
                    drill: Drill(
                        name: "Zone 2 base run",
                        prescription: "Once a week: 30–40 min at an easy, conversational pace (about 60–70% of max heart rate)."
                    ),
                    priority: 15
                ))
            }
        }

        if let recovery = insights.medianRecoveryBetweenEffortsS,
           let efforts = insights.highIntensityEffortCount, efforts >= 3, recovery > 90 {
            tips.append(Tip(
                id: "session-slow-recovery",
                focus: .recovery,
                tone: .improve,
                title: "Recover faster between efforts",
                evidence: "\(efforts) hard efforts, with a typical \(Int(recovery.rounded())) s before the next one.",
                drill: Drill(
                    name: "Short-rest repeats",
                    prescription: "3 sets of 6 × 30 m sprints with only 25 s recovery between reps and 3 min between sets."
                ),
                priority: 25
            ))
        }

        return Array(tips.sorted { $0.priority < $1.priority }.prefix(3))
    }
}
