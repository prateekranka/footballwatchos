import Foundation
import Testing
@testable import FootballPerformance

@Suite("PhoneSessionLibraryModel")
struct PhoneSessionLibraryModelTests {
    // MARK: - Metric picker

    @Test("the metric picker offers heart rate, distance, acceleration magnitude, and rotation rate")
    func metricPickerCases() {
        #expect(RecordedMetric.allCases.map(\.rawValue) == ["Heart rate", "Distance", "Acceleration", "Rotation"])
    }

    // MARK: - Acceleration magnitude

    @Test("acceleration magnitude maps samples to sqrt(x^2+y^2+z^2) rebased to the first sample")
    func accelerationMagnitudeMapping() {
        let samples = [
            FileSessionRepository.MotionSamplePoint(timestamp: 1_000, x: 3, y: 4, z: 0),
            FileSessionRepository.MotionSamplePoint(timestamp: 1_001, x: 0, y: 0, z: 2),
            FileSessionRepository.MotionSamplePoint(timestamp: 1_002, x: 1, y: 1, z: 1)
        ]
        let points = MotionChartBuilder.accelerationMagnitudePoints(from: samples, idPrefix: "accel")
        #expect(points.count == 3)
        #expect(points[0].timestamp == 0) // first sample rebased to zero
        #expect(points[0].value == 5) // sqrt(9 + 16 + 0)
        #expect(points[1].timestamp == 1)
        #expect(points[1].value == 2) // sqrt(0 + 0 + 4)
        #expect(points[2].timestamp == 2)
        #expect(points[2].value == 3.0.squareRoot()) // sqrt(1 + 1 + 1)
        #expect(points.map(\.id) == ["accel-0", "accel-1", "accel-2"])
    }

    @Test("empty accelerometer samples map to an empty chart")
    func emptyAccelerationMapping() {
        #expect(MotionChartBuilder.accelerationMagnitudePoints(from: [], idPrefix: "accel").isEmpty)
    }

    // MARK: - Rotation rate

    @Test("rotation rate maps device-motion rotation vectors to magnitudes rebased to the first sample")
    func rotationRateMapping() {
        let samples = [
            FileSessionRepository.DeviceMotionSamplePoint(
                timestamp: 2_000,
                userAcceleration: .init(x: 0, y: 0, z: 0),
                gravity: .init(x: 0, y: 0, z: 9.81),
                rotationRate: .init(x: 0.5, y: 0.6, z: 0.7)
            ),
            FileSessionRepository.DeviceMotionSamplePoint(
                timestamp: 2_010,
                userAcceleration: .init(x: 0, y: 0, z: 0),
                gravity: .init(x: 0, y: 0, z: 9.81),
                rotationRate: .init(x: 1, y: 0, z: 0)
            )
        ]
        let points = MotionChartBuilder.rotationRatePoints(from: samples, idPrefix: "rotation")
        #expect(points.count == 2)
        #expect(points[0].timestamp == 0)
        #expect(abs(points[0].value - 1.1.squareRoot()) < 1e-12) // sqrt(0.25 + 0.36 + 0.49), within float tolerance
        #expect(points[1].timestamp == 10)
        #expect(points[1].value == 1)
        #expect(points.map(\.id) == ["rotation-0", "rotation-1"])
    }

    @Test("empty device-motion samples map to an empty chart")
    func emptyRotationMapping() {
        #expect(MotionChartBuilder.rotationRatePoints(from: [], idPrefix: "rotation").isEmpty)
    }

    // MARK: - Decimation

    @Test("dense motion series are decimated stride-based to at most 2000 points, preserving the first sample")
    func denseSeriesDecimation() {
        let samples = (0..<5_000).map { index in
            FileSessionRepository.MotionSamplePoint(timestamp: Double(index) * 0.02, x: 1, y: 0, z: 0)
        }
        let points = MotionChartBuilder.accelerationMagnitudePoints(from: samples, idPrefix: "accel")
        #expect(points.count <= MotionChartBuilder.maximumChartPoints)
        #expect(points.count == 1_667) // stride 3 over 5_000 samples
        #expect(points.first?.timestamp == 0) // first sample always kept
        #expect(points.last?.timestamp == 4_998 * 0.02)
        #expect(points[1].timestamp == 3 * 0.02)
    }

    @Test("sparse motion series pass through without decimation")
    func sparseSeriesUnchanged() {
        let samples = (0..<50).map { index in
            FileSessionRepository.DeviceMotionSamplePoint(
                timestamp: Double(index) * 0.02,
                userAcceleration: .init(x: 0, y: 0, z: 0),
                gravity: .init(x: 0, y: 0, z: 9.81),
                rotationRate: .init(x: 0, y: 1, z: 0)
            )
        }
        let points = MotionChartBuilder.rotationRatePoints(from: samples, idPrefix: "rotation")
        #expect(points.count == 50)
    }

    // MARK: - Capture source text

    @Test("every capture source renders a human-readable label")
    func captureSourceTextIsHumanReadable() {
        #expect(captureSourceText(.batchedCoreMotion) == "Batched Core Motion")
        #expect(captureSourceText(.foregroundFallback) == "Foreground Core Motion fallback")
        #expect(captureSourceText(.unavailable(reason: .serviceUnavailable)) == "Unavailable: service unavailable")
        #expect(captureSourceText(.unavailable(reason: .permissionDenied)) == "Unavailable: permission denied")
    }
}
