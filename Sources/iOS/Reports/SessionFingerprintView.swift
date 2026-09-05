import SwiftUI

/// Compact heart-rate fingerprint: one bar per fingerprint bin. Bar height
/// follows the bin's mean heart rate relative to the session peak. Empty
/// bins render at minimum height with reduced opacity, so missing evidence
/// reads as a gap, never as a low reading.
struct SessionFingerprintView: View {
    let fingerprint: SessionFingerprintV1?
    var tint: Color = PerformanceTheme.heartRate

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let fingerprint {
            canvas(fingerprint)
        } else {
            placeholder
        }
    }

    private func canvas(_ fingerprint: SessionFingerprintV1) -> some View {
        let peak = fingerprint.peakBeatsPerMinute ?? 1
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(fingerprint.bins.indices, id: \.self) { index in
                Capsule()
                    .fill(binColor(fingerprint.bins[index], peak: peak))
                    .frame(height: binHeight(fingerprint.bins[index], peak: peak))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fingerprintLabel(fingerprint))
    }

    private func binHeight(_ bin: Double?, peak: Double) -> CGFloat {
        guard let bin, peak > 0 else { return 4 }
        return 6 + CGFloat(bin / peak) * 18
    }

    private func binColor(_ bin: Double?, peak: Double) -> Color {
        guard let bin, peak > 0 else { return tint.opacity(0.12) }
        return tint.opacity(0.35 + 0.65 * bin / peak)
    }

    private func fingerprintLabel(_ fingerprint: SessionFingerprintV1) -> String {
        let filled = fingerprint.bins.compactMap { $0 }.count
        return "Heart-rate fingerprint, \(filled) of \(fingerprint.bins.count) minute groups have readings"
    }

    /// No fingerprint without heart-rate evidence. The placeholder keeps the
    /// row height stable but never suggests data.
    private var placeholder: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<SessionFingerprintV1.binCount, id: \.self) { _ in
                Capsule()
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
