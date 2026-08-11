import Foundation
import XCTest
@testable import FootballPerformanceWatch

final class WatchDiagnosticJournalTests: XCTestCase {
    func testArmedAttemptBecomesPendingReportOnNextLaunchAndAcknowledgesDurably() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchDiagnosticTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSinceReferenceDate: 300_000)

        let firstLaunch = try WatchDiagnosticJournal(
            directory: directory,
            now: start,
            appVersion: "1.0.1",
            buildNumber: "6",
            operatingSystemVersion: "watchOS 26.5"
        )
        try await firstLaunch.checkpoint(
            "start_attempt_created",
            armed: true,
            at: start.addingTimeInterval(1)
        )
        try await firstLaunch.checkpoint(
            "health_start_requested",
            at: start.addingTimeInterval(2)
        )

        let secondLaunch = try WatchDiagnosticJournal(
            directory: directory,
            now: start.addingTimeInterval(10),
            appVersion: "1.0.1",
            buildNumber: "6",
            operatingSystemVersion: "watchOS 26.5"
        )
        let reports = await secondLaunch.pendingReports()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].checkpoints.last?.code, "health_start_requested")

        try await secondLaunch.acknowledge(
            WatchDiagnosticReceiptV1(
                reportID: reports[0].reportID,
                acknowledgedAt: start.addingTimeInterval(11)
            )
        )

        let thirdLaunch = try WatchDiagnosticJournal(
            directory: directory,
            now: start.addingTimeInterval(20),
            appVersion: "1.0.1",
            buildNumber: "6",
            operatingSystemVersion: "watchOS 26.5"
        )
        let remainingReports = await thirdLaunch.pendingReports()
        XCTAssertTrue(remainingReports.isEmpty)
    }

    func testUnarmedLaunchDoesNotCreateAnInterruptionReport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchDiagnosticUnarmedTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = Date(timeIntervalSinceReferenceDate: 400_000)

        _ = try WatchDiagnosticJournal(
            directory: directory,
            now: start,
            appVersion: "1.0.1",
            buildNumber: "6",
            operatingSystemVersion: "watchOS 26.5"
        )
        let nextLaunch = try WatchDiagnosticJournal(
            directory: directory,
            now: start.addingTimeInterval(10),
            appVersion: "1.0.1",
            buildNumber: "6",
            operatingSystemVersion: "watchOS 26.5"
        )

        let reports = await nextLaunch.pendingReports()
        XCTAssertTrue(reports.isEmpty)
    }
}
