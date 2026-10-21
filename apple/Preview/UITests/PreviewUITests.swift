import XCTest

// Only the isolated QD Preview app, never production or its persistence harness.
// Device runs require a fresh preview installation authorized for UI testing.
final class PreviewUITests: XCTestCase {
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
                    for _ in 0..<8 {
                        if reading.exists && reading.isHittable { break }
                        app.swipeUp()
                    }
                    XCTAssertTrue(reading.isHittable, "\(variant): expected independent \(label): \(value)")
                }
                let timestamp = app.staticTexts["2026-10-21T05:00:00.123999Z"]
                for _ in 0..<8 {
                    if timestamp.exists && timestamp.isHittable { break }
                    app.swipeUp()
                }
                XCTAssertTrue(timestamp.isHittable, "Original source timestamp remains reachable")
                XCTAssertFalse(app.buttons["Connect with Apple"].exists)
                XCTAssertFalse(app.buttons["Apple로 연결"].exists)
                capture(app, variant + "-readings")
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = variant + "-AX"; hierarchy.lifetime = .keepAlways; add(hierarchy)
                app.terminate()
            }
        }
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
