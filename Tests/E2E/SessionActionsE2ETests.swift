// Failure coverage:
// 1. Export cannot open or dismiss, or leaves navigation blocked: export journey.
// 2. Dismissing the confirmation deletes data, confirmation fails, or either tab keeps stale counts: deletion journey.
// 3. The interrupted hero loses its reason or its 40 min / 3.7 km values touch: interrupted journey.
// 4. XXXL hero captions truncate or stats and chart labels overlap: accessibility journey.
// Initial loading has no controlled completion gate. The many fixture duration depends on disk and CPU.
import XCTest

@MainActor
final class SessionActionsE2ETests: XCTestCase {
    func testExportDismissalFromMenuAndDetailsLeavesAppUsable() {
        let app = launch("one")
        openSession(containing: "Football · Watch recording", in: app)
        XCTAssertTrue(element("session-hero-duration", in: app).waitForExistence(timeout: 15))
        app.buttons["Session actions"].tap()
        app.buttons["Prepare exact export"].tap()
        app.buttons["Session actions"].tap()
        let share = app.buttons["Share verified package"]
        XCTAssertTrue(share.waitForExistence(timeout: 15))
        share.tap()
        dismissShareSheet(in: app, prefix: "export-menu")

        let details = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Details")).firstMatch
        XCTAssertTrue(reveal(details, in: app))
        details.tap()
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(share, in: app))
        share.tap()
        dismissShareSheet(in: app, prefix: "export-details")
        back(app)
        XCTAssertTrue(app.buttons["Session actions"].waitForExistence(timeout: 10))
        back(app)
        app.tabBars.buttons["Progress"].tap()
        assertCount(1, identifier: "coach-outings", in: app)
        capture(app, "export-dismissed-progress-usable")
    }

    func testConfirmedDeletionUpdatesSessionsAndProgressCounts() {
        let app = launch("demo")
        let weekCount = element("week-stat-sessions", in: app)
        XCTAssertTrue(weekCount.waitForExistence(timeout: 45))
        let before = firstInteger(weekCount.label)
        app.tabBars.buttons["Progress"].tap()
        assertCount(4, identifier: "coach-outings", in: app)
        capture(app, "delete-before-progress-four-sessions")
        app.tabBars.buttons["Sessions"].tap()
        openSession(containing: "Football · Watch recording", in: app)
        XCTAssertTrue(element("session-hero-duration", in: app).waitForExistence(timeout: 15))

        openDeleteConfirmation(in: app)
        capture(app, "delete-confirmation-cancel")
        dismissPopover(in: app)
        XCTAssertTrue(app.popovers.firstMatch.waitForNonExistence(timeout: 10), "Delete confirmation did not dismiss")
        XCTAssertTrue(element("session-hero-duration", in: app).exists)
        back(app)
        assertCount(before, identifier: "week-stat-sessions", in: app)
        app.tabBars.buttons["Progress"].tap()
        assertCount(4, identifier: "coach-outings", in: app)
        app.tabBars.buttons["Sessions"].tap()
        openSession(containing: "Football · Watch recording", in: app)
        XCTAssertTrue(element("session-hero-duration", in: app).waitForExistence(timeout: 15))
        openDeleteConfirmation(in: app)
        app.buttons["Delete iPhone copy"].firstMatch.tap()
        XCTAssertTrue(text("Session unavailable", in: app).waitForExistence(timeout: 15))
        back(app)
        assertCount(max(0, before - 1), identifier: "week-stat-sessions", in: app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Football · Watch recording")).firstMatch.exists)
        capture(app, "delete-after-sessions-count")
        app.tabBars.buttons["Progress"].tap()
        assertCount(3, identifier: "coach-outings", in: app)
        capture(app, "delete-after-progress-three-sessions")
    }

    func testInterruptedHeroShowsReasonAndSeparatedMetrics() {
        let app = launch("coach")
        let seeAll = app.buttons["See all"]
        XCTAssertTrue(reveal(seeAll, in: app))
        seeAll.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Interrupted")).firstMatch
        XCTAssertTrue(reveal(row, in: app))
        XCTAssertTrue(row.label.contains("40 min"))
        row.tap()
        let status = element("session-hero-interrupted", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 15))
        XCTAssertTrue(status.label.contains("Interrupted"))
        XCTAssertTrue(status.label.contains("The workout ended unexpectedly."))
        let duration = element("session-hero-duration", in: app)
        let distance = element("session-hero-distance", in: app)
        XCTAssertTrue(duration.label.contains("40 min"))
        XCTAssertTrue(distance.label.contains("3.7 km"))
        XCTAssertGreaterThanOrEqual(distance.frame.minX - duration.frame.maxX, 12)
        capture(app, "interrupted-hero-reason-and-metric-gap")
    }

    func testAccessibilityXXXLWeekHeroKeepsFullCaptionsAndStacksStats() {
        let app = launch("coach", contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        let specs = [
            ("week-stat-sessions", "session"),
            ("week-stat-minutes", "minutes"),
            ("week-stat-distance", "distance"),
        ]
        for (identifier, caption) in specs {
            let stat = element(identifier, in: app)
            XCTAssertTrue(reveal(stat, in: app))
            XCTAssertTrue(stat.label.contains(caption))
            XCTAssertFalse(stat.label.contains("…"))
            XCTAssertFalse(stat.label.contains("..."))
            capture(app, "xxxl-full-\(caption)-caption")
        }
        let sessions = element("week-stat-sessions", in: app)
        let minutes = element("week-stat-minutes", in: app)
        let distance = element("week-stat-distance", in: app)
        // A combined accessibility element reports its text bounds, not the stretched row,
        // so stacking is proven by vertical order and a shared leading edge.
        XCTAssertEqual(minutes.frame.minX, sessions.frame.minX, accuracy: 2)
        XCTAssertEqual(distance.frame.minX, sessions.frame.minX, accuracy: 2)
        XCTAssertGreaterThanOrEqual(minutes.frame.minY - sessions.frame.maxY, 8)
        XCTAssertGreaterThanOrEqual(distance.frame.minY - minutes.frame.maxY, 8)
        let chart = element("week-load-chart", in: app)
        XCTAssertTrue(reveal(chart, in: app))
        XCTAssertFalse(chart.label.isEmpty)
        XCTAssertGreaterThanOrEqual(chart.frame.minY - distance.frame.maxY, 8)
        capture(app, "xxxl-week-chart-without-overlapping-axis-labels")
    }

    private func launch(_ scenario: String, contentSize: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = [
            "-FP_UI_QA", "YES", "-onboardingCompleted", "YES",
            "-FP_QA_SCENARIO", scenario, "-FP_QA_TAB", "sessions",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", contentSize,
        ]
        app.launch()
        XCTAssertTrue(element("week-hero", in: app).waitForExistence(timeout: 45))
        return app
    }

    private func openDeleteConfirmation(in app: XCUIApplication) {
        app.buttons["Session actions"].tap()
        app.buttons["Delete iPhone copy"].tap()
        XCTAssertTrue(text("Delete iPhone copy?", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(text("It does not alter Health data", in: app).exists)
    }

    private func dismissShareSheet(in app: XCUIApplication, prefix: String) {
        let sheet = element("ShareSheet.RemoteContainerView", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 15), "Share sheet did not open")
        capture(app, "\(prefix)-share-sheet")
        dismissPopover(in: app)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Share sheet did not dismiss")
        capture(app, "\(prefix)-dismissed")
    }

    /// iOS 27 shows confirmation dialogs and the share sheet as popovers with no Cancel or
    /// Close button; the system dismiss control is the tap-outside region.
    private func dismissPopover(in app: XCUIApplication) {
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel"])).firstMatch
        if close.exists && close.isHittable {
            close.tap()
            return
        }
        let region = app.otherElements["PopoverDismissRegion"]
        XCTAssertTrue(region.waitForExistence(timeout: 5), "Popover must expose the system dismiss region")
        let popover = app.popovers.firstMatch.frame
        let window = app.windows.firstMatch.frame
        let dy = popover.midY > window.midY ? 0.15 : 0.85
        region.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy)).tap()
    }

    private func openSession(containing value: String, in app: XCUIApplication) {
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
        XCTAssertTrue(reveal(row, in: app))
        row.tap()
    }

    private func assertCount(_ expected: Int, identifier: String, in app: XCUIApplication) {
        let count = element(identifier, in: app)
        XCTAssertTrue(reveal(count, in: app))
        XCTAssertEqual(firstInteger(count.label), expected, count.label)
    }

    private func firstInteger(_ label: String) -> Int {
        label.split(whereSeparator: { !$0.isNumber }).first.flatMap { Int($0) } ?? -1
    }

    private func text(_ value: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<20 {
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
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
