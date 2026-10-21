import XCTest

final class OnboardingUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testFirstRunEnglishToKorean() {
        exerciseFirstRun(startKorean: false)
    }

    func testFirstRunKoreanToEnglish() {
        exerciseFirstRun(startKorean: true)
    }

    func testPreferencesLastParagraphScrollsClearOfFooter() {
        for korean in [false, true] {
            app.launchArguments = ["--demo", "--reset-setup-test",
                                   korean ? "--language-ko-preview" : "--language-en-preview"]
            app.launch()
            tap(app.buttons["setup-continue"])
            tap(app.buttons["setup-route-demo"])
            tap(app.buttons["setup-continue"])
            let last = app.staticTexts[korean ?
                "내 계정이 아닌 DEMO 데이터를 엽니다. 데모는 저장된 측정값을 덮어쓰지 않습니다." :
                "You will open DEMO data, not your account. Demo never overwrites your saved observations."]
            let footer = app.buttons["setup-continue"]
            for _ in 0..<8 {
                if last.exists && last.isHittable && last.frame.maxY <= footer.frame.minY { break }
                app.swipeUp()
            }
            XCTAssertTrue(last.isHittable)
            XCTAssertLessThanOrEqual(last.frame.maxY, footer.frame.minY,
                                     "The final paragraph must scroll fully above the fixed footer")
            XCTAssertTrue(footer.isHittable)
            print("ONBOARDING FOOTER \(korean ? "ko" : "en") paragraph=\(last.frame) footer=\(footer.frame)")
            capture(korean ? "KO-preferences-scrolled-bottom" : "EN-preferences-scrolled-bottom")
            app.terminate()
        }
    }

    func testSetupOpensPairingAndSeparateUnacceptedCloudConsent() {
        app.launchArguments = ["--demo", "--reset-setup-test", "--language-en-preview"]
        app.launch()
        tap(app.buttons["setup-continue"])
        tap(app.buttons["setup-route-bridge"])
        tap(app.buttons["setup-continue"])
        let refresh = app.switches["setup-foreground-refresh"]
        reveal(refresh)
        tapSwitch(refresh)
        XCTAssertEqual(refresh.value as? String, "0")
        tap(app.buttons["setup-continue"])
        XCTAssertTrue(app.navigationBars["Pair bridge"].waitForExistence(timeout: 5))
        let token = app.secureTextFields["Pairing token"]
        XCTAssertTrue(token.exists)
        capture("EN-setup-bridge")
        tap(app.buttons["Cancel"])
        openSettings(korean: false)
        tap(app.buttons["Review setup"])
        tap(app.buttons["setup-continue"])
        tap(app.buttons["setup-route-cloud"])
        tap(app.buttons["setup-continue"])
        reveal(refresh)
        XCTAssertEqual(refresh.value as? String, "0")
        tap(app.buttons["setup-continue"])
        XCTAssertTrue(app.navigationBars["Optional cloud"].waitForExistence(timeout: 5))
        let storage = app.switches["Store sanitized quota and account metadata"]
        let collector = app.switches["Allow local collector quota processing"]
        reveal(storage)
        XCTAssertEqual(storage.value as? String, "0", "Choosing cloud in setup is not storage consent")
        reveal(collector)
        XCTAssertEqual(collector.value as? String, "0", "Choosing cloud in setup is not collector consent")
        let connect = app.buttons["Connect with Apple"]
        reveal(connect)
        XCTAssertFalse(connect.isEnabled)
        tapSwitch(storage)
        XCTAssertEqual(storage.value as? String, "1")
        XCTAssertEqual(collector.value as? String, "0")
        XCTAssertFalse(connect.isEnabled, "One consent cannot authorize Apple sign-in")
        tapSwitch(collector)
        XCTAssertEqual(collector.value as? String, "1")
        XCTAssertTrue(connect.isEnabled, "Both explicit consents must enable the sign-in action")
        tapSwitch(storage)
        XCTAssertEqual(storage.value as? String, "0")
        XCTAssertEqual(collector.value as? String, "1")
        XCTAssertFalse(connect.isEnabled, "Withdrawing either consent must disable sign-in")
        tapSwitch(collector)
        XCTAssertEqual(collector.value as? String, "0")
        capture("EN-setup-cloud-consent")
    }

    private func exerciseFirstRun(startKorean: Bool) {
        app.launchArguments = ["--demo", "--reset-setup-test",
                               startKorean ? "--language-ko-preview" : "--language-en-preview"]
        app.launch()
        heading(startKorean ? "다음 프롬프트 전에, 사용량을 한눈에." : "A little clarity before your next prompt.")
        capture(startKorean ? "KO-welcome" : "EN-welcome")
        app.swipeUp() // Continue is fixed; the next step must still begin at its heading.
        tap(app.buttons["setup-continue"])
        heading(startKorean ? "시작 방법을 선택하세요." : "Choose how to get started.")
        XCTAssertFalse(app.buttons["setup-continue"].isEnabled, "A connection choice is required")
        capture(startKorean ? "KO-connection" : "EN-connection")
        tap(app.buttons["setup-route-demo"])
        XCTAssertTrue(app.buttons["setup-continue"].isEnabled)
        tap(app.buttons["setup-continue"])
        heading(startKorean ? "원하는 방식으로 설정하세요." : "Make it work your way.")
        let toggle = app.switches["setup-foreground-refresh"]
        reveal(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        tapSwitch(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        capture(startKorean ? "KO-preferences" : "EN-preferences")

        // Language is changed through the public menu, not by relaunching or a preview step.
        tap(app.buttons[startKorean ? "뒤로" : "Back"])
        tap(app.buttons[startKorean ? "뒤로" : "Back"])
        tap(app.buttons["interface-language"])
        tap(app.buttons[startKorean ? "English" : "한국어"])
        let korean = !startKorean
        heading(korean ? "다음 프롬프트 전에, 사용량을 한눈에." : "A little clarity before your next prompt.")
        capture(korean ? "KO-welcome-switched" : "EN-welcome-switched")
        tap(app.buttons["setup-continue"])
        heading(korean ? "시작 방법을 선택하세요." : "Choose how to get started.")
        XCTAssertTrue(app.buttons["setup-route-demo"].isSelected, "Switching language must retain the route")
        capture(korean ? "KO-connection-switched" : "EN-connection-switched")
        tap(app.buttons["setup-continue"])
        heading(korean ? "원하는 방식으로 설정하세요." : "Make it work your way.")
        reveal(toggle)
        XCTAssertEqual(toggle.value as? String, "0", "Switching language must retain the draft preference")
        capture(korean ? "KO-preferences-switched" : "EN-preferences-switched")
        tap(app.buttons["setup-continue"])
        let demo = app.staticTexts[korean ? "DEMO · 내 계정이 아닌 샘플 데이터" : "DEMO · sample data, not your account"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["setup-heading"].exists)
        capture(korean ? "KO-dashboard" : "EN-dashboard")

        openSettings(korean: korean)
        assertSavedRefresh(korean: korean, value: "0")
        tap(app.buttons[korean ? "초기 설정 다시 보기" : "Review setup"])
        heading(korean ? "다음 프롬프트 전에, 사용량을 한눈에." : "A little clarity before your next prompt.")
        tap(app.buttons["setup-continue"])
        tap(app.buttons["setup-route-later"])
        tap(app.buttons["setup-continue"])
        reveal(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        tapSwitch(toggle) // Cancel must discard this change, not save it.
        XCTAssertEqual(toggle.value as? String, "1")
        tap(app.buttons[korean ? "취소" : "Cancel"])
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        openSettings(korean: korean)
        assertSavedRefresh(korean: korean, value: "0")

        // Existing provider views must redraw too, without replacing their data.
        tap(app.buttons["interface-language"])
        tap(app.buttons[startKorean ? "한국어" : "English"])
        assertSavedRefresh(korean: startKorean, value: "0")
        tap(app.buttons[startKorean ? "완료" : "Done"])
        let translatedPlan = app.staticTexts[startKorean ? "요금제: Max" : "Plan: Max"]
        XCTAssertTrue(translatedPlan.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[startKorean ? "Plan: Max" : "요금제: Max"].exists)
        capture(startKorean ? "KO-dashboard-switched" : "EN-dashboard-switched")

        app.terminate()
        // Crucially omit --demo too: it otherwise bypasses setup even if completion was lost.
        // Foreground refresh was disabled, so this launch does not request a network refresh.
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.navigationBars[startKorean ? "얼로마크" : "Allowmark"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["setup-heading"].exists, "Completion must survive Cancel and relaunch")
        openSettings(korean: startKorean)
        assertSavedRefresh(korean: startKorean, value: "0")
    }

    private func openSettings(korean: Bool) {
        tap(app.buttons[korean ? "설정" : "Settings"])
        XCTAssertTrue(app.buttons[korean ? "초기 설정 다시 보기" : "Review setup"].waitForExistence(timeout: 5))
    }

    private func assertSavedRefresh(korean: Bool, value: String) {
        let toggle = app.switches[korean ? "앱을 열 때 새로고침" : "Refresh when I open the app"]
        reveal(toggle)
        XCTAssertEqual(toggle.value as? String, value)
    }

    private func heading(_ title: String) {
        let element = app.staticTexts["setup-heading"]
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        XCTAssertEqual(element.label, title)
        XCTAssertTrue(element.isHittable, "A new step must begin at its visible heading")
    }

    private func reveal(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let footer = app.buttons["setup-continue"]
        func visible() -> Bool {
            guard element.isHittable else { return false }
            // A partially visible route can be hittable even while its tap point
            // lies beneath the fixed Continue button. Reveal the complete row.
            if element.identifier.hasPrefix("setup-route-"), footer.exists {
                return element.frame.maxY <= footer.frame.minY
            }
            return true
        }
        for _ in 0..<8 {
            if visible() { return }
            app.swipeUp()
        }
        XCTAssertTrue(visible(), "Element must be reachable without footer overlap: \(element)")
    }

    private func tap(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    private func tapSwitch(_ element: XCUIElement) {
        reveal(element)
        // Form toggles wrap a native switch in a full-width accessibility row.
        // On iOS 27 a synthesized instantaneous tap can leave it unchanged;
        // deliberately press the current thumb, not the label or track center.
        let nested = element.switches.firstMatch
        let control = nested.exists ? nested : element
        reveal(control)
        let thumbX = control.value as? String == "1" ? 0.8 : 0.2
        control.coordinate(withNormalizedOffset: CGVector(dx: thumbX, dy: 0.5)).press(forDuration: 0.3)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
