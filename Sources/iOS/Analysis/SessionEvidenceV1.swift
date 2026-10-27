import Foundation

public struct SessionEvidenceV1: Codable, Equatable, Sendable {
    public let durationSeconds: Double?
    public let distancePerMinute: Double?
    public let averageHeartRate: Double?
    public let heartRateSampleCount: Int
    public let acceptedHeartRateSeconds: Double
    public let hasWholeSessionHeartRate: Bool
    public let hasEffortCoverage: Bool

    static func duration(
        envelope: SessionEnvelopeV1,
        completion: SessionCompletionV1,
        lastRecordedAt: Date?
    ) -> Double? {
        let summary = completion.summary?.duration?.value
        let recorded = lastRecordedAt.map { max(0, $0.timeIntervalSince(envelope.startedAt)) }
        if completion.lifecycle == .completed, let summary, summary.isFinite, summary > 0 {
            return summary
        }
        guard let recorded, recorded.isFinite, recorded > 0 else { return nil }
        if let summary, summary.isFinite, summary > 0 { return min(summary, recorded) }
        return recorded
    }

    static func acceptedHeartRate(
        _ samples: [(timestamp: Date, value: Double)], start: Date, duration: Double
    ) -> [(timestamp: Date, value: Double)] {
        let end = start.addingTimeInterval(duration)
        var seen = Set<Date>()
        return samples.filter {
            $0.timestamp >= start && $0.timestamp <= end && $0.value.isFinite
                && (40...200).contains($0.value) && seen.insert($0.timestamp).inserted
        }.sorted { $0.timestamp < $1.timestamp }
    }

    static func evaluate(
        envelope: SessionEnvelopeV1,
        completion: SessionCompletionV1,
        lastRecordedAt: Date?,
        heartRate: [(timestamp: Date, value: Double)],
        distance: [(timestamp: Date, value: Double)],
        truncated: Bool = false
    ) -> SessionEvidenceV1 {
        let duration = duration(envelope: envelope, completion: completion, lastRecordedAt: lastRecordedAt)
        let seconds = duration ?? 0
        let accepted = acceptedHeartRate(heartRate, start: envelope.startedAt, duration: seconds)
        var covered = 0.0
        var effortCovered = 0.0
        var weightedHeartRate = 0.0
        for index in accepted.indices.dropFirst() {
            let interval = accepted[index].timestamp.timeIntervalSince(accepted[index - 1].timestamp)
            if interval > 0 && interval <= 90 {
                covered += interval
                weightedHeartRate += interval * accepted[index - 1].value
            }
            if interval > 0 && interval <= 20 { effortCovered += interval }
        }
        let complete = completion.lifecycle == .completed && !truncated && seconds >= 600
            && completion.summary?.duration?.provenance != .userEntered
        let wholeHR = complete && accepted.count >= 60 && covered >= seconds * 0.5
        let comparisonHR = wholeHR && covered >= seconds * 0.7
            && accepted.count >= max(60, Int(seconds / 20))
        let distanceRate = coveredDistanceRate(distance, start: envelope.startedAt, duration: seconds)
        return SessionEvidenceV1(
            durationSeconds: duration,
            distancePerMinute: complete ? distanceRate : nil,
            averageHeartRate: comparisonHR && covered > 0 ? weightedHeartRate / covered : nil,
            heartRateSampleCount: accepted.count,
            acceptedHeartRateSeconds: covered,
            hasWholeSessionHeartRate: wholeHR,
            hasEffortCoverage: wholeHR && accepted.count >= max(60, Int(seconds / 15))
                && effortCovered >= seconds * 0.8
        )
    }

    static func distancePoints(
        _ samples: [(timestamp: Date, value: Double)], start: Date, duration: Double
    ) -> [(timestamp: Date, value: Double)]? {
        guard duration >= 600 else { return nil }
        let end = start.addingTimeInterval(duration)
        let points = samples.filter {
            $0.timestamp >= start && $0.timestamp <= end && $0.value.isFinite && $0.value >= 0
        }.sorted { $0.timestamp < $1.timestamp }
        guard points.count >= 4, let first = points.first, let last = points.last,
              first.timestamp.timeIntervalSince(start) <= 60,
              end.timeIntervalSince(last.timestamp) <= 60 else { return nil }
        for index in points.indices.dropFirst() {
            let interval = points[index].timestamp.timeIntervalSince(points[index - 1].timestamp)
            let delta = points[index].value - points[index - 1].value
            guard interval > 0, interval <= 120, delta >= 0, delta / interval <= 12 else { return nil }
        }
        let rate = (last.value - first.value) / duration * 60
        guard rate >= 40 else { return nil }
        return points
    }

    private static func coveredDistanceRate(
        _ samples: [(timestamp: Date, value: Double)], start: Date, duration: Double
    ) -> Double? {
        guard let points = distancePoints(samples, start: start, duration: duration),
              let first = points.first, let last = points.last else { return nil }
        return (last.value - first.value) / duration * 60
    }
}
