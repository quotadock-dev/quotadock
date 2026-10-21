import XCTest
@testable import QuotaDock

final class SetupTests: XCTestCase {
    private func withPreferences(_ check: (UserDefaults) -> Void) {
        let name = "QuotaDock.SetupTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: name)!
        defer { preferences.removePersistentDomain(forName: name) }
        check(preferences)
    }

    func testInterruptedSetupResumesWithoutEnablingRefreshOrCompleting() {
        withPreferences { preferences in
            preferences.set(false, forKey: RefreshSettings.foregroundKey)
            var draft = SetupStore.load(in: preferences)
            XCTAssertEqual(draft.step, .welcome)
            XCTAssertFalse(draft.foregroundAutoRefresh)
            draft.advance()
            XCTAssertFalse(draft.canContinue)
            draft.advance()
            XCTAssertEqual(draft.step, .connection)
            draft.route = .bridge
            draft.foregroundAutoRefresh = true
            draft.advance()
            XCTAssertTrue(SetupStore.save(draft, in: preferences))
            XCTAssertEqual(SetupStore.load(in: preferences), draft)
            XCTAssertFalse(SetupStore.load(in: preferences).completed)
            XCTAssertFalse(RefreshSettings.foregroundEnabled(in: preferences))
            // Navigating back keeps choices, while explicit completion applies them.
            draft.back()
            draft.back()
            XCTAssertEqual(draft.route, .bridge)
            draft.advance()
            draft.advance()
            XCTAssertTrue(SetupStore.finish(draft, in: preferences))
            XCTAssertTrue(SetupStore.load(in: preferences).completed)
            XCTAssertTrue(RefreshSettings.foregroundEnabled(in: preferences))
        }
    }

    func testEachRouteCanFinishWithManualRefreshPreference() {
        for route in SetupRoute.allCases {
            withPreferences { preferences in
                let draft = SetupProgress(step: .preferences, route: route, foregroundAutoRefresh: false)
                XCTAssertTrue(SetupStore.finish(draft, in: preferences))
                let remembered = SetupStore.load(in: preferences)
                XCTAssertTrue(remembered.completed)
                XCTAssertEqual(remembered.route, route)
                XCTAssertFalse(remembered.foregroundAutoRefresh)
                XCTAssertFalse(RefreshSettings.foregroundEnabled(in: preferences))
            }
        }
    }

    func testMalformedOrUnsupportedSetupRestartsWithoutChangingRefreshPreference() {
        let invalid = [
            "not JSON",
            "{\"version\":2,\"step\":\"preferences\",\"route\":\"demo\",\"foregroundAutoRefresh\":true,\"completed\":true}",
            "{\"version\":1,\"step\":\"future\",\"route\":\"demo\",\"foregroundAutoRefresh\":true,\"completed\":false}",
            "{\"version\":1,\"step\":\"preferences\",\"route\":\"unknown\",\"foregroundAutoRefresh\":true,\"completed\":false}",
            "{\"version\":1,\"step\":\"preferences\",\"foregroundAutoRefresh\":true,\"completed\":false}",
            "{\"version\":1,\"step\":\"welcome\",\"route\":\"demo\",\"foregroundAutoRefresh\":true,\"completed\":true}",
            String(repeating: " ", count: 2049)
        ]
        for value in invalid {
            withPreferences { preferences in
                preferences.set(false, forKey: RefreshSettings.foregroundKey)
                preferences.set(Data(value.utf8), forKey: SetupStore.key)
                let recovered = SetupStore.load(in: preferences)
                XCTAssertEqual(recovered.step, .welcome)
                XCTAssertNil(recovered.route)
                XCTAssertFalse(recovered.completed)
                XCTAssertFalse(recovered.foregroundAutoRefresh)
                XCTAssertFalse(RefreshSettings.foregroundEnabled(in: preferences))
            }
        }
    }

    func testCannotFinishWithoutConnectionChoiceOrAtAnEarlierStep() {
        withPreferences { preferences in
            XCTAssertFalse(SetupStore.finish(SetupProgress(route: .cloud), in: preferences))
            XCTAssertFalse(SetupStore.finish(SetupProgress(step: .preferences), in: preferences))
            XCTAssertFalse(SetupStore.load(in: preferences).completed)
            XCTAssertTrue(RefreshSettings.foregroundEnabled(in: preferences))
        }
    }

    func testLanguagePreferenceIsAllowlistedAndResolvesSupportedDeviceLanguages() {
        withPreferences { preferences in
            XCTAssertEqual(DockL10n.selection(in: preferences), .system)
            preferences.set("../../private", forKey: DockL10n.languageKey)
            XCTAssertEqual(DockL10n.selection(in: preferences), .system)
            DockL10n.save(.ko, in: preferences)
            XCTAssertEqual(DockL10n.selection(in: preferences), .ko)
            XCTAssertEqual(DockL10n.resolved(.ko, preferred: ["en-US"]), "ko")
            XCTAssertEqual(DockL10n.resolved(.en, preferred: ["ko-KR"]), "en")
            XCTAssertEqual(DockL10n.resolved(.system, preferred: ["ko_KR"]), "ko")
            XCTAssertEqual(DockL10n.resolved(.system, preferred: ["fr-FR", "ko-KR"]), "ko")
            XCTAssertEqual(DockL10n.resolved(.system, preferred: ["fr-FR"]), "en")
            XCTAssertEqual(DockL10n.resolved(.system, preferred: []), "en")
        }
    }
}
