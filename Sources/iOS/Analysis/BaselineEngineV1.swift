import Foundation

/// Turns recorded snapshot series into bounded, gap-aware chart data.
///
/// Rendering optimizations live here so views receive ready-to-draw series.
/// Two rules matter for honesty:
/// 1. Points are decimated only after full-resolution values are read; the
///    decimation exists purely for rendering.
/// 2. The series is split into segments wherever a substantial time gap
///    occurs, so charts never draw a connecting line across missing
///    evidence.
enum ChartPreparationV1 {

    /// A run of consecutive samples with no substantial internal gap.
    struct Segment: Identifiable, Sendable, Equatable {
        let id: Int
        let points: [ChartSample]

        var startIndex: Int { points.first?.index ?? 0 }
    }

    /// One chart-ready sample.
    struct ChartSample: Identifiable, Sendable, Equatable {
        let id: Int
        /// Seconds from the start of the series' own time base.
        let seconds: Double
        let value: Double
        /// Index in the source series, kept so selection can map back.
        let index: Int
    }

    /// A gap longer than this ends the current segment. Heart-rate and
    /// distance snapshots arrive on the order of seconds; a two-minute hole
    /// is missing evidence, not a steep line.
    static let maximumGapSeconds: Double = 120

    /// Rendering cap per series.
    static let maximumPoints = 600

    /// Prepares a seconds-from-start series from dated snapshots.
    ///
    /// The result starts at t = 0 (first sample) and is split at gaps, then
    /// stride-decimated per segment if needed. When `relativeToStart` is
    /// false the caller must label the axis accordingly (used for motion
    /// time, which is relative to its own first recorded sample).
    static func segments(
        from snapshots: [(timestamp: Date, value: Double)],
        maximumGapSeconds: Double = ChartPreparationV1.maximumGapSeconds,
        maximumPoints: Int = ChartPreparationV1.maximumPoints
    ) -> [Segment] {
        guard !snapshots.isEmpty else { return [] }
        let sorted = snapshots.sorted { $0.timestamp < $1.timestamp }
        let origin = sorted[0].timestamp

        var runs: [[(timestamp: Date, value: Double)]] = [[sorted[0]]]
        for sample in sorted.dropFirst() {
            if sample.timestamp.timeIntervalSince(runs[runs.count - 1].last!.timestamp) > maximumGapSeconds {
                runs.append([sample])
            } else {
                runs[runs.count - 1].append(sample)
            }
        }

        var segments: [Segment] = []
        var globalIndex = 0
        for (segmentIndex, run) in runs.enumerated() {
            let chosen = decimate(run, maximumPoints: maximumPoints)
            guard !chosen.isEmpty else { continue }
            let samples = chosen.enumerated().map { offset, sample -> ChartSample in
                let index = globalIndex + offset
                return ChartSample(
                    id: index,
                    seconds: sample.timestamp.timeIntervalSince(origin),
                    value: sample.value,
                    index: index
                )
            }
            segments.append(Segment(id: segmentIndex, points: samples))
            globalIndex += chosen.count
        }
        return segments
    }

    /// Stride decimation inside one segment. Always keeps the first and last
    /// samples so segment shapes stay truthful at the edges.
    private static func decimate(
        _ run: [(timestamp: Date, value: Double)],
        maximumPoints: Int
    ) -> [(timestamp: Date, value: Double)] {
        guard run.count > maximumPoints else { return run }
        let stride = (run.count + maximumPoints - 1) / maximumPoints
        var chosen: [(timestamp: Date, value: Double)] = []
        chosen.reserveCapacity(maximumPoints + 1)
        var index = 0
        while index < run.count {
            chosen.append(run[index])
            index += stride
        }
        if chosen.last?.timestamp != run[run.count - 1].timestamp {
            chosen.append(run[run.count - 1])
        }
        return chosen
    }

    /// Mean value of the samples whose minute bucket matches `minute`.
    /// Returns `nil` when the minute has no samples.
    static func minuteMean(
        seconds: Double,
        in samples: [ChartSample]
    ) -> Double? {
        let bucket = Int(seconds / 60)
        let matching = samples.filter { Int($0.seconds / 60) == bucket }
        guard !matching.isEmpty else { return nil }
        return matching.map(\.value).reduce(0, +) / Double(matching.count)
    }
}

/// Personal Baseline computation from the player's own prior sessions.
///
/// Rules (documented product contract):
/// - The first three Valid Sessions establish the baseline.
/// - Later comparisons use the most recent prior Valid Sessions (up to four).
/// - The current session is never part of its own comparison pool; the caller
///   passes prior sessions only, and the engine re-checks the dates.
/// - A session is Valid when it completed, its duration was recorded,
///   its distance was recorded, and it lasted at least `minimumDurationSeconds`.
///   These are quality gates, not judgments about performance.
enum BaselineEngineV1 {

    /// Required Valid Sessions before a baseline exists.
    static let requiredValidSessions = 3

    /// Maximum prior sessions contributing once the baseline exists.
    static let maximumContributingSessions = 4

    /// A completed outing shorter than this is not representative of a
    /// Football Session for trend purposes.
    static let minimumDurationSeconds: Double = 600

    enum Measure: String, CaseIterable, Sendable, Identifiable {
        case distancePerMinute = "Distance per minute"
        case averageHeartRate = "Average heart rate"

        var id: String { rawValue }
    }

    /// Deterministic validity gate for baseline and trend work.
    static func isValidSession(_ record: FileSessionRepository.SessionRecord) -> Bool {
        guard record.completion.lifecycle == .completed else { return false }
        guard let summary = record.completion.summary else { return false }
        guard let duration = summary.duration, duration.value >= minimumDurationSeconds else { return false }
        guard summary.distance != nil else { return false }
        return true
    }

    /// Distance per minute for one session, from recorded summary values.
    /// Returns `nil` when either value is missing, so a missing metric is
    /// never displayed as zero.
    static func distancePerMinute(_ record: FileSessionRepository.SessionRecord) -> Double? {
        guard let summary = record.completion.summary,
              let distance = summary.distance?.value,
              let duration = summary.duration?.value,
              duration > 0, distance >= 0 else {
            return nil
        }
        return distance / duration * 60
    }

    enum BaselineStatus: Equatable, Sendable {
        /// Baseline established from `count` prior Valid Sessions.
        case established(valuePerMinute: Double, contributingCount: Int)
        /// Not enough Valid Sessions yet; neutral, non-judgmental state.
        case building(validCount: Int, required: Int)
        /// The measure has no usable evidence in any prior session.
        case unavailable
    }

    /// Baseline for `measure` computed from `priorSessions` only.
    ///
    /// Sessions starting after `currentStartedAt` are ignored defensively so
    /// a future session can never leak into a comparison pool.
    static func baseline(
        for measure: Measure,
        priorSessions: [FileSessionRepository.SessionRecord],
        currentStartedAt: Date
    ) -> BaselineStatus {
        let validPrior = priorSessions
            .filter { $0.startedAt < currentStartedAt && isValidSession($0) }
            .sorted { $0.startedAt > $1.startedAt }

        let values: [Double] = validPrior.compactMap { record in
            switch measure {
            case .distancePerMinute:
                return distancePerMinute(record)
            case .averageHeartRate:
                return record.completion.summary?.averageHeartRate?.value
            }
        }

        guard values.count >= requiredValidSessions else {
            if validPrior.isEmpty {
                return .unavailable
            }
            return .building(validCount: values.count, required: requiredValidSessions)
        }

        let pool = values.prefix(maximumContributingSessions)
        let mean = pool.reduce(0, +) / Double(pool.count)
        return .established(valuePerMinute: mean, contributingCount: pool.count)
    }

    /// Neutral pre-baseline copy. Deliberately contains no better/worse
    /// language and no percentage comparison.
    static func buildingSentence(validCount: Int, required: Int) -> String {
        "Building your baseline — \(validCount) of \(required) valid sessions"
    }
}
