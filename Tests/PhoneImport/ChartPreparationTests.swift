import Foundation
import Testing
@testable import FootballPerformance

@Suite("ChartPreparation")
struct ChartPreparationTests {

    private static let t0 = Date(timeIntervalSinceReferenceDate: 745_000_000)

    private static func sample(at seconds: Double, _ value: Double) -> (timestamp: Date, value: Double) {
        (Self.t0.addingTimeInterval(seconds), value)
    }

    // MARK: - Basic series

    @Test("three points one minute apart form one segment starting at zero")
    func singleSegment() {
        let snapshots = [
            Self.sample(at: 0, 120),
            Self.sample(at: 60, 130),
            Self.sample(at: 120, 140)
        ]
        let segments = ChartPreparationV1.segments(from: snapshots)
        #expect(segments.count == 1)
        #expect(segments[0].points.first?.seconds == 0)
        #expect(abs((segments[0].points.last?.seconds ?? -1) - 120) < 0.001)
        #expect(segments[0].points.count == 3)
    }

    // MARK: - Gap awareness

    @Test("a five-minute hole splits the series into two segments")
    func gapSplitsSegments() {
        let snapshots = [
            Self.sample(at: 0, 120),
            Self.sample(at: 60, 130),
            Self.sample(at: 120, 140),
            Self.sample(at: 420, 150),
            Self.sample(at: 480, 160)
        ]
        let segments = ChartPreparationV1.segments(from: snapshots)
        #expect(segments.count == 2)
        #expect(abs((segments[0].points.last?.seconds ?? -1) - 120) < 0.001)
        // The second segment starts at its own first sample, never connected
        // across the gap.
        #expect((segments[1].points.first?.seconds ?? 0) >= 300)
    }

    @Test("unsorted input is sorted internally and renders the same series")
    func unsortedInputIsSorted() {
        let sorted = [
            Self.sample(at: 0, 120),
            Self.sample(at: 60, 130),
            Self.sample(at: 120, 140)
        ]
        let shuffled = [sorted[2], sorted[0], sorted[1]]
        let fromSorted = ChartPreparationV1.segments(from: sorted)
        let fromShuffled = ChartPreparationV1.segments(from: shuffled)
        #expect(fromShuffled.count == fromSorted.count)
        #expect(fromShuffled == fromSorted)
    }

    // MARK: - Decimation

    @Test("a dense one-hour series decimates to at most the rendering cap plus edges")
    func denseSeriesDecimates() {
        let snapshots = (0..<3_000).map { index in
            Self.sample(at: Double(index), Double(index % 40))
        }
        let segments = ChartPreparationV1.segments(from: snapshots)
        #expect(segments.count == 1)
        let totalPoints = segments.reduce(0) { $0 + $1.points.count }
        #expect(totalPoints <= ChartPreparationV1.maximumPoints + 2)
    }

    // MARK: - Largest gap helper

    @Test("largest gap is nil for fewer than two dates and reports the widest spacing otherwise")
    func largestGapHelper() {
        #expect(largestGap(in: []) == nil)
        #expect(largestGap(in: [Self.t0]) == nil)

        let dates = [
            Self.t0,
            Self.t0.addingTimeInterval(60),
            Self.t0.addingTimeInterval(400),
            Self.t0.addingTimeInterval(460)
        ]
        let gap = largestGap(in: dates) ?? -1
        #expect(abs(gap - 340) < 0.001)
    }
}
