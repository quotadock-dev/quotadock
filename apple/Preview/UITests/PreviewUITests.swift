import XCTest

// Only the isolated QD Preview app, never production or its persistence harness.
// Device runs require a fresh preview installation authorized for UI testing.
final class PreviewUITests: XCTestCase {
    func testLowQuotaMarkersAreOptInIndependentAndExpireWithoutCollection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        for korean in [false, true] {
            for largest in [false, true] {
                let variant = "\(korean ? "KO" : "EN")-alerts-\(largest ? "largest-dark" : "normal-light")"
                app.launchArguments = ["--quota-alert-preview", korean ? "--language-ko-preview" : "--language-en-preview"]
                    + (largest ? ["--history-largest-preview"] : [])
                app.launch()
                let context = app.staticTexts["quota-alert-preview-context"]
                XCTAssertTrue(context.waitForExistence(timeout: 8))
                let raw = XCTAttachment(string: context.label)
                raw.name = variant + "-context"; raw.lifetime = .keepAlways; add(raw)
                XCTAssertTrue(context.label.contains(korean ? "locale=ko" : "locale=en"))
                XCTAssertTrue(context.label.contains(largest ? "type=accessibility5" : "type=large"))
                XCTAssertTrue(context.label.contains(largest ? "scheme=dark" : "scheme=light"))
                XCTAssertEqual(app.staticTexts["quota-alert-preview-notice"].label,
                               korean ? "UI 프리뷰 · 샘플 데이터 전용" : "UI PREVIEW · sample data only")
                let toggle = app.switches["quota-alerts-enabled"]
                assertHistoryFullyReachable(toggle, in: app, name: variant + " off control")
                XCTAssertEqual(toggle.value as? String, "0")
                captureAlerts(app, variant + "-off", reading: toggle)
                pressAlertSwitch(toggle, in: app, name: variant + " enable")
                captureAlerts(app, variant + "-enabled", reading: toggle)
                let marker20 = korean ? "20% 이하로 관측됨" : "Observed at or below 20%"
                let marker30 = korean ? "30% 이하로 관측됨" : "Observed at or below 30%"
                func reading(_ label: String) -> XCUIElement {
                    app.descendants(matching: .any).matching(NSPredicate(
                        format: "label == %@ AND value != nil", label)).firstMatch
                }
                let session = reading(korean ? "세션" : "Session")
                let weekly = reading(korean ? "주간" : "Weekly")
                let credits = reading(korean ? "크레딧" : "Credits")
                for (element, expected, marked) in [
                    (session, korean ? "0% 남음" : "0% remaining", true),
                    (weekly, korean ? "잔여량 알 수 없음" : "Remaining unknown", false),
                    (credits, korean ? "20% 남음" : "20% remaining", false)
                ] {
                    assertHistoryFullyReachable(element, in: app, name: variant + " 20% " + expected)
                    captureAlerts(app, variant + "-20-" + element.label, reading: element)
                    XCTAssertTrue((element.value as? String ?? "").hasPrefix(expected))
                    XCTAssertEqual((element.value as? String ?? "").contains(marker20), marked)
                }
                // 20.001% rounds to 20% on screen, but must not mark at 20%.
                // A larger threshold must mark that same independent window.
                scrollAlertsToTop(app)
                let picker = app.buttons["quota-alert-threshold"]
                assertHistoryFullyReachable(picker, in: app, name: variant + " threshold control")
                picker.tap(); app.buttons["30%"].tap()
                app.terminate(); app.launch()
                XCTAssertTrue(toggle.waitForExistence(timeout: 8))
                XCTAssertEqual(toggle.value as? String, "1")
                for element in [session, credits] {
                    assertHistoryFullyReachable(element, in: app, name: variant + " restored 30% " + element.label)
                    captureAlerts(app, variant + "-30-" + element.label, reading: element)
                    XCTAssertTrue((element.value as? String ?? "").contains(marker30))
                }
                // Both are fresh and zero: only their demo/history role excludes them.
                for label in [korean ? "일간" : "Daily", "Pro"] {
                    let excluded = reading(label)
                    assertHistoryFullyReachable(excluded, in: app, name: variant + " excluded " + label)
                    captureAlerts(app, variant + "-excluded-" + label, reading: excluded)
                    XCTAssertTrue((excluded.value as? String ?? "").hasPrefix(korean ? "0% 남음" : "0% remaining"))
                    XCTAssertFalse((excluded.value as? String ?? "").contains(marker30))
                }
                if !korean && !largest {
                    scrollAlertsToTop(app)
                    let expire = app.buttons["quota-alert-preview-expire"]
                    assertHistoryFullyReachable(expire, in: app, name: variant + " expiry control")
                    expire.tap()
                    assertHistoryFullyReachable(session, in: app, name: variant + " before expiry")
                    XCTAssertTrue((session.value as? String ?? "").contains(marker30))
                    let expired = XCTNSPredicateExpectation(predicate: NSPredicate(
                        format: "NOT (value CONTAINS %@)", marker30), object: session)
                    XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 25), .completed)
                    XCTAssertTrue((session.value as? String ?? "").hasPrefix("0% remaining"))
                    captureAlerts(app, variant + "-expired", reading: session)
                }
                scrollAlertsToTop(app)
                assertHistoryFullyReachable(toggle, in: app, name: variant + " disable control")
                pressAlertSwitch(toggle, in: app, name: variant + " disable")
                app.terminate(); app.launch()
                XCTAssertTrue(toggle.waitForExistence(timeout: 8))
                XCTAssertEqual(toggle.value as? String, "0")
                assertHistoryFullyReachable(session, in: app, name: variant + " disabled reading")
                XCTAssertFalse((session.value as? String ?? "").contains(marker30))
                captureAlerts(app, variant + "-disabled", reading: session)
                app.terminate()
            }
        }
    }

    private func pressAlertSwitch(_ element: XCUIElement, in app: XCUIApplication, name: String) {
        // Form's outer AX switch spans the label. Its center tap was at x=201,
        // outside the actual x=313...364 control. Use the established production
        // onboarding gesture, retaining the state-change assertion (no retries).
        let nested = element.switches.firstMatch
        let control = nested.exists ? nested : element
        assertHistoryFullyReachable(control, in: app, name: name + " native switch")
        let wasOn = control.value as? String == "1"
        control.coordinate(withNormalizedOffset: CGVector(dx: wasOn ? 0.8 : 0.2, dy: 0.5)).press(forDuration: 0.3)
        XCTAssertEqual(element.value as? String, wasOn ? "0" : "1", name)
    }

    private func captureAlerts(_ app: XCUIApplication, _ name: String, reading: XCUIElement? = nil) {
        capture(app, name)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-AX"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        if let reading {
            // debugDescription truncates long values; retain the actual public
            // accessibility value independently of that textual tree rendering.
            let value = XCTAttachment(string: "label=\(reading.label)\nvalue=\(reading.value as? String ?? "<nil>")\nframe=\(reading.frame)")
            value.name = name + "-value"; value.lifetime = .keepAlways; add(value)
        }
    }

    private func scrollAlertsToTop(_ app: XCUIApplication) {
        let context = app.staticTexts["quota-alert-preview-context"]
        for _ in 0..<12 {
            if context.exists && context.isHittable && context.frame.minY > app.navigationBars.firstMatch.frame.maxY { return }
            app.swipeDown()
        }
        XCTFail("Could not return to low-quota controls")
    }

    func testHistoryPreservesIndependentReadingsAcrossLanguagesAndTextSizes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        for korean in [false, true] {
            for largest in [false, true] {
                let variant = "\(korean ? "KO" : "EN")-history-\(largest ? "largest-dark" : "normal-light")"
                app.launchArguments = ["--history-preview", korean ? "--language-ko-preview" : "--language-en-preview"]
                    + (largest ? ["--history-largest-preview"] : [])
                app.launch()
                let context = app.staticTexts["history-preview-context"]
                XCTAssertTrue(context.waitForExistence(timeout: 8))
                let rawContext = XCTAttachment(string: context.label)
                rawContext.name = variant + "-context"; rawContext.lifetime = .keepAlways; add(rawContext)
                XCTAssertTrue(context.label.contains(korean ? "locale=ko" : "locale=en"))
                XCTAssertTrue(context.label.contains(largest ? "type=accessibility5" : "type=large"))
                XCTAssertTrue(context.label.contains(largest ? "scheme=dark" : "scheme=light"))
                XCTAssertEqual(app.staticTexts["history-preview-notice"].label,
                               korean ? "UI 프리뷰 · 샘플 데이터 전용" : "UI PREVIEW · sample data only")
                capture(app, variant + "-top")
                let expected = korean
                    ? [("세션", "0% 남음"), ("주간", "잔여량 알 수 없음"), ("크레딧", "42.75% 남음")]
                    : [("Session", "0% remaining"), ("Weekly", "Remaining unknown"), ("Credits", "42.75% remaining")]
                for (label, value) in expected {
                    let reading = app.descendants(matching: .any).matching(
                        NSPredicate(format: "label == %@ AND value BEGINSWITH %@", label, value)).firstMatch
                    assertHistoryFullyReachable(reading, in: app, name: "\(variant): \(label): \(value)")
                    capture(app, variant + "-" + label)
                }
                let timestamp = app.staticTexts["2026-10-21T05:00:00.123999Z"]
                assertHistoryFullyReachable(timestamp, in: app, name: variant + " original timestamp")
                XCTAssertFalse(app.buttons["Connect with Apple"].exists)
                XCTAssertFalse(app.buttons["Apple로 연결"].exists)
                capture(app, variant + "-readings")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = variant + "-AX"; hierarchy.lifetime = .keepAlways; add(hierarchy)
                app.terminate()
            }
        }
    }

    private func assertHistoryFullyReachable(_ element: XCUIElement, in app: XCUIApplication, name: String) {
        // Hittable alone also accepts partially offscreen text. Check the whole
        // element below navigation and leave room above the home indicator.
        func visibleArea() -> CGRect {
            let top = app.navigationBars.firstMatch.frame.maxY + 8
            return CGRect(x: app.frame.minX, y: top, width: app.frame.width,
                          height: app.frame.maxY - 40 - top)
        }
        for _ in 0..<8 {
            if element.exists && element.isHittable && visibleArea().contains(element.frame) { break }
            let down = element.exists && element.frame.minY < visibleArea().minY
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.4 : 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.4))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, name)
        XCTAssertGreaterThan(element.frame.height, 0, name)
        XCTAssertTrue(visibleArea().contains(element.frame), "\(name): \(element.frame) outside \(visibleArea())")
        print("HISTORY REACH \(name): element=\(element.frame), viewport=\(visibleArea())")
    }

    func testOfflineSetupStatesLanguageAndRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        if app.buttons["preview-settings"].waitForExistence(timeout: 3) {
            app.buttons["preview-settings"].tap()
            chooseEnglish(app)
            app.buttons["preview-review-setup"].tap()
        } else {
            XCTAssertTrue(app.staticTexts["setup-heading"].waitForExistence(timeout: 5))
            chooseEnglish(app)
        }
        assertSetupHeading(app, title: "A little clarity before your next prompt.")
        capture(app, "EN-preview-welcome")
        app.buttons["setup-continue"].tap()
        assertSetupHeading(app, title: "Choose how to get started.")
        XCTAssertFalse(app.buttons["setup-route-bridge"].exists)
        XCTAssertFalse(app.buttons["setup-route-cloud"].exists)
        XCTAssertFalse(app.buttons["setup-continue"].isEnabled)
        assertNavigationUnobscured(app, button: app.buttons["Back"], noticeID: "preview-notice-setup")
        capture(app, "EN-preview-connection")
        app.buttons["setup-route-demo"].tap()
        app.buttons["setup-continue"].tap()
        assertSetupHeading(app, title: "Make it work your way.")
        XCTAssertTrue(app.staticTexts["Preview preferences are saved only in this separate app. No usage is collected or refreshed."].exists)
        assertNavigationUnobscured(app, button: app.buttons["Back"], noticeID: "preview-notice-setup")
        capture(app, "EN-preview-preferences")
        app.buttons["setup-continue"].tap()
        XCTAssertTrue(app.buttons["preview-scenario"].waitForExistence(timeout: 5))
        assertNavigationUnobscured(app, button: app.buttons["preview-settings"], noticeID: "preview-notice-dashboard")
        assertSession(app, value: "72% remaining")
        capture(app, "EN-preview-sample")

        chooseScenario(app, "Unknown readings")
        assertSession(app, value: "Remaining unknown")
        XCTAssertTrue(app.staticTexts["Plan unknown"].firstMatch.exists)
        capture(app, "EN-preview-unknown")
        chooseScenario(app, "Exhausted readings")
        assertSession(app, value: "0% remaining")
        capture(app, "EN-preview-exhausted")
        chooseScenario(app, "Stale readings")
        XCTAssertTrue(app.staticTexts["Stale · over 15 minutes old"].firstMatch.exists)
        assertSession(app, value: "72% remaining")
        capture(app, "EN-preview-stale")

        app.buttons["preview-settings"].tap()
        app.buttons["interface-language"].tap()
        app.buttons["한국어"].tap()
        XCTAssertTrue(app.buttons["초기 설정 다시 보기"].exists)
        assertNavigationUnobscured(app, button: app.buttons["완료"], noticeID: "preview-notice-settings")
        capture(app, "KO-preview-settings")
        app.buttons["완료"].tap()
        XCTAssertTrue(app.staticTexts["요금제: Max"].waitForExistence(timeout: 5))
        chooseScenario(app, "기본 샘플")
        XCTAssertEqual(app.staticTexts["preview-notice-dashboard"].label, "UI 프리뷰 · 샘플 데이터 전용")
        capture(app, "KO-preview-sample")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["요금제: Max"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["setup-heading"].exists)
        XCTAssertEqual(app.staticTexts["preview-notice-dashboard"].label, "UI 프리뷰 · 샘플 데이터 전용")
    }

    private func chooseEnglish(_ app: XCUIApplication) {
        app.buttons["interface-language"].tap()
        app.buttons["English"].tap()
    }

    private func chooseScenario(_ app: XCUIApplication, _ name: String) {
        app.buttons["preview-scenario"].tap()
        app.buttons[name].tap()
    }

    private func assertSetupHeading(_ app: XCUIApplication, title: String) {
        let heading = app.staticTexts["setup-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 10))
        XCTAssertTrue(heading.isHittable)
        XCTAssertEqual(heading.label, title)
    }

    private func assertSession(_ app: XCUIApplication, value: String) {
        let reading = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@ AND value BEGINSWITH %@", "Session", value)
        ).firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 5), "Expected independent Session reading: \(value)")
    }

    private func assertNavigationUnobscured(_ app: XCUIApplication, button: XCUIElement, noticeID: String) {
        let notice = app.staticTexts[noticeID]
        XCTAssertTrue(notice.exists)
        // Locale changes can finish rendering before the menu's hit-test transition settles.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed,
                       "Preview notice must become reachable after the transition")
        XCTAssertTrue(notice.isHittable)
        XCTAssertTrue(button.isHittable)
        XCTAssertFalse(button.frame.intersects(notice.frame), "Preview notice must not cover navigation controls")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
