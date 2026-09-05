import Foundation
import SwiftUI
import Testing
@testable import FootballPerformance

@Suite("SessionPresentation")
struct SessionPresentationTests {

    // MARK: - Record helper

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: components)!
    }

    private static func summary(
        duration: Double? = nil,
        distance: Double? = nil,
        averageHeartRate: Double? = nil
    ) -> SessionSummaryMetricsV1 {
        SessionSummaryMetricsV1(
            duration: duration.map {
                SessionMetricV1(value: $0, unit: .seconds, provenance: .healthKitFinalWorkout)
            },
            distance: distance.map {
                SessionMetricV1(value: $0, unit: .meters, provenance: .healthKitFinalWorkout)
            },
            averageHeartRate: averageHeartRate.map {
                SessionMetricV1(value: $0, unit: .beatsPerMinute, provenance: .healthKitFinalWorkout)
            },
            activeEnergy: nil
        )
    }

    private static func makeRecord(
        startedAt: Date,
        summary: SessionSummaryMetricsV1?,
        lifecycle: SessionLifecycleV1
    ) -> FileSessionRepository.SessionRecord {
        let endedAt = startedAt.addingTimeInterval(summary?.duration?.value ?? 600)
        let sessionID = UUID()
        let transferEnvelope = SessionTransferEnvelopeV1(
            sessionID: sessionID,
            packageDigest: SessionDigestV1(bytes: Data([0x01, 0x02, 0x03, 0x04])),
            byteCount: 48_000,
            createdAt: endedAt
        )
        let sessionEnvelope = SessionEnvelopeV1(
            sessionID: sessionID,
            createdAt: endedAt,
            startedAt: startedAt,
            captureSource: .batchedCoreMotion,
            initialAccelerometerAvailability: .available,
            initialDeviceMotionAvailability: .available
        )
        let completion = SessionCompletionV1(
            endedAt: endedAt,
            lifecycle: lifecycle,
            summary: summary,
            healthKitSaveOutcome: .saved(workoutUUID: nil)
        )
        return FileSessionRepository.SessionRecord(
            transferEnvelope: transferEnvelope,
            sessionEnvelope: sessionEnvelope,
            completion: completion
        )
    }

    // MARK: - Row formatting

    @Test("row labels render recorded values and an explicit dash for missing ones")
    func rowLabels() {
        let date = Self.date(2025, 4, 8, 19, 5)
        #expect(!SessionRowFormatting.dayLabel(date).isEmpty)
        #expect(!SessionRowFormatting.timeLabel(date).isEmpty)

        #expect(SessionRowFormatting.durationLabel(nil) == "—")
        #expect(SessionRowFormatting.durationLabel(0) == "—")
        #expect(SessionRowFormatting.durationLabel(4320) == "72 min")

        #expect(SessionRowFormatting.distanceLabel(meters: nil) == "—")
        #expect(SessionRowFormatting.distanceLabel(meters: 0) == "—")
        #expect(SessionRowFormatting.distanceLabel(meters: 8400) == "8.4 km")

        #expect(SessionRowFormatting.heartRateLabel(nil) == "—")
        #expect(SessionRowFormatting.heartRateLabel(142.4) == "142 bpm")
    }

    // MARK: - Lifecycle state

    @Test("recorded lifecycle maps to a plain session state without spin")
    func stateMapping() {
        let completed = Self.makeRecord(
            startedAt: Self.date(2025, 4, 8, 19, 5),
            summary: Self.summary(duration: 4320, distance: 8400, averageHeartRate: 142),
            lifecycle: .completed
        )
        #expect(SessionRowFormatting.state(completed) == .completed)

        let interrupted = Self.makeRecord(
            startedAt: Self.date(2025, 4, 9, 19, 5),
            summary: Self.summary(duration: 2280, distance: 3900),
            lifecycle: .interrupted(reason: .appTerminated)
        )
        #expect(SessionRowFormatting.state(interrupted) == .interrupted(reason: .appTerminated))
    }

    @Test("every interruption reason gets a plain-language detail sentence")
    func interruptionDetails() {
        // The reason enum is not CaseIterable, so the cases are listed here.
        let reasons: [SessionInterruptionReasonV1] = [
            .appTerminated,
            .workoutEndedUnexpectedly,
            .storageFailure,
            .partialFileRecovery,
            .userAbandoned,
            .unknown
        ]
        for reason in reasons {
            let detail = SessionRowFormatting.interruptionDetail(reason)
            #expect(!detail.isEmpty)
            #expect(detail.hasSuffix("."))
        }
    }

    // MARK: - Sync presentation

    @MainActor
    @Test("each sync kind maps to a title, symbol, and tint")
    func syncPresentationMappings() {
        let entries: [(kind: SyncPresentation.Kind, title: String, symbol: String, tint: Color)] = [
            (
                .receiving,
                "Receiving from Apple Watch…",
                "applewatch.radiowaves.left.and.right",
                PerformanceTheme.accent
            ),
            (.uploading, "Backing up…", "icloud.and.arrow.up", PerformanceTheme.accent),
            (.needsAttention, "Backup needs attention", "exclamationmark.triangle.fill", PerformanceTheme.warning),
            (.pendingUploads(count: 1), "1 session waiting to back up", "icloud.and.arrow.up", .secondary),
            (.pendingUploads(count: 2), "2 sessions waiting to back up", "icloud.and.arrow.up", .secondary),
            (.upToDate, "Up to date", "checkmark.icloud", PerformanceTheme.accent),
            (.waitingForFirst, "Waiting for your first session", "tray", .secondary),
            (.storageUnavailable, "Storage unavailable", "exclamationmark.triangle.fill", PerformanceTheme.warning)
        ]
        for entry in entries {
            let presentation = SyncPresentation(kind: entry.kind, detail: nil)
            #expect(presentation.title == entry.title)
            #expect(presentation.symbolName == entry.symbol)
            #expect(presentation.tint == entry.tint)
        }
    }

    @MainActor
    @Test("the presentation keeps the given detail text")
    func detailRoundTrip() {
        let presentation = SyncPresentation(kind: .needsAttention, detail: "Upload failed")
        #expect(presentation.detail == "Upload failed")
    }

    @MainActor
    @Test("an empty library presents waiting-for-first or storage-unavailable")
    func emptyLibraryPresentation() {
        let model = PhoneSessionLibraryModel()
        let presentation = SyncPresentation(model: model)
        #expect(presentation.kind == .waitingForFirst || presentation.kind == .storageUnavailable)
    }
}
