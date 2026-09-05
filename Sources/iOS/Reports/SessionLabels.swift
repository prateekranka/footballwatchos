import Foundation

/// Human-readable labels for recorded provenance, lifecycle, and stream
/// states. Every switch is exhaustive over its shared enum, so adding a case
/// forces a label here.
func metricText(_ metric: SessionMetricV1) -> String {
    let value: String
    switch metric.unit {
    case .seconds:
        value = "\(Int(metric.value.rounded())) seconds"
    case .meters:
        value = String(format: "%.1f meters", metric.value)
    case .beatsPerMinute:
        value = String(format: "%.0f bpm", metric.value)
    case .kilocalories:
        value = String(format: "%.0f kcal", metric.value)
    case .metersPerSecond:
        value = String(format: "%.1f m/s", metric.value)
    case .percent:
        value = String(format: "%.0f%%", metric.value * 100)
    case .count:
        value = String(format: "%.0f", metric.value)
    }
    return "\(value) · \(provenanceText(metric.provenance))"
}

func provenanceText(_ provenance: MetricProvenanceV1) -> String {
    switch provenance {
    case .healthKitLive: "HealthKit live"
    case .healthKitFinalWorkout: "HealthKit final workout"
    case .coreMotionBatched: "Batched Core Motion"
    case .coreMotionFallback: "Foreground Core Motion"
    case .capturedDeviceEstimate: "Captured device estimate"
    }
}

func healthSaveText(_ outcome: HealthKitSaveOutcomeV1) -> String {
    switch outcome {
    case .saved: "Saved by Apple Watch"
    case let .failed(message): "Apple Watch save failed: \(message)"
    case let .unavailable(reason): "Unavailable: \(healthUnavailableText(reason))"
    case let .authorizationIssue(reason): "Authorization issue: \(authorizationText(reason))"
    }
}

private func healthUnavailableText(_ reason: HealthKitUnavailabilityReasonV1) -> String {
    switch reason {
    case .healthDataUnavailable: "health data unavailable"
    case .notAttempted: "not attempted"
    case .serviceUnavailable: "service unavailable"
    }
}

private func authorizationText(_ reason: HealthKitAuthorizationIssueV1) -> String {
    switch reason {
    case .notDetermined: "not determined"
    case .denied: "denied"
    case .restricted: "restricted"
    case .requestFailed: "request failed"
    }
}

/// Human-readable label for every `MotionCaptureSourceV1` case.
func captureSourceText(_ source: MotionCaptureSourceV1) -> String {
    switch source {
    case .batchedCoreMotion: "Batched Core Motion"
    case .foregroundFallback: "Foreground Core Motion fallback"
    case let .unavailable(reason): "Unavailable: \(streamUnavailableText(reason))"
    }
}

func availabilityText(_ availability: StreamAvailabilityV1) -> String {
    switch availability {
    case .available: "Available"
    case let .unavailable(reason): "Unavailable: \(streamUnavailableText(reason))"
    case let .insufficient(reason): "Insufficient: \(streamInsufficiencyText(reason))"
    }
}

private func streamUnavailableText(_ reason: StreamUnavailabilityReasonV1) -> String {
    switch reason {
    case .hardwareUnsupported: "hardware unsupported"
    case .permissionDenied: "permission denied"
    case .authorizationUnavailable: "authorization unavailable"
    case .serviceUnavailable: "service unavailable"
    case .disabledByUser: "disabled by user"
    case .captureNotStarted: "capture not started"
    case .sourceError: "source error"
    }
}

private func streamInsufficiencyText(_ reason: StreamInsufficiencyReasonV1) -> String {
    switch reason {
    case .noSamples: "no samples"
    case .insufficientSamples: "insufficient samples"
    case .insufficientCoverage: "insufficient coverage"
    case .excessiveGaps: "excessive gaps"
    case .captureEndedEarly: "capture ended early"
    }
}
