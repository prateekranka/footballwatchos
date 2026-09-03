import Foundation

/// Persists the personal sprint threshold on the Watch (UserDefaults).
///
/// The detector uses the stored calibrated threshold when present and falls
/// back to `SprintThresholdV1.draft` otherwise. The value is set from the
/// companion after a Calibration Session (recommendation from
/// `SessionAnalystV1.recommendCalibration`).
public enum SprintCalibrationStore {
    private static let key = "sprint.threshold.v1"

    public static func load() -> SprintThresholdV1? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(SprintThresholdV1.self, from: data)
    }

    @discardableResult
    public static func save(_ threshold: SprintThresholdV1) -> Bool {
        guard let data = try? JSONEncoder().encode(threshold) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }

    public static func current() -> SprintThresholdV1 {
        load() ?? .draft
    }
}
