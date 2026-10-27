/// Ways coaching can fail, covered by the degraded-history journey:
/// 1. Next-day recovery becomes 1,440 minutes instead of five recorded minutes.
/// 2. A fragment inflates outing counts or produces sensor coaching.
/// 3. Normal weekly 77-minute play produces a load spike; short history gives a ratio.
/// 4. Sparse or late HR produces zone percentages, effort zeros, or fitness advice.
/// 5. Distance undercount or a ten-minute gap produces fade advice.
/// 6. Artifact peaks change max HR; good coverage loses valid session insights.
/// 7. Missing sensor metrics appear as zero instead of a dash.
/// Named screenshots are retained in the xcresult bundle for each evidence state.
import XCTest

@MainActor
final class DegradedCoachingE2ETests: XCTestCase {
    func testDegradedHistoryKeepsCoachingBoundToRecordedEvidence() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-FP_UI_QA", "YES", "-onboardingCompleted", "YES",
            "-FP_QA_SCENARIO", "degraded", "-FP_QA_TAB", "sessions",
        ]
        app.launch()
        XCTAssertTrue(text("THIS WEEK", in: app).waitForExistence(timeout: 30))
        XCTAssertFalse(text("Your load jumped", in: app).exists)
        XCTAssertTrue(reveal(app.buttons["Full plan"], in: app))
        app.buttons["Full plan"].tap()
        XCTAssertTrue(text("Steady build", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["coach-acute"].label.contains("77 min"))
        XCTAssertTrue(app.descendants(matching: .any)["coach-chronic"].label.contains("77 min"))
        XCTAssertEqual(app.descendants(matching: .any)["Load ratio"].value as? String, "1.0 times your usual week")
        XCTAssertFalse(text("Load spike", in: app).exists)
        XCTAssertTrue(reveal(text("Work-rate comparison unavailable", in: app), in: app))
        XCTAssertTrue(reveal(text("HR comparison unavailable", in: app), in: app))
        capture(app, "degraded-01-weekly-77-minutes-no-spike")
        back(app)

        openSession("7-a-side · Watch recording", in: app)
        XCTAssertTrue(text("77 min", in: app).waitForExistence(timeout: 10))
        assertLimitedEvidence(in: app)
        capture(app, "degraded-02-sparse-hr-distance-gap")
        back(app)
        XCTAssertTrue(reveal(app.buttons["See all"], in: app))
        app.buttons["See all"].tap()

        openSession("Calibration · Watch recording", in: app)
        XCTAssertTrue(text("5 min", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(text("Interrupted recording", in: app).exists)
        XCTAssertFalse(text("1,440", in: app).exists)
        XCTAssertFalse(text("1440", in: app).exists)
        XCTAssertTrue(reveal(text("This fragment does not count as an outing", in: app), in: app))
        XCTAssertTrue(reveal(app.descendants(matching: .any)["coach-hard-efforts"], in: app))
        XCTAssertTrue(app.descendants(matching: .any)["coach-hard-efforts"].label.contains("—"))
        XCTAssertFalse(text("Intensity", in: app).exists)
        XCTAssertFalse(text("How to get better", in: app).exists)
        capture(app, "degraded-03-five-minute-next-day-recovery")
        back(app)

        openSession("5-a-side · Watch recording", in: app)
        assertLimitedEvidence(in: app)
        capture(app, "degraded-04-late-heart-rate")
        back(app)

        openSession("Training · Manual log", in: app)
        XCTAssertTrue(text("No sensor readings were recorded", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(text("77 min", in: app).exists)
        XCTAssertTrue(text("—, Distance", in: app).exists || text("—", in: app).exists)
        XCTAssertFalse(text("Intensity", in: app).exists)
        capture(app, "degraded-05-manual-log-missing-metrics")
        back(app)

        openSession("11-a-side · Watch recording", in: app)
        XCTAssertTrue(reveal(text("Intensity", in: app), in: app))
        XCTAssertEqual(app.descendants(matching: .any)["coach-max-heart-rate"].label, "Max 190 bpm · est.")
        XCTAssertTrue(reveal(text("Z5 Max", in: app), in: app))
        XCTAssertTrue(text("Z5 Max", in: app).label.contains("40%"))
        XCTAssertTrue(reveal(app.descendants(matching: .any)["coach-hard-efforts"], in: app))
        XCTAssertTrue(app.descendants(matching: .any)["coach-hard-efforts"].label.hasPrefix("47"))
        XCTAssertTrue(reveal(text("You faded in the second half", in: app), in: app))
        XCTAssertTrue(text("from 110 to 70 m/min", in: app).exists)
        capture(app, "degraded-06-good-coverage-still-has-insights")
        deleteCurrentSession(in: app)
        openSession("Football · Watch recording", in: app)
        deleteCurrentSession(in: app)
        openSession("Training · Manual log", in: app)
        deleteCurrentSession(in: app)
        back(app)
        XCTAssertTrue(reveal(app.buttons["Full plan"], in: app))
        app.buttons["Full plan"].tap()
        XCTAssertTrue(text("Building history", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["coach-chronic"].label.contains("—"))
        XCTAssertFalse(app.otherElements["Load ratio"].exists)
        XCTAssertFalse(text("Load spike", in: app).exists)
        XCTAssertFalse(text("Ease back in after a quiet week", in: app).exists)
        capture(app, "degraded-07-short-history-stays-neutral")
        back(app)
        app.tabBars.buttons["Progress"].tap()
        XCTAssertTrue(text("Sessions, 4 weeks", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["coach-outings"].label.hasPrefix("2"))
        capture(app, "degraded-08-fragment-excluded-from-outing-count")
    }

    private func assertLimitedEvidence(in app: XCUIApplication) {
        XCTAssertTrue(reveal(text("HR coverage is too sparse or starts too late", in: app), in: app))
        XCTAssertFalse(text("Z5 Max", in: app).exists)
        XCTAssertFalse(app.descendants(matching: .any)["coach-zones"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["coach-high-intensity"].exists)
        XCTAssertTrue(reveal(text("Distance coverage is too limited", in: app), in: app))
        let efforts = app.descendants(matching: .any)["coach-hard-efforts"]
        XCTAssertTrue(reveal(efforts, in: app))
        XCTAssertTrue(efforts.label.contains("—"))
        let interval = app.descendants(matching: .any)["coach-effort-recovery"]
        XCTAssertTrue(reveal(interval, in: app))
        XCTAssertTrue(interval.label.contains("—"))
        XCTAssertFalse(text("You faded in the second half", in: app).exists)
        XCTAssertFalse(text("You held your pace", in: app).exists)
        XCTAssertFalse(text("How to get better", in: app).exists)
    }

    private func deleteCurrentSession(in app: XCUIApplication) {
        app.buttons["Session actions"].tap()
        app.buttons["Delete iPhone copy"].tap()
        let confirmation = app.buttons["Delete iPhone copy"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        XCTAssertTrue(text("Session unavailable", in: app).waitForExistence(timeout: 10))
        back(app)
    }

    private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func openSession(_ value: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
        XCTAssertTrue(reveal(row, in: app))
        row.tap()
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<18 {
            if element.exists && element.isHittable { return true }
            if element.exists && element.frame.midY < app.windows.firstMatch.frame.midY {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
        return element.exists && element.isHittable
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
