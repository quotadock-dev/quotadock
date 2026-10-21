import XCTest
@testable import QuotaDock

final class LocalizationPresentationTests: XCTestCase {
    func testExplicitLanguageLookupDoesNotFollowDeviceLanguage() {
        XCTAssertEqual(DockL10n.text("Allowmark", language: "en"), "Allowmark")
        XCTAssertEqual(DockL10n.text("Allowmark", language: "ko"), "얼로마크")
        XCTAssertEqual(DockL10n.text("QuotaDock · remaining", language: "en"), "Allowmark · remaining")
        XCTAssertEqual(DockL10n.text("QuotaDock · remaining", language: "ko"), "얼로마크 · 잔여량")
        XCTAssertEqual(DockL10n.text("Remaining unknown", language: "en"), "Remaining unknown")
        XCTAssertEqual(DockL10n.text("Remaining unknown", language: "ko"), "잔여량 알 수 없음")
        XCTAssertEqual(DockL10n.text("Restore purchases", language: "en"), "Restore purchases")
        XCTAssertEqual(DockL10n.text("Restore purchases", language: "ko"), "구매 복원")
    }

    func testNativeTablesHaveMatchingKeysAndSafeFormatArguments() throws {
        func table(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let url = URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")
            let data = try Data(contentsOf: url)
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try table("en")
        let korean = try table("ko")
        XCTAssertEqual(Set(english.keys), Set(korean.keys))
        let tokens = try NSRegularExpression(pattern: "%[@d]")
        func placeholders(_ value: String) -> [String] {
            tokens.matches(in: value, range: NSRange(value.startIndex..., in: value)).map {
                (value as NSString).substring(with: $0.range)
            }
        }
        for key in english.keys {
            let translated = try XCTUnwrap(korean[key])
            XCTAssertFalse(translated.isEmpty, key)
            // Plain text may legitimately contain percent signs. Only formatting
            // keys are interpreted by String(format:).
            guard !placeholders(key).isEmpty else { continue }
            XCTAssertEqual(placeholders(key), placeholders(try XCTUnwrap(english[key])), key)
            XCTAssertEqual(placeholders(key), placeholders(translated), key)
            for value in [key, try XCTUnwrap(english[key]), translated] {
                XCTAssertFalse(value.replacingOccurrences(of: "%[@d]", with: "", options: .regularExpression).contains("%"), key)
            }
        }
        // Percent signs and arbitrary provider text are arguments, never format strings.
        let format = DockL10n.text("%@ remaining", language: "ko")
        XCTAssertEqual(String(format: format, "<0.01%"), "<0.01% 남음")
    }

    func testSetupTablesHaveMatchingKeysAndFormatArguments() throws {
        func table(_ language: String) throws -> [String: String] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Setup.strings"))
            return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        }
        let english = try table("en")
        let korean = try table("ko")
        XCTAssertFalse(english.isEmpty)
        XCTAssertEqual(Set(english.keys), Set(korean.keys))
        for key in english.keys {
            XCTAssertFalse(try XCTUnwrap(english[key]).isEmpty, key)
            XCTAssertFalse(try XCTUnwrap(korean[key]).isEmpty, key)
        }
        // This is the current setupFormat contract; other Setup values are text,
        // not printf templates, and may contain literal percent signs.
        let key = "Step %@ of 3"
        for table in [english, korean] {
            let value = try XCTUnwrap(table[key])
            let tokens = try NSRegularExpression(pattern: "%@")
            XCTAssertEqual(tokens.numberOfMatches(in: value, range: NSRange(value.startIndex..., in: value)), 1)
            XCTAssertFalse(value.replacingOccurrences(of: "%@", with: "").contains("%"))
        }
        XCTAssertEqual(String(format: try XCTUnwrap(english[key]), "2"), "Step 2 of 3")
        XCTAssertEqual(String(format: try XCTUnwrap(korean[key]), "2"), "3단계 중 2단계")
    }

    func testSetupExplicitEnglishAndKoreanLookup() {
        let examples = [
            ("Welcome", "환영합니다"),
            ("Finish setup", "설정 완료"),
            ("Settings", "설정"),
            ("Pairing token", "연결 토큰"),
            ("Unknown is not zero.", "알 수 없음은 0이 아닙니다."),
            ("Bridge pairing rejected. Pair again; original observations retained.",
             "브리지 연결이 거부되었습니다. 다시 연결하세요. 기존 측정값은 유지됩니다.")
        ]
        for (key, korean) in examples {
            XCTAssertEqual(DockL10n.text(key, table: "Setup", language: "en"), key)
            XCTAssertEqual(DockL10n.text(key, table: "Setup", language: "ko"), korean)
        }
        XCTAssertEqual(DockL10n.text("Step %@ of 3", table: "Setup", language: "ko"), "3단계 중 %@단계")
    }

    func testUnknownProviderWindowDoesNotLeakProviderDiagnostics() {
        let unknown = QuotaWindow(id: "upstream", label: "private provider diagnostic", remainingPercent: nil, resetsAt: nil)
        XCTAssertEqual(QuotaPresentation.window(unknown), DockL10n.text("Quota window"))
        XCTAssertNil(QuotaPresentation.percent(unknown))
        let tiny = QuotaWindow(id: "session", label: "Session", remainingPercent: 0.001, resetsAt: nil)
        XCTAssertEqual(QuotaPresentation.percent(tiny), "<0.01%")
        XCTAssertEqual(tiny.label, "Session") // Presentation must not rewrite serialized model fields.
    }
}
