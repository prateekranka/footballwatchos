import Foundation

/// Companion-side computation of football analytics from a decoded package.
///
/// The Watch captures raw frames; this analyst derives the football-specific
/// metrics and produces the `SessionAnalyticsV1` document that gets pushed to
/// the health pipeline (`POST /analytics`) and surfaced in reports.
///
/// Draft status: pure-math derivations (fatigue curve, sprint quality,
/// work:rest, zones) are implemented; load bands and acceleration counts
/// depend on motion/GPS streams and are marked TODO until the detection
/// pipeline feeds them validated data.
public enum SessionAnalystV1 {

    // MARK: - Zones

    /// HR zones 1...5 from an estimated max (220 − age or watch estimate).
    public static func zones(
        heartRate: [(timestamp: Date, bpm: Double)],
        estimatedHRMaxBPM: Double,
        highThresholdBPM: Double = 160
    ) -> SessionZoneSummaryV1 {
        let boundaries = (1...5).map { Double($0) / 5.0 * estimatedHRMaxBPM } // 20% steps, draft
        var secondsPerZone = [Double](repeating: 0, count: 5)
        var aboveHigh: Double = 0
        for i in heartRate.indices.dropFirst() {
            let dt = heartRate[i].timestamp.timeIntervalSince(heartRate[i - 1].timestamp)
            guard dt > 0, dt < 120 else { continue }
            let bpm = heartRate[i].bpm
            let zone = min(4, max(0, Int(bpm / (estimatedHRMaxBPM / 5))))
            secondsPerZone[zone] += dt
            if bpm > highThresholdBPM { aboveHigh += dt }
        }
        let zones = zip(1...5, secondsPerZone).map { z, s in
            HRZoneV1(
                zone: z,
                lowerBPM: z == 1 ? 0 : boundaries[z - 2],
                upperBPM: z == 5 ? .infinity : boundaries[z - 1],
                seconds: s
            )
        }
        let trimp = secondsPerZone.enumerated().reduce(0) { $0 + $1.element * Double($1.offset + 1) }
        return SessionZoneSummaryV1(
            zones: zones,
            trimp: metric(trimp, .count, .capturedDeviceEstimate),
            timeAboveHighThresholdS: aboveHigh,
            estimatedHRMaxBPM: estimatedHRMaxBPM
        )
    }

    // MARK: - Fatigue curve

    /// Buckets the match into `bucketMinutes` slices; per bucket, measures the
    /// 160 -> 140 recovery of the last high-effort ending inside it.
    public static func fatigueCurve(
        heartRate: [(timestamp: Date, bpm: Double)],
        sprints: [SprintEventV1],
        sessionStart: Date,
        sessionEnd: Date,
        bucketMinutes: Int = 5,
        high: Double = 160,
        low: Double = 140,
        sustainS: Double = 30
    ) -> FatigueCurveV1 {
        let totalMinutes = max(1, Int(sessionEnd.timeIntervalSince(sessionStart) / 60))
        let bucketCount = Int(ceil(Double(totalMinutes) / Double(bucketMinutes)))
        var points: [FatiguePointV1] = (0..<bucketCount).map { i in
            FatiguePointV1(
                bucketStartMinute: i * bucketMinutes,
                recoverySeconds: nil,
                peakBPM: nil,
                sprintCount: 0
            )
        }

        let sorted = heartRate.sorted { $0.timestamp < $1.timestamp }
        for sprint in sprints {
            let minute = Int(sprint.startTimestamp.timeIntervalSince(sessionStart) / 60)
            let bucket = min(bucketCount - 1, minute / bucketMinutes)
            if bucket >= 0 {
                points[bucket].sprintCount += 1
            }
        }

        // For each bucket: find the last HR crossing above `high` inside it,
        // then measure to the first sustained <= low afterwards.
        for (bucketIndex, _) in points.enumerated() {
            let bucketStart = sessionStart.addingTimeInterval(TimeInterval(bucketIndex * bucketMinutes * 60))
            let bucketEnd = sessionStart.addingTimeInterval(TimeInterval((bucketIndex + 1) * bucketMinutes * 60))
            let inBucket = sorted.filter { $0.timestamp >= bucketStart && $0.timestamp < bucketEnd && $0.bpm > high }
            guard let lastAbove = inBucket.last else { continue }
            points[bucketIndex].peakBPM = inBucket.map { $0.bpm }.max()

            var sustainedAt: Date?
            var idx = sorted.firstIndex { $0.timestamp >= lastAbove.timestamp } ?? sorted.endIndex
            while idx < sorted.count {
                let start = sorted[idx]
                guard start.bpm <= low else { idx += 1; continue }
                var j = idx
                while j < sorted.count && sorted[j].bpm <= low {
                    if sorted[j].timestamp.timeIntervalSince(start.timestamp) >= sustainS {
                        sustainedAt = start.timestamp
                        break
                    }
                    j += 1
                }
                if sustainedAt != nil { break }
                idx = j + 1
            }
            if let sustainedAt {
                points[bucketIndex].recoverySeconds = sustainedAt.timeIntervalSince(lastAbove.timestamp)
            }
        }

        let halves = splitAtHalf(points, totalMinutes: totalMinutes)
        let firstAvg = average(halves.0.compactMap(\.recoverySeconds))
        let secondAvg = average(halves.1.compactMap(\.recoverySeconds))
        let drift: Double? = (firstAvg != nil && secondAvg != nil) ? secondAvg! - firstAvg! : nil

        return FatigueCurveV1(
            points: points,
            firstHalfAverageRecoveryS: firstAvg,
            secondHalfAverageRecoveryS: secondAvg,
            driftSeconds: drift
        )
    }

    // MARK: - Sprint quality

    public static func sprintQuality(
        _ sprints: [SprintEventV1],
        sessionStart: Date,
        sessionDurationMinutes: Double
    ) -> SprintQualityV1 {
        let first15 = sprints.filter { $0.startTimestamp.timeIntervalSince(sessionStart) / 60 < 15 }
        let last15 = sprints.filter { $0.startTimestamp.timeIntervalSince(sessionStart) / 60 >= max(0, sessionDurationMinutes - 15) }
        let firstAvgSpeed = average(first15.compactMap(\.maxSpeedMPS?.value))
        let lastAvgSpeed = average(last15.compactMap(\.maxSpeedMPS?.value))
        let decrement: Double? = if let f = firstAvgSpeed, let l = lastAvgSpeed, f > 0 {
            (f - l) / f
        } else { nil }

        return SprintQualityV1(
            sprintCount: sprints.count,
            averageDurationS: averageMetric(sprints.compactMap(\.durationS)),
            averageMaxSpeedMPS: averageMetric(sprints.compactMap(\.maxSpeedMPS)),
            averagePeakHR: averageMetric(sprints.compactMap(\.peakHeartRate)),
            averageOnsetHR: averageMetric(sprints.compactMap(\.heartRateAtOnset)),
            frequencyPerMinute: sessionDurationMinutes > 0
                ? metric(Double(sprints.count) / sessionDurationMinutes, .count, .capturedDeviceEstimate) : nil,
            lateGameSpeedDecrementFraction: decrement.map { metric($0, .percent, .capturedDeviceEstimate) }
        )
    }

    // MARK: - Work : rest

    /// High-intensity efforts = HR runs above `high`; rest = time between
    /// efforts. Also folds in sprint boundaries when HR data is sparse.
    public static func workRest(
        heartRate: [(timestamp: Date, bpm: Double)],
        high: Double = 160,
        minimumEffortS: Double = 10
    ) -> WorkRestSummaryV1 {
        let sorted = heartRate.sorted { $0.timestamp < $1.timestamp }
        var efforts: [ClosedRange<Date>] = []
        var inEffort = false
        var effortStart = Date()
        for i in sorted.indices {
            let sample = sorted[i]
            if sample.bpm > high {
                if !inEffort {
                    inEffort = true
                    effortStart = sample.timestamp
                }
            } else if inEffort {
                // End the effort at the midpoint between this and the last high sample.
                let lastHigh = sorted[max(0, i - 1)].timestamp
                inEffort = false
                if lastHigh.timeIntervalSince(effortStart) >= minimumEffortS {
                    efforts.append(effortStart...lastHigh)
                }
            }
        }
        if inEffort, let last = sorted.last {
            efforts.append(effortStart...last.timestamp)
        }

        let work = efforts.reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) }
        var rests: [Double] = []
        for i in efforts.indices.dropFirst() {
            rests.append(efforts[i].lowerBound.timeIntervalSince(efforts[i - 1].upperBound))
        }
        let rest = rests.reduce(0, +)
        let ratio: Double? = work > 0 ? rest / work : nil

        return WorkRestSummaryV1(
            highIntensityEffortCount: efforts.count,
            workSeconds: work,
            restSeconds: rest,
            ratio: ratio,
            longestHighIntensityRunS: efforts.map { $0.upperBound.timeIntervalSince($0.lowerBound) }.max(),
            medianRecoveryBetweenEffortsS: rests.sorted().isEmpty ? nil : rests.sorted()[rests.count / 2]
        )
    }

    // MARK: - Load (draft: distance bands from snapshots; accel counts TODO)

    public static func load(
        distanceSnapshots: [(timestamp: Date, meters: Double)],
        sprintThreshold: SprintThresholdV1 = .draft
    ) -> LoadSummaryV1 {
        let hsr = sprintThreshold.highSpeedRunningMinMPS
        let sprint = sprintThreshold.minSpeedMPS
        let bands: [(String, Double, Double)] = [
            ("walk", 0, 1.4), ("jog", 1.4, 3.0), ("run", 3.0, hsr),
            ("high-speed", hsr, sprint), ("sprint", sprint, .infinity),
        ]
        var metersPerBand = [Double](repeating: 0, count: bands.count)
        var total: Double = 0
        for i in distanceSnapshots.indices.dropFirst() {
            let dt = distanceSnapshots[i].timestamp.timeIntervalSince(distanceSnapshots[i - 1].timestamp)
            guard dt > 0.2, dt < 120 else { continue }
            let delta = max(0, distanceSnapshots[i].meters - distanceSnapshots[i - 1].meters)
            let mps = delta / dt
            total += delta
            for (bandIndex, band) in bands.enumerated() where mps >= band.1 && mps < band.2 {
                metersPerBand[bandIndex] += delta
                break
            }
        }
        let banded = zip(bands, metersPerBand).map { b, m in
            SpeedBandDistanceV1(label: b.0, lowMPS: b.1, highMPS: b.2, meters: m)
        }
        let hsrMeters = metersPerBand[3]
        let sprintMeters = metersPerBand[4]
        return LoadSummaryV1(
            totalDistanceM: metric(total, .meters, .capturedDeviceEstimate),
            distanceByBand: banded,
            highSpeedRunningM: metric(hsrMeters, .meters, .capturedDeviceEstimate),
            sprintingM: metric(sprintMeters, .meters, .capturedDeviceEstimate),
            highIntensityAccelerations: nil, // TODO: from accelerometer batches
            highIntensityDecelerations: nil  // TODO: from accelerometer batches
        )
    }

    // MARK: - Calibration

    /// Derive a personal sprint threshold from measured maximal efforts.
    ///
    /// Distance-derived speed streams smooth instantaneous peaks, so the best
    /// observed effort is scaled up by `correctionFactor` (draft 1.10) before
    /// taking 80% as the detection threshold. With at least 2 qualifying
    /// efforts the result is `provisional`; below that it stays `uncalibrated`.
    public static func recommendCalibration(
        sprints: [SprintEventV1],
        correctionFactor: Double = 1.10,
        thresholdFraction: Double = 0.80
    ) -> SprintCalibrationV1? {
        let peaks = sprints.compactMap(\.maxSpeedMPS?.value)
        guard let best = peaks.max() else { return nil }
        let estimatedMSS = best * correctionFactor
        return SprintCalibrationV1(
            estimatedMSSMPS: estimatedMSS,
            recommendedThresholdMPS: estimatedMSS * thresholdFraction,
            correctionFactor: correctionFactor,
            sampleCount: peaks.count,
            confidence: peaks.count >= 2 ? .provisional : .uncalibrated
        )
    }

    // MARK: - Document assembly

    public static func analyticsDocument(
        sessionID: UUID,
        startedAt: Date,
        endedAt: Date,
        heartRate: [(timestamp: Date, bpm: Double)],
        distanceSnapshots: [(timestamp: Date, meters: Double)],
        sprints: [SprintEventV1],
        estimatedHRMaxBPM: Double,
        readiness: ReadinessSnapshotV1?,
        subjective: SubjectiveSessionInputV1?,
        pipelineRecoverySeconds: Double?
    ) -> SessionAnalyticsV1 {
        let durationMinutes = endedAt.timeIntervalSince(startedAt) / 60
        return SessionAnalyticsV1(
            sessionID: sessionID,
            startedAt: startedAt,
            sprints: sprints,
            zones: zones(heartRate: heartRate, estimatedHRMaxBPM: estimatedHRMaxBPM),
            fatigueCurve: fatigueCurve(heartRate: heartRate, sprints: sprints, sessionStart: startedAt, sessionEnd: endedAt),
            sprintQuality: sprintQuality(sprints, sessionStart: startedAt, sessionDurationMinutes: durationMinutes),
            workRest: workRest(heartRate: heartRate),
            load: load(distanceSnapshots: distanceSnapshots),
            readiness: readiness,
            subjective: subjective,
            pipelineRecoverySeconds: pipelineRecoverySeconds,
            computedAt: Date()
        )
    }

    // MARK: - Helpers

    private static func metric(_ value: Double, _ unit: MetricUnitV1, _ provenance: MetricProvenanceV1) -> SessionMetricV1 {
        SessionMetricV1(value: value, unit: unit, provenance: provenance)
    }

    private static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    private static func averageMetric(_ metrics: [SessionMetricV1]) -> SessionMetricV1? {
        guard !metrics.isEmpty, let unit = metrics.first?.unit else { return nil }
        return metric(metrics.map(\.value).reduce(0, +) / Double(metrics.count), unit, .capturedDeviceEstimate)
    }

    private static func splitAtHalf(_ points: [FatiguePointV1], totalMinutes: Int) -> ([FatiguePointV1], [FatiguePointV1]) {
        let halfMinute = totalMinutes / 2
        return (
            points.filter { $0.bucketStartMinute < halfMinute },
            points.filter { $0.bucketStartMinute >= halfMinute }
        )
    }
}
