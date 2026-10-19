import XCTest

/// End-to-end coaching journeys against the real app, driven by the
/// deterministic "coach" QA fixture (`-FP_QA_SCENARIO coach`).
///
/// Ways the coaching feature can fail, and the scenario that covers each:
/// 1. The fixture or real packages do not decode into the library, so the
///    screens fall back to the empty state.                 → all journeys
/// 2. Load is measured wrongly (manual or interrupted sessions dropped from
///    load, wrong 7- and 28-day windows) or tips rank wrongly, so the
///    focus tip is not the load spike.                       → coaching journey
/// 3. Manual or interrupted sessions leak into the personal baseline, so
///    the work-rate comparison quotes the wrong percentage.  → coaching journey
/// 4. Per-session insights break on decoded snapshots (cumulative distance,
///    heart-rate sampling), so Intensity or the fade takeaway is missing or
///    quotes wrong paces.                                    → coaching journey
/// 5. The age setting does not reach heart-rate zones (key mismatch, stale
///    cached insights).                                      → age journey
/// 6. A manual log is shown sensor insights it cannot have.  → manual journey
/// 7. An empty history shows coaching or crashes.            → empty journey
///
/// Every journey attaches screenshots to the result bundle; CI exports them.
/// To reproduce locally, run the FootballPerformanceE2E scheme on any iOS 26
/// iPhone simulator.
@MainActor
final class CoachingE2ETests: XCTestCase {

    // MARK: - Journeys

    func testCoachingJourneyFromLoadSpikeToSessionTakeaways() {
        let app = launch(scenario: "coach")

        // Home: the load spike outranks everything else, quoting the
        // 7-day minutes (3 matches + 1 manual log) against the usual week.
        let focus = app.element(containing: "Your load jumped this week")
        XCTAssertTrue(focus.waitForExistence(timeout: 30), "Focus tip missing; fixture may not have loaded")
        XCTAssertTrue(app.element(containing: "330 min in the last 7 days against a usual 55 min a week").exists)
        XCTAssertTrue(app.element(containing: "THIS WEEK").exists)
        capture(app, "01-home-load-spike")

        // Full plan: personal tips first, quoting the baseline built only
        // from completed watch recordings, then labelled foundations.
        app.buttons["Full plan"].tap()
        XCTAssertTrue(app.element(containing: "From your sessions").waitForExistence(timeout: 10))
        XCTAssertTrue(app.element(containing: "Load spike").exists)
        XCTAssertTrue(reveal(app.element(containing: "Heart rate ran high for the work done"), in: app))
        XCTAssertTrue(reveal(app.element(containing: "10% below your baseline of 100 m/min"), in: app))
        capture(app, "02-plan-personal")
        XCTAssertTrue(reveal(app.element(containing: "Foundations"), in: app))
        XCTAssertTrue(reveal(app.element(containing: "General football-fitness guidance"), in: app))
        capture(app, "03-plan-foundations")
        goBack(app)

        // Latest session: intensity from heart rate, and the second-half
        // fade computed from cumulative distance (110 → 70 m/min).
        openSession(app, containing: "11-a-side · Watch recording")
        XCTAssertTrue(app.element(containing: "11-a-side · Watch recording").waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.element(containing: "Intensity"), in: app))
        XCTAssertTrue(app.element(containing: "estimated; set your age").exists)
        capture(app, "04-session-intensity")
        XCTAssertTrue(reveal(app.element(containing: "You faded in the second half"), in: app))
        XCTAssertTrue(app.element(containing: "from 110 to 70 m/min").exists)
        XCTAssertTrue(app.element(containing: "4 × 4 intervals").exists)
        capture(app, "05-session-takeaways")

        // Progress shows the same load and the top tips with drills.
        goBack(app)
        app.tabBars.buttons["Progress"].tap()
        XCTAssertTrue(app.element(containing: "Training load").waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.element(containing: "How to get better"), in: app))
        capture(app, "06-progress")
    }

    func testAgeSettingRecalculatesHeartRateZones() {
        let app = launch(scenario: "coach")
        XCTAssertTrue(app.element(containing: "Your load jumped this week").waitForExistence(timeout: 30))

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.element(containing: "Not set").waitForExistence(timeout: 10))
        // The stepper starts from 30 when unset; one step sets 31.
        let increment = app.steppers.firstMatch.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Increment")
        ).firstMatch
        XCTAssertTrue(increment.waitForExistence(timeout: 5))
        increment.tap()
        XCTAssertTrue(app.element(containing: "186 bpm").waitForExistence(timeout: 5))
        capture(app, "07-settings-age")

        app.tabBars.buttons["Sessions"].tap()
        openSession(app, containing: "11-a-side · Watch recording")
        XCTAssertTrue(reveal(app.element(containing: "Max 186 bpm from your age"), in: app))
        capture(app, "08-session-zones-from-age")
    }

    func testManualLogCountsAsLoadButGetsNoSensorInsights() {
        let app = launch(scenario: "coach")
        XCTAssertTrue(app.element(containing: "Your load jumped this week").waitForExistence(timeout: 30))

        let seeAll = app.buttons["See all"]
        XCTAssertTrue(reveal(seeAll, in: app))
        seeAll.tap()
        openSession(app, containing: "Training · Manual log")
        XCTAssertTrue(app.element(containing: "No sensor readings were recorded").waitForExistence(timeout: 10))
        XCTAssertFalse(app.element(containing: "Intensity").exists)
        XCTAssertFalse(app.element(containing: "How to get better").exists)
        capture(app, "09-manual-log")
    }

    func testEmptyHistoryShowsStartGuidanceWithoutCoaching() {
        let app = launch(scenario: "empty")
        XCTAssertTrue(app.element(containing: "No sessions yet").waitForExistence(timeout: 30))
        XCTAssertFalse(app.element(containing: "Your focus").exists)
        XCTAssertFalse(app.element(containing: "THIS WEEK").exists)
        XCTAssertTrue(app.buttons["add-session"].exists)
        capture(app, "10-empty")

        app.tabBars.buttons["Progress"].tap()
        XCTAssertTrue(app.element(containing: "No sessions in this range yet").waitForExistence(timeout: 10))
        XCTAssertFalse(app.element(containing: "How to get better").exists)
    }

    // MARK: - Helpers

    private func launch(scenario: String) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-FP_UI_QA", "YES",
            "-onboardingCompleted", "YES",
            "-FP_QA_SCENARIO", scenario,
            "-FP_QA_TAB", "sessions",
        ]
        app.launch()
        return app
    }

    private func openSession(_ app: XCUIApplication, containing text: String) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(reveal(row, in: app), "No session row containing \(text)")
        row.tap()
    }

    private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// Scrolls down until the element is on screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 10) -> Bool {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
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

private extension XCUIApplication {
    func element(containing text: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
    }
}
