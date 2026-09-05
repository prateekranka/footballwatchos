import Foundation

/// A compact, deterministic visual fingerprint of one Football Session.
///
/// The fingerprint summarizes heart-rate evidence into a fixed number of
/// minute bins. It is derived only from recorded heart-rate snapshots; a
/// session without usable heart-rate evidence has no fingerprint, never a
/// fabricated one. Binning is gap-aware: bins with no samples stay empty
/// rather than being interpolated.
struct SessionFingerprintV1: Equatable, Sendable, Codable {

    /// Number of bins the fingerprint renders. Matches the compact
    /// mini-visualization used on session rows.
    static let binCount = 24

    /// Mean heart rate per bin, `nil` when the bin has no samples.
    let bins: [Double?]

    /// Fraction of bins that contain at least one sample, 0...1.
    let coverage: Double

    /// Highest mean bin value, used to normalize display heights.
    let peakBeatsPerMinute: Double?

    /// Session time range the bins cover, in whole minutes from session start.
    let durationMinutes: Int

    /// Bumped when binning rules change so cached values recompute.
    static let analysisVersion = 1

    /// Builds a fingerprint from recorded heart-rate snapshots.
    ///
    /// - Parameters:
    ///   - snapshots: heart-rate samples as `(timestamp, bpm)` pairs.
    ///   - startedAt: session start; bins are minutes from this instant.
    ///   - endedAt: session end; the range is divided into `binCount` bins.
    /// Snapshots outside the range are ignored. Unsorted input is sorted.
    static func build(
        from snapshots: [(timestamp: Date, beatsPerMinute: Double)],
        startedAt: Date,
        endedAt: Date
    ) -> SessionFingerprintV1? {
        let span = endedAt.timeIntervalSince(startedAt)
        guard span > 0 else { return nil }
        let usable = snapshots
            .filter { $0.beatsPerMinute > 0 && $0.timestamp >= startedAt && $0.timestamp <= endedAt }
        guard !usable.isEmpty else { return nil }

        let spanMinutes = span / 60
        // Very short outings render as a single partial bin rather than a
        // misleading bar chart.
        guard spanMinutes >= 10 else { return nil }

        var sums = [Double](repeating: 0, count: binCount)
        var counts = [Int](repeating: 0, count: binCount)
        for sample in usable {
            let offset = sample.timestamp.timeIntervalSince(startedAt) / span
            let bin = min(binCount - 1, max(0, Int(offset * Double(binCount))))
            sums[bin] += sample.beatsPerMinute
            counts[bin] += 1
        }

        var bins: [Double?] = []
        bins.reserveCapacity(binCount)
        var filled = 0
        var peak: Double?
        for index in 0..<binCount {
            if counts[index] > 0 {
                let mean = sums[index] / Double(counts[index])
                bins.append(mean)
                peak = max(peak ?? mean, mean)
                filled += 1
            } else {
                bins.append(nil)
            }
        }
        return SessionFingerprintV1(
            bins: bins,
            coverage: Double(filled) / Double(binCount),
            peakBeatsPerMinute: peak,
            durationMinutes: Int(spanMinutes.rounded(.down))
        )
    }
}

/// One factual Observation derived from recorded evidence.
///
/// Observations never infer football actions and never compare the player
/// with anyone else. When evidence is insufficient the engine returns `nil`
/// and the interface shows no observation at all.
struct SessionObservationV1: Equatable, Sendable, Codable {
    /// Minute range the observation refers to, measured from session start.
    let minuteRange: ClosedRange<Int>
    /// Mean heart rate across the range, when heart-rate evidence supports it.
    let meanBeatsPerMinute: Double?
    /// User-facing sentence, already localized in style but not localized yet.
    let sentence: String
}

/// Selects at most one factual observation for a session.
enum SessionObservationEngineV1 {

    /// Minimum fingerprint coverage for a "busiest stretch" statement.
    static let minimumCoverage = 0.5

    /// Width of the comparison window, in fingerprint bins (3 of 24 bins for
    /// a 72-minute session is about 9 minutes).
    static let windowBins = 3

    /// Picks the busiest observed stretch from heart-rate evidence.
    ///
    /// The busiest stretch is the window of `windowBins` consecutive bins
    /// that sits furthest above the session's own linear heart-rate trend.
    /// Measuring against the trend, rather than raw means, stops a steadily
    /// rising session from making every late window look like a burst.
    /// Windows containing empty bins are skipped, so a claim never rests on
    /// interpolated data. Returns `nil` when coverage is too low or no full
    /// window sits above the trend.
    static func busiestStretch(from fingerprint: SessionFingerprintV1) -> SessionObservationV1? {
        guard fingerprint.coverage >= minimumCoverage else { return nil }
        let bins = fingerprint.bins
        guard bins.count >= windowBins else { return nil }

        // Least-squares trend over the filled bins, positions normalized to
        // 0...1 so minute length never changes the fit.
        let filled = bins.enumerated().compactMap { index, value -> (position: Double, value: Double)? in
            guard let value else { return nil }
            let position = (Double(index) + 0.5) / Double(bins.count)
            return (position, value)
        }
        guard filled.count >= windowBins else { return nil }
        let count = Double(filled.count)
        let meanPosition = filled.reduce(0) { $0 + $1.position } / count
        let meanValue = filled.reduce(0) { $0 + $1.value } / count
        let covariance = filled.reduce(0) { $0 + ($1.position - meanPosition) * ($1.value - meanValue) }
        let variance = filled.reduce(0) { $0 + pow($1.position - meanPosition, 2) }
        let slope = variance > 0 ? covariance / variance : 0
        let intercept = meanValue - slope * meanPosition

        var bestRange: Range<Int>?
        var bestResidual: Double = 0
        for start in 0...(bins.count - windowBins) {
            let window = bins[start..<(start + windowBins)]
            guard window.allSatisfy({ $0 != nil }) else { continue }
            let residualSum = window.enumerated().reduce(0) { sum, pair in
                let position = (Double(start + pair.offset) + 0.5) / Double(bins.count)
                return sum + (pair.element! - (intercept + slope * position))
            }
            let meanResidual = residualSum / Double(windowBins)
            if bestRange == nil || meanResidual > bestResidual {
                bestResidual = meanResidual
                bestRange = start..<(start + windowBins)
            }
        }
        // A window must genuinely exceed the trend, not merely be the least
        // below it.
        guard let range = bestRange, bestResidual > 0 else { return nil }

        let binCount = Double(bins.count)
        let totalMinutes = fingerprint.durationMinutes
        let startMinute = Int((Double(range.lowerBound) / binCount * Double(totalMinutes)).rounded(.down))
        let endMinute = max(
            startMinute + 1,
            Int((Double(range.upperBound) / binCount * Double(totalMinutes)).rounded(.up))
        )
        let sentence = "The busiest observed stretch was between \(startMinute) and \(endMinute) minutes."
        return SessionObservationV1(
            minuteRange: startMinute...endMinute,
            meanBeatsPerMinute: fingerprint.peakBeatsPerMinute,
            sentence: sentence
        )
    }

    /// A factual range statement for a series of per-session values, used on
    /// the Progress screen. Returns `nil` for fewer than two sessions.
    static func rangeStatement(
        values: [Double],
        measureName: String,
        unitName: String
    ) -> String? {
        guard values.count >= 2 else { return nil }
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        return String(
            format: "%@ ranged from %.0f to %.0f %@ across %d sessions.",
            measureName,
            low,
            high,
            unitName,
            values.count
        )
    }
}
