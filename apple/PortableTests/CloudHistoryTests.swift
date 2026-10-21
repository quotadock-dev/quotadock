import Foundation
import XCTest
#if canImport(QuotaDockStorage)
@testable import QuotaDockStorage
#else
@testable import QuotaDock
#endif

final class CloudHistoryTests: XCTestCase {
    private let accountID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    // Synthetic fixtures only; these do not represent a provider or authenticated account.
    private let newer = "2023-11-15T00:13:20.125987+02:00"
    private let older = "2023-11-14T17:13:19.987654-05:00"
    private let cursor = "2023-11-14T22:13:19.987Z"

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func window(_ id: String, _ value: Any, _ reset: Any = NSNull()) -> [String: Any] {
        ["id": id, "label": id == "primary" ? "Session" : "Weekly",
         "remainingPercent": value, "resetsAt": reset]
    }

    private func observation(_ timestamp: String) -> [String: Any] {
        ["plan": NSNull(), "state": "available", "source": "codexbar", "observedAt": timestamp,
         "windows": [window("primary", 0, "2023-11-14T21:13:20.001999Z"),
                     window("secondary", NSNull())]]
    }

    private func fixture() -> [String: Any] {
        ["accountId": accountID.uuidString, "provider": "claude", "enabled": true,
         "retentionDays": 7, "maximumSamplesPerAccount": 1000,
         "observations": [observation(newer), observation(older)], "nextCursor": cursor]
    }

    private func decode(_ object: [String: Any], before: String? = nil) throws -> CloudHistoryPage {
        try CloudHistoryPage.decode(data(object), accountID: accountID, provider: .claude, before: before)
    }

    func testSettingsRequireExactMetadataAndFixedPolicy() throws {
        let valid: [String: Any] = ["enabled": true, "retentionDays": 7, "maximumSamplesPerAccount": 1000]
        let settings = try CloudHistorySettings.decode(data(valid))
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.retentionDays, 7)
        XCTAssertEqual(settings.maximumSamplesPerAccount, 1000)
        var disabled = valid
        disabled["enabled"] = false
        XCTAssertFalse(try CloudHistorySettings.decode(data(disabled)).enabled)
        for key in valid.keys {
            var missing = valid
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try CloudHistorySettings.decode(data(missing)), key)
        }
        for (key, value) in [("enabled", 1 as Any), ("enabled", "true" as Any),
                             ("retentionDays", true as Any), ("retentionDays", 8 as Any),
                             ("retentionDays", 7.5 as Any), ("maximumSamplesPerAccount", 999 as Any),
                             ("maximumSamplesPerAccount", "1000" as Any), ("extra", NSNull() as Any)] {
            var invalid = valid
            invalid[key] = value
            XCTAssertThrowsError(try CloudHistorySettings.decode(data(invalid)), key)
        }
    }

    func testPagePreservesRawTimesZeroUnknownAndIndependentWindows() throws {
        let page = try decode(fixture(), before: "2023-11-14T22:13:20.126Z")
        XCTAssertEqual(page.accountId, accountID)
        XCTAssertEqual(page.provider, .claude)
        XCTAssertTrue(page.settings.enabled)
        XCTAssertEqual(page.settings.retentionDays, 7)
        XCTAssertEqual(page.settings.maximumSamplesPerAccount, 1000)
        XCTAssertEqual(page.nextCursor, cursor)
        XCTAssertEqual(page.observations.map(\.observedAt), [newer, older])
        // Fixed Unix epochs, independent of Snapshot's parser/formatter.
        for (point, epoch) in zip(page.observations, [1_700_000_000.125, 1_699_999_999.987]) {
            XCTAssertEqual(point.observedDate.timeIntervalSince1970, epoch, accuracy: 0.00001)
            XCTAssertEqual(point.reading.observedAt?.timeIntervalSince1970 ?? 0, epoch, accuracy: 0.00001)
            XCTAssertNil(point.reading.plan)
            XCTAssertEqual(point.reading.state, .available)
            XCTAssertEqual(point.reading.source, .codexbar)
            XCTAssertEqual(point.reading.windows.map(\.id), ["primary", "secondary"])
            XCTAssertEqual(point.reading.windows[0].remainingPercent, 0)
            XCTAssertEqual(point.reading.windows[0].resetsAt?.timeIntervalSince1970 ?? 0,
                           1_699_996_400.001, accuracy: 0.00001)
            XCTAssertNil(point.reading.windows[1].remainingPercent)
            XCTAssertNil(point.reading.windows[1].resetsAt)
        }
        var terminal = fixture()
        terminal["nextCursor"] = NSNull()
        XCTAssertNil(try decode(terminal).nextCursor)
        terminal["enabled"] = false
        terminal["observations"] = []
        XCTAssertTrue(try decode(terminal).observations.isEmpty)
        var planned = observation(newer)
        planned["plan"] = "Pro"
        planned["windows"] = [window("tertiary", 42)]
        terminal["enabled"] = true
        terminal["observations"] = [planned]
        let reading = try XCTUnwrap(decode(terminal).observations.first).reading
        XCTAssertEqual(reading.plan, "Pro")
        XCTAssertEqual(reading.windows.map(\.id), ["tertiary"])
    }

    func testRejectsMalformedScopePaginationAndObservationContracts() throws {
        for key in fixture().keys {
            var invalid = fixture()
            invalid.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(invalid), "missing \(key)")
        }
        for (key, value) in [("accountId", UUID().uuidString as Any), ("provider", "codex" as Any),
                             ("enabled", false as Any), ("retentionDays", 30 as Any),
                             ("maximumSamplesPerAccount", 1001 as Any), ("extra", true as Any),
                             ("nextCursor", "2023-11-14T22:13:19.987000Z" as Any),
                             ("nextCursor", "2023-11-14T17:13:19.987-05:00" as Any),
                             ("nextCursor", "2023-02-30T22:13:19.987Z" as Any),
                             ("nextCursor", "2023-11-14T22:13:20.125Z" as Any),
                             ("observations", [] as Any),
                             ("observations", [observation(older), observation(newer)] as Any),
                             ("observations", [observation(newer), observation("2023-11-14T22:13:20.125001Z")] as Any)] {
            var invalid = fixture()
            invalid[key] = value
            XCTAssertThrowsError(try decode(invalid), key)
        }
        for before in ["2023-11-14T22:13:20.125Z", cursor, newer,
                       "2023-11-14T22:13:21Z", "2023-02-30T22:13:21.000Z"] {
            XCTAssertThrowsError(try decode(fixture(), before: before), before)
        }
        for key in observation(newer).keys {
            var point = observation(newer)
            point.removeValue(forKey: key)
            var invalid = fixture()
            invalid["observations"] = [point]
            invalid["nextCursor"] = NSNull()
            XCTAssertThrowsError(try decode(invalid), "missing observation \(key)")
        }
        for (key, value) in [("state", "error" as Any), ("source", "demo" as Any),
                             ("plan", "unrecognized" as Any), ("extra", true as Any),
                             ("observedAt", NSNull() as Any),
                             ("windows", [window("primary", NSNull())] as Any),
                             ("windows", [window("weekly", 20)] as Any),
                             ("windows", [window("primary", 101)] as Any),
                             ("windows", [window("primary", 20), window("primary", 30)] as Any),
                             ("windows", [["id": "primary", "label": "Session", "remainingPercent": 0]] as Any),
                             ("windows", [["id": "primary", "label": "Session", "remainingPercent": 0,
                                           "resetsAt": NSNull(), "extra": true]] as Any)] {
            var point = observation(newer)
            point[key] = value
            var invalid = fixture()
            invalid["observations"] = [point]
            invalid["nextCursor"] = NSNull()
            XCTAssertThrowsError(try decode(invalid), key)
        }
        // Both sides of the size boundary have distinct, descending dates.
        var bounded = fixture()
        let rows = (0..<251).map { observation("2023-11-14T22:13:20." + String(format: "%03d", 999 - $0) + "Z") }
        bounded["observations"] = Array(rows.prefix(250))
        bounded["nextCursor"] = NSNull()
        XCTAssertEqual(try decode(bounded).observations.count, 250)
        bounded["observations"] = rows
        XCTAssertThrowsError(try decode(bounded))
    }
}
