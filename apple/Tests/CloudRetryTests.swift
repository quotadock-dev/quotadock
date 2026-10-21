import XCTest
import Security
@testable import QuotaDock

final class CloudRetryTests: XCTestCase {
    func testRetryRetainsExactSerializedIntentAndHasTwoSendLimit() throws {
        let ids = [UUID(), UUID()]
        var intent = try CloudRefreshIntent(revision: 7, ids: ids, mode: .force)
        let original = intent.body
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(root["idempotencyKey"] as? String)))
        XCTAssertEqual(root["accountIds"] as? [String], ids.map(\.uuidString))
        XCTAssertEqual(root["mode"] as? String, "force")
        XCTAssertGreaterThan(try intent.beginAttempt(), 0)
        XCTAssertGreaterThan(try intent.beginAttempt(), 0)
        XCTAssertEqual(intent.body, original)
        XCTAssertThrowsError(try intent.beginAttempt())
        XCTAssertEqual(intent.attempts, 2)
        XCTAssertEqual(intent.revision, 7)
        try intent.continueOperation()
        XCTAssertGreaterThan(try intent.beginAttempt(), 0)
        XCTAssertEqual(intent.body, original)
        XCTAssertEqual(root["idempotencyKey"] as? String, intent.idempotencyKey.uuidString)
    }

    func testRestartRestoresExactCommandOnlyForOriginalUnexpiredSession() throws {
        let expiry = Date().addingTimeInterval(3600)
        let session = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: expiry)
        let slot = UUID(), key = UUID()
        // Preserve byte order and whitespace, not just equivalent JSON values.
        let body = Data("{ \"mode\":\"force\", \"idempotencyKey\":\"\(key.uuidString.lowercased())\", \"accountIds\":[\"\(slot.uuidString.lowercased())\"] }".utf8)
        var intent = try CloudRefreshIntent(revision: 7, body: body)
        _ = try intent.beginAttempt()
        let stored = try CloudRefreshIntentStore.encode(intent, session: session)
        let savedSession = try JSONDecoder().decode(CloudSession.self, from: JSONEncoder().encode(session))
        let restored = try XCTUnwrap(CloudRefreshIntentStore.decode(stored, session: savedSession, revision: 2))
        XCTAssertEqual(restored.body, body)
        XCTAssertEqual(restored.idempotencyKey, key)
        XCTAssertEqual(restored.ids, [slot])
        XCTAssertEqual(restored.mode, .force)
        XCTAssertEqual(restored.revision, 2)
        XCTAssertEqual(restored.attempts, 0)
        XCTAssertNil(restored.job)
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains(session.token))
        for other in [
            CloudSession(baseURL: session.baseURL, token: String(repeating: "b", count: 43), expiresAt: expiry),
            CloudSession(baseURL: URL(string: "https://elsewhere.invalid/api")!, token: session.token, expiresAt: expiry),
            CloudSession(baseURL: session.baseURL, token: session.token, expiresAt: expiry.addingTimeInterval(1))
        ] {
            XCTAssertNil(try CloudRefreshIntentStore.decode(stored, session: other, revision: 2))
        }
        let expired = CloudSession(baseURL: session.baseURL, token: session.token, expiresAt: .distantPast)
        XCTAssertThrowsError(try CloudRefreshIntentStore.decode(stored, session: expired, revision: 2))
        let live = try CloudRefreshIntent(revision: 7, ids: [slot], mode: .live)
        XCTAssertThrowsError(try CloudRefreshIntentStore.encode(live, session: session))
    }

    func testStoredCommandsRejectDuplicateTargetsAndMalformedRecovery() throws {
        let slot = UUID(), key = UUID()
        for ids in [[UUID](), [slot, slot], Array(repeating: slot, count: 51)] {
            XCTAssertThrowsError(try CloudRefreshIntent(revision: 0, ids: ids, mode: .force))
        }
        let valid: [String: Any] = ["accountIds": [slot.uuidString], "mode": "auto", "idempotencyKey": key.uuidString]
        let invalid: [[String: Any]] = [
            valid.merging(["accountIds": [slot.uuidString, slot.uuidString.lowercased()]]) { _, new in new },
            valid.merging(["accountIds": ["not a slot"]]) { _, new in new },
            valid.merging(["mode": "unrecognized"]) { _, new in new },
            valid.merging(["idempotencyKey": "not a key"]) { _, new in new },
            valid.merging(["token": "must not be persisted"]) { _, new in new }
        ]
        for root in invalid {
            let body = try JSONSerialization.data(withJSONObject: root)
            XCTAssertThrowsError(try CloudRefreshIntent(revision: 0, body: body))
        }
        let session = CloudSession(baseURL: URL(string: "https://example.invalid")!,
            token: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(3600))
        for data in [Data(), Data("{}".utf8), Data(repeating: 32, count: 8193)] {
            XCTAssertThrowsError(try CloudRefreshIntentStore.decode(data, session: session, revision: 0))
        }
    }

    func testTypedFailuresOnlyRetainAllowlistedCodesAndBoundDelays() {
        let privateBody = Data("{\"error\":\"private user diagnostic\"}".utf8)
        XCTAssertEqual(CloudHTTPError.classify(status: 403, data: privateBody, retryAfter: nil),
                       .rejected(status: 403, code: nil))
        XCTAssertEqual(CloudHTTPError.classify(status: 401, data: privateBody, retryAfter: nil), .unauthorized)
        XCTAssertEqual(CloudHTTPError.classify(status: 404, data: privateBody, retryAfter: nil), .notFound)
        for status in [429, 500, 502, 503, 504] {
            XCTAssertEqual(CloudHTTPError.classify(status: status, data: privateBody, retryAfter: "999999"),
                           .rejected(status: status, code: nil))
            for header in ["NaN", "-2", "private text", "61"] {
                XCTAssertEqual(CloudHTTPError.classify(status: status, data: privateBody, retryAfter: header),
                               .rejected(status: status, code: nil))
            }
            XCTAssertEqual(CloudHTTPError.classify(status: status, data: privateBody, retryAfter: "60"),
                           .transient(status: status, code: nil, retryAfter: 60))
            XCTAssertEqual(CloudHTTPError.classify(status: status, data: privateBody, retryAfter: "0"),
                           .transient(status: status, code: nil, retryAfter: 1))
        }
        XCTAssertEqual(CloudHTTPError.classify(status: 429,
            data: Data("{\"error\":\"rate_limited\"}".utf8), retryAfter: "3"),
            .transient(status: 429, code: "rate_limited", retryAfter: 3))
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let future = CloudHTTPError.classify(status: 503, data: privateBody,
            retryAfter: parser.string(from: Date().addingTimeInterval(30)))
        guard case .transient(_, _, let delay) = future else { XCTFail("Valid server wait rejected"); return }
        XCTAssertGreaterThan(delay, 25)
        XCTAssertLessThanOrEqual(delay, 30)
        XCTAssertEqual(CloudHTTPError.classify(status: 429,
            data: Data("{\"error\":\"early_budget_exhausted\"}".utf8), retryAfter: "3"),
            .rejected(status: 429, code: "early_budget_exhausted"))
        XCTAssertEqual(CloudHTTPError.classify(status: 503, data: Data(repeating: 32, count: 4097), retryAfter: nil),
                       .transient(status: 503, code: nil, retryAfter: 1))
        XCTAssertNil(CloudHTTPError.retryDelay(URLError(.cancelled)))
        XCTAssertNil(CloudHTTPError.retryDelay(CancellationError()))
        XCTAssertEqual(CloudHTTPError.retryDelay(URLError(.networkConnectionLost)), 1)
    }

    func testLookupDistinguishesAbsentJobFromMalformedOrUnrelatedJob() throws {
        let id = UUID(), slot = UUID()
        XCTAssertNil(try CloudJob.lookup(Data("{\"job\":null}".utf8), requested: [slot], mode: .force))
        let job: [String: Any] = ["id": id.uuidString, "status": "pending", "mode": "force",
            "accountIds": [slot.uuidString], "expiresAt": "2026-10-14T01:00:00.000Z", "debited": false]
        let body = try JSONSerialization.data(withJSONObject: ["job": job])
        XCTAssertEqual(try CloudJob.lookup(body, requested: [slot], mode: .force)?.id, id)
        XCTAssertThrowsError(try CloudJob.lookup(body, requested: [UUID()], mode: .force))
        XCTAssertThrowsError(try CloudJob.lookup(body, requested: [slot], mode: .auto))
        for raw in ["{}", "{\"job\":false}", "{\"job\":null,\"private\":true}"] {
            XCTAssertThrowsError(try CloudJob.lookup(Data(raw.utf8), requested: [slot], mode: .force))
        }
    }

    func testCloudCredentialSaveRejectsInvalidSessionAndPreservesFailedReplacement() throws {
        let original = Data("old usable credential".utf8)
        var stored = original
        let token = String(repeating: "a", count: 43)
        let expiry = Date().addingTimeInterval(3600)
        for session in [CloudSession(baseURL: URL(string: "http://example.invalid")!, token: token, expiresAt: expiry),
                        CloudSession(baseURL: URL(string: "https://example.invalid")!, token: "short", expiresAt: expiry),
                        CloudSession(baseURL: URL(string: "https://example.invalid")!, token: String(repeating: "+", count: 43), expiresAt: expiry)] {
            XCTAssertThrowsError(try CloudSessionStore.encoded(session))
            XCTAssertEqual(stored, original)
        }
        let valid = CloudSession(baseURL: URL(string: "https://example.invalid")!, token: token, expiresAt: expiry)
        let data = try ConnectionRecord(generation: UUID(), mode: .cloud,
            credential: CloudSessionStore.encoded(valid)).encoded()
        XCTAssertThrowsError(try ConnectionKeychain.write(data, update: { _, _ in errSecInteractionNotAllowed },
            add: { _, _ in stored = Data(); return errSecSuccess }))
        XCTAssertEqual(stored, original)
        try ConnectionKeychain.write(data, update: { _, values in
            let attributes = values as NSDictionary
            XCTAssertEqual(attributes[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            stored = attributes[kSecValueData] as! Data
            return errSecSuccess
        }, add: { _, _ in stored = Data(); return errSecSuccess })
        let record = try ConnectionRecord.decode(stored)
        XCTAssertEqual(record.mode, .cloud)
        XCTAssertEqual(try JSONDecoder().decode(CloudSession.self, from: XCTUnwrap(record.credential)).token, token)
    }

    func testRefreshIntentSavePreservesOriginalOnFailureAndRestoresExactReplacement() throws {
        let session = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(3600))
        let slot = UUID(), originalKey = UUID(), replacementKey = UUID()
        let originalBody = Data("{ \"mode\":\"auto\", \"accountIds\":[\"\(slot.uuidString.lowercased())\"], \"idempotencyKey\":\"\(originalKey.uuidString.lowercased())\" }".utf8)
        let replacementBody = Data("{\n \"idempotencyKey\":\"\(replacementKey.uuidString.lowercased())\", \"mode\":\"force\", \"accountIds\":[\"\(slot.uuidString.lowercased())\"]\n}".utf8)
        let original = try CloudRefreshIntent(revision: 7, body: originalBody)
        let replacement = try CloudRefreshIntent(revision: 8, body: replacementBody)
        var stored = try CloudRefreshIntentStore.encode(original, session: session)
        let originalRecord = stored

        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecDuplicateItem] {
            XCTAssertThrowsError(try CloudRefreshIntentStore.save(replacement, session: session,
                update: { _, _ in status }, add: { _, _ in
                    XCTFail("Only a missing item may trigger add")
                    stored = Data()
                    return errSecSuccess
                }))
            XCTAssertEqual(stored, originalRecord)
            let restored = try XCTUnwrap(CloudRefreshIntentStore.decode(stored, session: session, revision: 0))
            XCTAssertEqual(restored.body, originalBody)
            XCTAssertEqual(restored.idempotencyKey, originalKey)
            XCTAssertEqual(restored.mode, .auto)
        }

        try CloudRefreshIntentStore.save(replacement, session: session, update: { _, values in
            let attributes = values as NSDictionary
            XCTAssertEqual(attributes[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
            stored = attributes[kSecValueData] as! Data
            return errSecSuccess
        }, add: { _, _ in XCTFail("Successful update must not add"); return errSecSuccess })
        let restored = try XCTUnwrap(CloudRefreshIntentStore.decode(stored, session: session, revision: 0))
        XCTAssertEqual(restored.body, replacementBody)
        XCTAssertEqual(restored.idempotencyKey, replacementKey)
        XCTAssertEqual(restored.mode, .force)

        var missing: Data?
        XCTAssertThrowsError(try CloudRefreshIntentStore.save(replacement, session: session,
            update: { _, _ in errSecItemNotFound }, add: { _, _ in errSecInteractionNotAllowed }))
        XCTAssertNil(missing)
        try CloudRefreshIntentStore.save(replacement, session: session,
            update: { _, _ in errSecItemNotFound }, add: { item, result in
                let attributes = item as NSDictionary
                XCTAssertNil(result)
                XCTAssertEqual(attributes[kSecAttrAccessible] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
                XCTAssertEqual(attributes[kSecAttrAccount] as? String, "refresh-intent")
                missing = attributes[kSecValueData] as? Data
                return errSecSuccess
            })
        let added = try XCTUnwrap(CloudRefreshIntentStore.decode(try XCTUnwrap(missing), session: session, revision: 0))
        XCTAssertEqual(added.body, replacementBody)
        XCTAssertEqual(added.idempotencyKey, replacementKey)
        XCTAssertEqual(added.mode, .force)
    }

    @MainActor
    func testIntentRecoveryFailurePublishesReadAndBlocksRefreshUntilLaterRecovery() async throws {
        let model = CloudModel()
        let session = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(3600))
        model.session = session
        defer { model.clear() }
        let slot = UUID()
        let intent = try CloudRefreshIntent(revision: model.revision, ids: [slot], mode: .force)
        let record = try CloudRefreshIntentStore.encode(intent, session: session)
        var publications = 0
        model.onSnapshot = { _ in publications += 1 }
        let fetch: (String) async throws -> Data = { path in
            switch path {
            case "v2/me":
                return Data("""
                {"tier":"free","limits":{"accounts":3,"autoMinutes":120,"allowedAutoMinutes":[120],"earlyBatchesPerDay":10,"live":false},"autoMinutes":120,"earlyBatchesUsed":2,"liveSessionsUsed":0,"liveSessionsLimit":0,"purchasesAvailable":false}
                """.utf8)
            case "v2/snapshot/page?limit=250":
                return Data("""
                {"schemaVersion":2,"generatedAt":"2026-10-13T10:30:00Z","demo":false,"accounts":[{"accountId":"\(slot)","provider":"codex","plan":null,"state":"unavailable","source":"codexbar","observedAt":null,"windows":[{"id":"primary","label":"Session","remainingPercent":null,"resetsAt":null}],"lastError":null}],"nextCursor":null}
                """.utf8)
            case "v2/collectors": return Data("{\"collectors\":[]}".utf8)
            default: XCTFail("Unexpected read endpoint: \(path)"); throw SnapshotError.invalid
            }
        }
        // Both inaccessible and malformed records must leave authoritative
        // reads visible, including subsequent reads with already populated slots.
        for status in [errSecInteractionNotAllowed, errSecSuccess] {
            await model.read(fetchData: fetch, intentCopyMatching: { _, result in
                if status == errSecSuccess { result?.pointee = Data("{}".utf8) as CFData }
                return status
            })
            XCTAssertEqual(model.slots.map(\.id), [slot])
            XCTAssertEqual(model.snapshot?.accounts.map(\.id), [slot])
            XCTAssertEqual(model.me?.earlyBatchesUsed, 2)
            XCTAssertTrue(model.budget.contains(DockL10n.text("Free")))
            XCTAssertTrue(model.status.contains("Refresh blocked"))
            // This should return before any transport or new intent creation.
            await model.refresh(force: false)
            XCTAssertTrue(model.status.contains("Refresh blocked"))
            await model.refresh(force: true)
            XCTAssertTrue(model.status.contains("Refresh blocked"))
            model.selectRefreshSlots([])
        }
        XCTAssertEqual(publications, 2)
        await model.read(fetchData: fetch, intentCopyMatching: { _, result in
            result?.pointee = record as CFData
            return errSecSuccess
        })
        XCTAssertEqual(publications, 3)
        XCTAssertEqual(model.refreshSelection.ids, intent.ids)
        XCTAssertFalse(model.status.contains("Refresh blocked"))
        // Existing store/intent tests assert byte-exact body/key preservation;
        // this regression observes recovery through the model's published state.
    }

    func testCancellationConsumesNoAttemptAndPreventsTransport() async throws {
        let task = Task {
            var intent = try CloudRefreshIntent(revision: 0, ids: [UUID()], mode: .live)
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try intent.beginAttempt(); XCTFail("Cancelled attempt accepted") }
            catch is CancellationError { }
            XCTAssertEqual(intent.attempts, 0)
            let client = try CloudClient(baseURL: "https://example.invalid")
            do {
                _ = try await client.request("v2/refresh", method: "POST", encodedBody: intent.body)
                XCTFail("Cancelled transport accepted")
            } catch is CancellationError { }
        }
        try await task.value
    }
}
