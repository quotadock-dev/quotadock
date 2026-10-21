import XCTest

final class HistoryUITests: XCTestCase {
    func testSignedOutHistoryExplainsConsentWithoutEnablingOperations() {
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        for korean in [false, true] {
            app.launchArguments = ["--demo", "--cloud-preview", korean ? "--language-ko-preview" : "--language-en-preview"]
            app.launch()
            let title = korean ? "할당량 이력" : "Quota history"
            let link = app.buttons[title]
            for _ in 0..<8 {
                if link.exists && link.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(link.isHittable)
            link.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
            let signedOut = app.staticTexts[korean
                ? "로그인하고 목록의 계정을 선택하면 해당 이력을 조회할 수 있습니다. 연결되지 않은 동안 저장된 이력을 표시하지 않습니다."
                : "Sign in and select a listed account to read its history. No saved history is shown here while disconnected."]
            for _ in 0..<8 {
                if signedOut.exists && signedOut.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(signedOut.isHittable)
            XCTAssertFalse(app.buttons[korean ? "이력 저장 활성화" : "Enable history storage"].exists)
            XCTAssertFalse(app.buttons[korean ? "이력 저장 상태 조회" : "Read history status"].exists)
            XCTAssertFalse(app.buttons[korean ? "최근 이력 조회" : "Read latest history"].exists)
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = korean ? "KO-history-signed-out" : "EN-history-signed-out"
            image.lifetime = .keepAlways
            add(image)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = korean ? "KO-history-signed-out-AX" : "EN-history-signed-out-AX"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            app.terminate()
        }
    }
}
