import XCTest
@testable import QuotaDock

final class SnapshotBoundaryTests: XCTestCase {
    private func fixture() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
        {"schemaVersion":1,"generatedAt":"2026-10-13T10:00:00.123Z","demo":false,"providers":[
          {"id":"gemini","name":"Gemini","plan":"Google AI Pro","state":"available","source":"codexbar","message":null,"observedAt":"2026-10-13T09:59:00.456Z","windows":[
            {"id":"primary","label":"Pro tier","remainingPercent":null,"resetsAt":null},
            {"id":"secondary","label":"Flash Lite tier","remainingPercent":0,"resetsAt":"2026-10-14T10:00:00.789Z"}]},
          {"id":"codex","name":"private name","plan":null,"state":"error","source":"codexbar","message":"private diagnostic","observedAt":null,"windows":[
            {"id":"primary","label":"Session","remainingPercent":93,"resetsAt":null}]}]}
        """.utf8)) as? [String: Any])
    }

    private func decode(_ root: [String: Any]) throws -> Snapshot {
        try Snapshot.decode(JSONSerialization.data(withJSONObject: root))
    }

    func testUnknownZeroAndErrorRemainAsymmetricAcrossSanitizedRoundTrip() throws {
        let raw = try decode(fixture())
        let safe = raw.sanitized
        XCTAssertEqual(safe.generatedAt, raw.generatedAt)
        XCTAssertEqual(safe.providers[0].observedAt, raw.providers[0].observedAt)
        XCTAssertEqual(safe.providers[0].windows.map(\.label), ["Pro tier", "Flash Lite tier"])
        XCTAssertNil(safe.providers[0].windows[0].remainingPercent)
        XCTAssertEqual(safe.providers[0].windows[1].remainingPercent, 0)
        XCTAssertNil(safe.providers[0].windows[0].remainingPercentText)
        XCTAssertEqual(safe.providers[0].windows[1].remainingPercentText, "0%")
        XCTAssertEqual(QuotaWindow(id: "primary", label: "Session", remainingPercent: 0.75, resetsAt: nil).remainingPercentText, "0.75%")
        XCTAssertEqual(QuotaWindow(id: "primary", label: "Session", remainingPercent: 0.001, resetsAt: nil).remainingPercentText, "<0.01%")
        XCTAssertEqual(safe.providers[0].windows[1].resetsAt, raw.providers[0].windows[1].resetsAt)
        XCTAssertNil(safe.providers[1].windows[0].remainingPercent)
        XCTAssertNil(safe.providers[1].observedAt)
        let data = try safe.encoded()
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private"))
        XCTAssertEqual(try Snapshot.decode(data), safe)
        let preview = try Snapshot.decode(Snapshot.preview.encoded())
        XCTAssertEqual(preview.providers[1].windows[0].id, "weekly")
        XCTAssertEqual(preview.providers[2].windows[0].id, "pro")
        XCTAssertEqual(try Snapshot.decode(preview.encoded()), preview)
    }

    func testDecodeRejectsDuplicateUnboundedAndMalformedStructures() throws {
        let root = try fixture()
        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        var mutations: [[String: Any]] = []
        for count in [2, 5] {
            var changed = root
            changed["providers"] = Array(repeating: providers[0], count: count)
            mutations.append(changed)
        }
        let windows = try XCTUnwrap(providers[0]["windows"] as? [[String: Any]])
        for count in [2, 4] {
            var changed = root
            var provider = providers[0]
            provider["windows"] = Array(repeating: windows[0], count: count)
            changed["providers"] = [provider]
            mutations.append(changed)
        }
        for (key, value) in [("plan", "private identity"), ("name", String(repeating: "x", count: 65)), ("message", String(repeating: "x", count: 1025))] {
            var changed = root
            var provider = providers[0]
            provider[key] = value
            changed["providers"] = [provider]
            mutations.append(changed)
        }
        for (key, value) in [("id", "private-id" as Any), ("label", "private diagnostic" as Any), ("remainingPercent", -1 as Any), ("remainingPercent", 101 as Any), ("remainingPercent", true as Any), ("resetsAt", "bad-date" as Any)] {
            var changed = root
            var provider = providers[0]
            var window = windows[0]
            window[key] = value
            provider["windows"] = [window]
            changed["providers"] = [provider]
            mutations.append(changed)
        }
        var missing = root
        var provider = providers[0]
        provider.removeValue(forKey: "observedAt")
        missing["providers"] = [provider]
        mutations.append(missing)
        for mutation in mutations { XCTAssertThrowsError(try decode(mutation)) }
        XCTAssertThrowsError(try Snapshot.decode(Data(repeating: 32, count: 256 * 1024 + 1)))
    }

    func testSanitizationWhitelistsTextEvenForDirectlyConstructedModels() throws {
        let provider = Provider(id: .gemini, name: "secret-name", plan: "secret-plan", state: .available,
                                source: .codexbar, message: "secret-message", observedAt: nil,
                                windows: [QuotaWindow(id: "primary", label: "secret-label", remainingPercent: 0, resetsAt: nil)])
        let safe = Snapshot(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 1), demo: false, providers: [provider]).sanitized
        XCTAssertEqual(safe.providers[0].name, "Gemini")
        XCTAssertNil(safe.providers[0].plan)
        XCTAssertEqual(safe.providers[0].windows[0].label, "Additional")
        XCTAssertFalse(String(decoding: try safe.encoded(), as: UTF8.self).contains("secret"))
        XCTAssertEqual(try Snapshot.decode(safe.encoded()), safe)
    }
}
