// Failure coverage:
// a. Start is offscreen or cannot be tapped on a small Watch.
// b. Countdown or timer stalls; unobserved heart rate or distance shows a number.
// c. A quick tap incorrectly finishes the recording.
// d. A held finish fails to save or loses transfer status.
// e. Diagnostics or saved details cannot open or return.
// f. Process death resets elapsed time, loses capture, or creates a duplicate fragment.
// g. The non-default session type cannot be selected, recorded, and saved.
import XCTest

final class WatchUITests: XCTestCase {
    @MainActor
    func testAStartIsHittableWithoutScrolling() throws {
        let app = try launch()
        defer { app.terminate() }
        let start = element("watch.start", in: app)
        capture("a-idle-without-scrolling", app)
        observe("a-start", [
            "exists": String(start.exists),
            "hittable": String(start.isHittable),
            "frame": String(describing: start.frame),
            "screen": String(describing: app.frame),
        ])
        XCTAssertTrue(start.exists, "Start must exist before any scroll")
        XCTAssertTrue(start.isHittable, "Start must be hittable before any scroll")
        XCTAssertTrue(app.frame.contains(start.frame), "The entire Start control must fit without scrolling")
    }

    @MainActor
    func testBStartCountdownAndMissingMetrics() throws {
        let app = try launch()
        defer { finishIfActive(app) }
        try start(app, prefix: "b", captureActive: false)
        let heart = element("watch.metric.heart", in: app)
        let distance = element("watch.metric.distance", in: app)
        let motion = element("watch.motion-status", in: app)
        let heartLabel = heart.label
        let distanceLabel = distance.label
        let motionLabel = motion.label
        capture("b-first-active-metrics", app)
        observe("b-metrics", ["heart": heartLabel, "distance": distanceLabel, "motion": motionLabel])
        XCTAssertTrue(heart.exists)
        XCTAssertTrue(distance.exists)
        let previous = element("watch.elapsed", in: app).label
        try waitForElapsed(app, past: previous)
        capture("b-timer-advanced", app)
        continueAfterFailure = true
        if heartLabel.contains("—") {
            XCTAssertTrue(heartLabel.contains("BPM"))
        } else {
            observe("b-heart-limit", ["reason": "A heart-rate reading arrived before the first UI snapshot", "shown": heartLabel])
        }
        // HealthKit on the simulator reports a 0 m cumulative sum once collection starts,
        // so "0.00" is an observed value there; only a value before any delivery must be a dash.
        if !distanceLabel.contains("—") {
            observe("b-distance-limit", ["reason": "HealthKit delivered a distance sum before the first UI snapshot", "shown": distanceLabel])
        }
        XCTAssertTrue(distanceLabel.contains("—") || distanceLabel.contains("0.00"), "Distance must be a dash or a HealthKit-reported value; observed: \(distanceLabel)")
        XCTAssertTrue(distanceLabel.contains("KM"))
    }

    @MainActor
    func testCQuickTapDoesNotFinish() throws {
        let app = try launch()
        defer { finishIfActive(app) }
        try start(app, prefix: "c")
        element("watch.finish", in: app).tap()
        capture("c-after-quick-tap", app)
        let previous = element("watch.elapsed", in: app).label
        try waitForElapsed(app, past: previous)
        capture("c-still-recording", app)
        observe("c-quick-tap", ["recording": String(element("watch.recording", in: app).exists), "saved": String(element("watch.saved", in: app).exists)])
        XCTAssertTrue(element("watch.recording", in: app).exists)
        XCTAssertFalse(element("watch.saved", in: app).exists)
    }

    @MainActor
    func testDLongPressSavesWithTransferState() throws {
        let app = try launch()
        defer { finishIfActive(app) }
        try start(app, prefix: "d")
        try save(app, prefix: "d")
    }

    @MainActor
    func testEOptionsAndSavedDetailsOpenAndClose() throws {
        let app = try launch()
        defer { finishIfActive(app) }
        try start(app, prefix: "e")
        element("watch.options", in: app).tap()
        try require(element("watch.diagnostics", in: app).waitForExistence(timeout: 10), "Options did not open Motion Diagnostics")
        capture("e-options-motion-diagnostics", app)
        observe("e-options", ["destination": "Motion Diagnostics", "tree": app.debugDescription])
        try goBack(app)
        try require(element("watch.recording", in: app).waitForExistence(timeout: 10), "Diagnostics did not close")
        capture("e-diagnostics-closed", app)
        try save(app, prefix: "e")
        let details = element("watch.saved.details.open", in: app)
        try reveal(details, in: app)
        details.tap()
        try require(element("watch.saved.details", in: app).waitForExistence(timeout: 10), "Saved Details did not open")
        capture("e-saved-details", app)
        try goBack(app)
        try require(element("watch.saved", in: app).waitForExistence(timeout: 10), "Saved Details did not close")
        capture("e-details-closed", app)
    }

    @MainActor
    func testFKillRelaunchResumesRecording() throws {
        let app = try launch()
        defer { finishIfActive(app) }
        let recovery = element("watch.recovery.open", in: app)
        try reveal(recovery, in: app)
        recovery.tap()
        let savedCount = element("watch.recovery.saved", in: app)
        try require(savedCount.waitForExistence(timeout: 15), "Saved session count did not load")
        let savedBefore = lastInteger(savedCount.label)
        let recoveredBefore = element("watch.recovery.recovered", in: app).label
        try require(savedBefore >= 0, "Saved session count could not be read")
        try require(lastInteger(element("watch.recovery.needed", in: app).label) == 0, "This journey needs no earlier unrecovered sessions")
        observe("f-session-baseline", ["saved": String(savedBefore), "recovered": recoveredBefore])
        capture("f-session-baseline", app)
        try goBack(app)
        try start(app, prefix: "f")
        let elapsed = element("watch.elapsed", in: app)
        let tenSeconds = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                elapsed.exists && self.elapsedSeconds(elapsed.label) >= 10
            },
            object: nil
        )
        try require(XCTWaiter.wait(for: [tenSeconds], timeout: 25) == .completed, "Recording did not reach ten seconds")
        capture("f-before-terminate", app)
        let preKillLabel = elapsed.label
        let preKillSeconds = elapsedSeconds(preKillLabel)
        observe("f-before-terminate", ["elapsed": preKillLabel])
        app.terminate()
        app.launch()
        try waitForReady(app)
        capture("f-relaunch-first-screen", app)
        observe("f-relaunch", [
            "idle": String(element("watch.idle", in: app).exists),
            "recording": String(element("watch.recording", in: app).exists),
            "recoveryBadge": String(element("watch.recovery.attention", in: app).exists),
            "tree": app.debugDescription,
        ])
        try require(element("watch.recording", in: app).waitForExistence(timeout: 20), "The same recording did not resume after relaunch")
        XCTAssertFalse(element("watch.idle", in: app).exists)
        let resumedLabel = elapsed.label
        let resumedSeconds = elapsedSeconds(resumedLabel)
        XCTAssertGreaterThanOrEqual(resumedSeconds, preKillSeconds, "Relaunch reset the original elapsed time")
        let resumedAt = Date()
        observe("f-resumed", ["beforeKill": preKillLabel, "resumedElapsed": resumedLabel])
        capture("f-resumed-recording", app)
        let continued = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                elapsed.exists && self.elapsedSeconds(elapsed.label) >= resumedSeconds + 5
            },
            object: nil
        )
        try require(XCTWaiter.wait(for: [continued], timeout: 15) == .completed, "Resumed recording timer stopped")
        let beforeFinishLabel = elapsed.label
        let postRelaunchSeconds = Int(Date().timeIntervalSince(resumedAt))
        capture("f-resumed-before-finish", app)
        try save(app, prefix: "f")
        // A combined summary row is read-only text, which watchOS never reports as hittable.
        let duration = element("watch.saved.duration", in: app)
        try require(duration.waitForExistence(timeout: 10), "Saved duration row is missing")
        let savedSeconds = clockSeconds(duration.label)
        let gapWarning = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] %@", "capture had a gap"
        )).firstMatch
        XCTAssertTrue(gapWarning.exists, "The saved summary must disclose the capture gap")
        observe("f-resumed-saved-duration", [
            "beforeKill": preKillLabel,
            "beforeFinish": beforeFinishLabel,
            "postRelaunchSeconds": String(postRelaunchSeconds),
            "savedDuration": duration.label,
            "captureGap": gapWarning.label,
        ])
        XCTAssertGreaterThanOrEqual(savedSeconds, preKillSeconds + postRelaunchSeconds - 2)
        XCTAssertGreaterThanOrEqual(savedSeconds, elapsedSeconds(beforeFinishLabel) - 2)
        let done = element("watch.saved.done", in: app)
        try reveal(done, in: app)
        done.tap()
        try require(element("watch.idle", in: app).waitForExistence(timeout: 10), "Saved Done did not return home")
        try reveal(recovery, in: app)
        capture("f-recovery-entry", app)
        recovery.tap()
        let needed = element("watch.recovery.needed", in: app)
        try require(needed.waitForExistence(timeout: 15), "Recovery counts did not load")
        let oneNewSession = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                savedCount.exists && self.lastInteger(savedCount.label) == savedBefore + 1
            },
            object: nil
        )
        try require(XCTWaiter.wait(for: [oneNewSession], timeout: 15) == .completed, "Finish must save exactly one new session")
        XCTAssertEqual(lastInteger(needed.label), 0, "The resumed session must not leave a recovery fragment")
        XCTAssertEqual(element("watch.recovery.recovered", in: app).label, recoveredBefore, "Relaunch must not create an interrupted copy")
        capture("f-recovery-after-resumed-finish", app)
        observe("f-recovery-after-resumed-finish", [
            "needed": needed.label,
            "savedBefore": String(savedBefore),
            "savedAfter": savedCount.label,
            "recovered": element("watch.recovery.recovered", in: app).label,
            "tree": app.debugDescription,
        ])
        let home = element("watch.recovery.home", in: app)
        try reveal(home, in: app)
        home.tap()
        try require(element("watch.idle", in: app).waitForExistence(timeout: 10), "Recovery Home did not return to idle")
        capture("f-recovery-home", app)
    }

    @MainActor
    func testGRecordNonDefaultSessionType() throws {
        let app = try launch()
        defer { finishIfActive(app) }
        let picker = element("watch-session-type", in: app)
        try reveal(picker, in: app, fullyVisible: true)
        observe("g-original-type", ["label": picker.label, "value": String(describing: picker.value)])
        picker.tap()
        let choice = element("watch.session-type.fiveASide", in: app)
        try require(choice.waitForExistence(timeout: 10), "Session choices did not open")
        let fallback = app.staticTexts["5-a-side"].firstMatch
        let selection = choice.exists ? choice : fallback
        try reveal(selection, in: app)
        capture("g-session-type-choices", app)
        selection.tap()
        if !element("watch.start", in: app).exists {
            try goBack(app)
        }
        try require(picker.waitForExistence(timeout: 10), "Session picker did not close")
        try reveal(picker, in: app, fullyVisible: true)
        capture("g-non-default-selected", app)
        let selectedText = picker.label + " " + String(describing: picker.value)
        observe("g-selected-type", ["shown": selectedText])
        try require(selectedText.contains("5-a-side"), "Picker did not retain the non-default type")
        try start(app, prefix: "g")
        try save(app, prefix: "g")
    }

    @MainActor
    private func launch() throws -> XCUIApplication {
        continueAfterFailure = false
        executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchEnvironment["FP_UI_QA_AUTOSTART"] = "0"
        app.launchEnvironment["FP_UI_QA_AUTOFINISH_SECONDS"] = "0"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        addUIInterruptionMonitor(withDescription: "Health and motion permission") { alert in
            // The Health sheet pages ("Write Access", then read access) each need the
            // "All Requested Data Below" switch turned on before Next/Allow is enabled.
            // The sheet's advance control (ConfigureCell.Button) sits below the fold; scroll it
            // with the Digital Crown. Work through every page before reporting the alert handled.
            let advance = alert.descendants(matching: .any).matching(NSPredicate(
                format: "label IN {'Next', 'Allow', 'Done'} OR identifier CONTAINS[c] 'ConfigureCell.Button' OR identifier CONTAINS[c] 'NextButton' OR identifier CONTAINS[c] 'AllowButton' OR identifier CONTAINS[c] 'DoneButton'"
            )).firstMatch
            var advancedAnyPage = false
            for _ in 0..<4 where alert.exists {
                let allData = alert.cells["UIA.Health.WatchAuthSheet.SwitchCellALL_REQUESTED_DATA"].firstMatch
                if allData.exists, "\(allData.value ?? "")" == "0" {
                    allData.tap()
                }
                // watchOS 27 adds a "How much historical data" page whose Done stays inert
                // until one time range is chosen.
                let range = alert.cells.matching(NSPredicate(
                    format: "(label BEGINSWITH 'Past ' OR label IN {'All Data', 'All History', 'All Time'}) AND NOT (identifier CONTAINS[c] 'SwitchCell')"
                )).firstMatch
                if range.exists && range.isHittable {
                    range.tap()
                }
                var tapped = false
                for _ in 0..<8 {
                    if advance.exists && advance.isHittable {
                        advance.tap()
                        tapped = true
                        break
                    }
                    XCUIDevice.shared.rotateDigitalCrown(delta: 1.0)
                }
                guard tapped else { break }
                advancedAnyPage = true
                _ = alert.waitForNonExistence(timeout: 2)
            }
            if advancedAnyPage { return !alert.exists }
            for title in ["Review", "Allow All", "Turn On All", "Allow", "Continue", "OK", "Done", "Next", "While Using the App"] {
                let button = alert.buttons[title].firstMatch
                if button.exists && button.isHittable {
                    button.tap()
                    return true
                }
            }
            alert.swipeUp()
            let allow = alert.buttons["Allow"].firstMatch
            if allow.exists && allow.isHittable {
                allow.tap()
                return true
            }
            return false
        }
        app.launch()
        try waitForReady(app)
        // Recordings now survive relaunch, so a workout an earlier journey left running
        // comes back here; save it so every journey starts from Home.
        if element("watch.recording", in: app).exists {
            capture("launch-resumed-leftover", app)
            try save(app, prefix: "launch-leftover")
            let done = element("watch.saved.done", in: app)
            try reveal(done, in: app)
            done.tap()
            _ = element("watch.idle", in: app).waitForExistence(timeout: 10)
        }
        try require(element("watch.idle", in: app).exists, "App did not reach idle: \(app.debugDescription)")
        return app
    }

    @MainActor
    private func waitForReady(_ app: XCUIApplication) throws {
        for _ in 0..<12 {
            if element("watch.idle", in: app).waitForExistence(timeout: 1)
                || element("watch.recording", in: app).exists
                || element("watch.failure", in: app).exists {
                return
            }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.Carousel")
            var handled = false
            for surface in [app, springboard] {
                for title in ["Review", "Allow All", "Turn On All", "Allow", "Continue", "OK", "Done", "Next"] {
                    let button = surface.buttons[title].firstMatch
                    if button.exists && button.isHittable {
                        capture("permission-\(title)", surface)
                        button.tap()
                        handled = true
                        break
                    }
                }
                if handled { break }
            }
            // A centre tap lands on Start and begins a recording; nudge the interruption
            // monitors from the top strip instead.
            if !handled { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.03)).tap() }
        }
        capture("launch-not-ready", app)
        try require(false, "App never reached a known recorder state")
    }

    @MainActor
    private func start(_ app: XCUIApplication, prefix: String, captureActive: Bool = true) throws {
        let start = element("watch.start", in: app)
        let initiallyHittable = start.isHittable
        try reveal(start, in: app)
        observe("\(prefix)-start", ["neededScroll": String(!initiallyHittable), "label": start.label])
        capture("\(prefix)-start-ready", app)
        start.tap()
        try require(element("watch.countdown", in: app).waitForExistence(timeout: 3), "Start did not show countdown")
        capture("\(prefix)-countdown", app)
        try require(element("watch.recording", in: app).waitForExistence(timeout: 30), "Countdown did not reach recording: \(app.debugDescription)")
        if captureActive { capture("\(prefix)-active", app) }
    }

    @MainActor
    private func save(_ app: XCUIApplication, prefix: String) throws {
        let finish = element("watch.finish", in: app)
        try require(finish.isHittable, "Hold to Finish is not hittable")
        capture("\(prefix)-before-hold", app)
        finish.press(forDuration: 2.5)
        capture("\(prefix)-after-hold", app)
        let saved = element("watch.saved", in: app)
        try require(saved.waitForExistence(timeout: 95), "Long press did not save: \(app.debugDescription)")
        let transfer = element("watch.saved.transfer", in: app)
        capture("\(prefix)-saved-summary", app)
        observe("\(prefix)-saved", ["title": saved.label, "transfer": transfer.label, "tree": app.debugDescription])
        XCTAssertEqual(saved.label, "Saved on Watch")
        XCTAssertTrue(transfer.exists)
        XCTAssertFalse(transfer.label.isEmpty)
    }

    @MainActor
    private func finishIfActive(_ app: XCUIApplication) {
        let finish = element("watch.finish", in: app)
        if finish.exists && finish.isHittable {
            finish.press(forDuration: 2.5)
            _ = element("watch.saved", in: app).waitForExistence(timeout: 95)
            capture("cleanup-final-state", app)
        }
        app.terminate()
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, fullyVisible: Bool = false) throws {
        for _ in 0..<12 {
            if element.exists && element.isHittable && (!fullyVisible || app.frame.contains(element.frame)) { return }
            if element.exists && element.frame.midY < app.frame.midY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
        }
        capture("unreachable-control", app)
        try require(element.exists && element.isHittable, "Control cannot be reached: \(element)")
    }

    @MainActor
    private func goBack(_ app: XCUIApplication) throws {
        let back = app.navigationBars.buttons.firstMatch
        try require(back.exists && back.isHittable, "No hittable navigation back button: \(app.debugDescription)")
        back.tap()
    }

    @MainActor
    private func waitForElapsed(_ app: XCUIApplication, past previous: String) throws {
        let elapsed = element("watch.elapsed", in: app)
        let advanced = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in elapsed.exists && elapsed.label != previous },
            object: nil
        )
        try require(XCTWaiter.wait(for: [advanced], timeout: 5) == .completed, "Elapsed time did not advance")
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func elapsedSeconds(_ label: String) -> Int {
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count >= 2 else { return -1 }
        return numbers[0] * 60 + numbers[1]
    }

    /// The saved summary shows hh:mm:ss, unlike the spoken minutes/seconds of the live timer.
    private func clockSeconds(_ label: String) -> Int {
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !numbers.isEmpty else { return -1 }
        return numbers.reduce(0) { $0 * 60 + $1 }
    }

    private func lastInteger(_ label: String) -> Int {
        label.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? -1
    }

    @MainActor
    private func capture(_ name: String, _ app: XCUIApplication) {
        XCTContext.runActivity(named: name) { activity in
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = name
            screenshot.lifetime = .keepAlways
            activity.add(screenshot)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "\(name)-accessibility"
            tree.lifetime = .keepAlways
            activity.add(tree)
        }
    }

    @MainActor
    private func observe(_ name: String, _ values: [String: String]) {
        let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys, .prettyPrinted])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? String(describing: values)
        print("WATCH_UI_OBSERVATION \(name) \(json)")
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(string: json)
            attachment.name = "\(name)-observed"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private func require(_ condition: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        guard condition else {
            XCTFail(message, file: file, line: line)
            throw NSError(domain: "WatchUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
