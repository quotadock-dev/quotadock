import XCTest
@testable import QuotaDock

final class ContractTests: XCTestCase {
    private let cloudFixture = Data("""
    {"schemaVersion":2,"generatedAt":"2026-10-13T10:30:00Z","demo":false,"sessionToken":"must-not-cache","accounts":[
      {"accountId":"11111111-1111-4111-8111-111111111111","provider":"codex","name":"ignored private name","plan":"ChatGPT Pro","state":"available","source":"codexbar","observedAt":"2026-10-13T10:00:00.123Z","windows":[{"id":"primary","label":"Session","remainingPercent":75,"resetsAt":null},{"id":"secondary","label":"Weekly","remainingPercent":28,"resetsAt":null}],"lastError":"private diagnostic"},
      {"accountId":"22222222-2222-4222-8222-222222222222","provider":"codex","name":"Codex","plan":null,"state":"unavailable","source":"codexbar","observedAt":null,"windows":[{"id":"primary","label":"Session","remainingPercent":null,"resetsAt":null}],"lastError":null}
    ]}
    """.utf8)

    func testAppleChallengeRejectsMalformedWireBeforeAuthorization() throws {
        let id = "a1111111-1111-4111-8111-111111111111"
        let nonce = "Az09-_" + String(repeating: "b", count: 37)
        let wire: [String: Any] = ["challengeId": id, "nonce": nonce, "expiresIn": 300]
        let challenge = try CloudChallenge.decode(JSONSerialization.data(withJSONObject: wire))
        XCTAssertEqual(challenge.challengeId, id)
        XCTAssertEqual(challenge.nonce, nonce)
        XCTAssertEqual(challenge.expiresIn, 300)
        for (field, value) in [("challengeId", "not-a-uuid" as Any),
                               ("challengeId", id.uppercased() as Any),
                               ("nonce", String(nonce.dropLast()) as Any),
                               ("nonce", "$" + String(nonce.dropFirst()) as Any),
                               ("expiresIn", 0 as Any), ("expiresIn", 301 as Any),
                               ("expiresIn", true as Any), ("identityToken", "unexpected" as Any)] {
            var invalid = wire
            invalid[field] = value
            XCTAssertThrowsError(try CloudChallenge.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
        for field in wire.keys {
            var invalid = wire
            invalid.removeValue(forKey: field)
            XCTAssertThrowsError(try CloudChallenge.decode(JSONSerialization.data(withJSONObject: invalid)))
        }
        XCTAssertThrowsError(try CloudChallenge.decode(Data("[]".utf8)))
    }

    func testCloudPreservesSameProviderSlotsAndUnknownWindows() throws {
        let snapshot = try CloudSnapshot.decode(cloudFixture)
        XCTAssertEqual(snapshot.accounts.count, 2)
        XCTAssertNotEqual(snapshot.accounts[0].id, snapshot.accounts[1].id)
        XCTAssertEqual(snapshot.accounts.map(\.provider), [.codex, .codex])
        XCTAssertEqual(snapshot.accounts[0].windows.count, 2)
        XCTAssertEqual(snapshot.accounts[0].reading.displayWindows[1].clampedRemaining, 28)
        XCTAssertNil(snapshot.accounts[1].reading.displayWindows.first?.clampedRemaining)
        XCTAssertNil(snapshot.accounts[1].observedAt)
        XCTAssertEqual(snapshot.smallSurfaceSnapshot.providers.count, 1)
        XCTAssertEqual(snapshot.smallSurfaceSnapshot.providers[0].windows[0].clampedRemaining, 75)
        XCTAssertEqual(snapshot.smallSurfaceSnapshot.providers[0].observedAt, snapshot.accounts[0].observedAt)
    }

    func testCloudDatesAcceptServerBoundaryAndOffsetWithoutChangingInstant() throws {
        for (milliseconds, expected) in [("123", 1791885600.123), ("000", 1791885600.0), ("999", 1791885600.999)] {
            let timestamp = "2026-10-13T10:00:00.\(milliseconds)" + String(repeating: "9", count: 40) + "Z"
            XCTAssertEqual(timestamp.utf8.count, 64)
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: cloudFixture) as? [String: Any])
            var accounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
            accounts[0]["observedAt"] = timestamp
            var windows = try XCTUnwrap(accounts[0]["windows"] as? [[String: Any]])
            windows[0]["resetsAt"] = "2026-10-13T19:00:00.\(milliseconds)+09:00"
            accounts[0]["windows"] = windows
            root["accounts"] = accounts
            let snapshot = try CloudSnapshot.decode(JSONSerialization.data(withJSONObject: root))
            let observation = try XCTUnwrap(snapshot.accounts[0].observedAt)
            let reset = try XCTUnwrap(snapshot.accounts[0].windows[0].resetsAt)
            XCTAssertEqual(observation.timeIntervalSince1970, expected, accuracy: 0.0001)
            XCTAssertEqual(reset.timeIntervalSince1970, expected, accuracy: 0.0001)
            let cached = try CloudSnapshot.decode(snapshot.cacheData())
            XCTAssertEqual(cached.accounts[0].observedAt, observation)
            XCTAssertEqual(cached.accounts[0].windows[0].resetsAt, reset)
            var sharedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.smallSurfaceSnapshot.encoded()) as? [String: Any])
            sharedRoot["generatedAt"] = timestamp
            let shared = try Snapshot.decode(JSONSerialization.data(withJSONObject: sharedRoot))
            XCTAssertEqual(shared.generatedAt.timeIntervalSince1970, expected, accuracy: 0.0001)
            XCTAssertEqual(shared.providers[0].observedAt, observation)
            for invalid in [timestamp.replacingOccurrences(of: "Z", with: "9Z"), timestamp + "\n",
                            timestamp.replacingOccurrences(of: "T", with: "Ｔ")] {
                accounts[0]["observedAt"] = invalid
                root["accounts"] = accounts
                XCTAssertThrowsError(try CloudSnapshot.decode(JSONSerialization.data(withJSONObject: root)))
            }
        }
    }

    func testCloudCacheExportsOnlySanitizedQuotaAndOriginalTime() throws {
        let snapshot = try CloudSnapshot.decode(cloudFixture)
        let full = try snapshot.cacheData()
        let shared = try snapshot.smallSurfaceSnapshot.encoded()
        for data in [full, shared] {
            let text = String(decoding: data, as: UTF8.self)
            for secret in ["sessionToken", "must-not-cache", "private diagnostic", "ignored private name"] {
                XCTAssertFalse(text.contains(secret))
            }
        }
        let cached = try CloudSnapshot.decode(full)
        XCTAssertEqual(cached.accounts.count, 2)
        XCTAssertEqual(cached.accounts[0].observedAt, snapshot.accounts[0].observedAt)
        XCTAssertEqual(cached.accounts[0].lastError, "collection_unavailable")
        XCTAssertNil(cached.accounts[1].windows[0].clampedRemaining)
        XCTAssertEqual(try Snapshot.decode(shared).providers[0].observedAt, snapshot.accounts[0].observedAt)
    }

    func testCloudVerifiedTierLimitsIntervalsAndCounters() throws {
        for (tier, cap, minutes, allowed, early, liveLimit) in [
            ("free", "3", 120, "[120]", "10", 0),
            ("plus", "10", 60, "[60]", "null", 5),
            ("pro", "25", 20, "[20,30,60,120]", "null", 5)
        ] {
            let json = """
            {"tier":"\(tier)","limits":{"accounts":\(cap),"autoMinutes":\(minutes),"allowedAutoMinutes":\(allowed),"earlyBatchesPerDay":\(early),"live":\(tier != "free")},"autoMinutes":\(minutes),"earlyBatchesUsed":2,"liveSessionsUsed":0,"liveSessionsLimit":\(liveLimit),"purchasesAvailable":false,"identity":"never display"}
            """
            let me = try CloudMe.decode(Data(json.utf8))
            XCTAssertEqual(me.autoMinutes, minutes)
            XCTAssertEqual(me.earlyBatchesUsed, 2)
            XCTAssertEqual(me.limits.accounts, Int(cap))
            XCTAssertFalse(me.purchasesAvailable)
            XCTAssertEqual(me.tier.rawValue, tier)
            XCTAssertFalse(me.budget.contains("never display"))
            let collectorCap = tier == "free" ? 1 : tier == "plus" ? 3 : 5
            let collectors = json.replacingOccurrences(of: "\"accounts\":\(cap)", with: "\"accounts\":\(cap),\"collectors\":\(collectorCap)")
            XCTAssertEqual(try CloudMe.decode(Data(collectors.utf8)).limits.collectors, collectorCap)
            XCTAssertThrowsError(try CloudMe.decode(Data(collectors.replacingOccurrences(of: "\"collectors\":\(collectorCap)", with: "\"collectors\":99").utf8)))
            let enabled = json.replacingOccurrences(of: "\"purchasesAvailable\":false", with: "\"purchasesAvailable\":true")
            XCTAssertThrowsError(try CloudMe.decode(Data(enabled.utf8)))
            let bound = enabled.replacingOccurrences(of: "\"identity\":\"never display\"", with:
                "\"appAccountToken\":\"33333333-3333-4333-8333-333333333333\"")
            XCTAssertEqual(try CloudMe.decode(Data(bound.utf8)).appAccountToken,
                UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
            XCTAssertThrowsError(try CloudMe.decode(Data(json.replacingOccurrences(of: "\"earlyBatchesUsed\":2", with: "\"earlyBatchesUsed\":-1").utf8)))
            XCTAssertThrowsError(try CloudMe.decode(Data(json.replacingOccurrences(of: "\"tier\":\"\(tier)\"", with: "\"tier\":\"clientPaid\"").utf8)))
            XCTAssertThrowsError(try CloudMe.decode(Data(json.replacingOccurrences(of: "\"autoMinutes\":\(minutes)", with: "\"autoMinutes\":7").utf8)))
            if tier == "pro" {
                for interval in [20, 30, 60, 120] {
                    XCTAssertEqual(try CloudMe.decode(Data(json.replacingOccurrences(of: "\"autoMinutes\":20", with: "\"autoMinutes\":\(interval)").utf8)).autoMinutes, interval)
                }
                var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                root["liveSession"] = ["accountIds": ["11111111-1111-4111-8111-111111111111"], "startedAt": "2026-10-13T10:00:00.000Z", "deadline": "2026-10-13T10:30:00.000Z"]
                let resumed = try CloudMe.decode(JSONSerialization.data(withJSONObject: root))
                XCTAssertEqual(resumed.liveSessionsUsed, 0) // Renewal can reset counters during an active session.
                XCTAssertEqual(resumed.liveSession?.deadlineDate, Date(timeIntervalSince1970: 1791887400))
            }
        }
    }

    func testRefreshTracksItsExactJobAndTerminalDoesNotRequireNewObservation() throws {
        let id = "44444444-4444-4444-8444-444444444444"
        let account = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let other = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let pending = """
        {"id":"\(id)","status":"pending","mode":"auto","accountIds":["\(account.uuidString)"],"expiresAt":"2026-10-13T10:05:00.000Z","debited":false}
        """
        let issued = try CloudJob.decode(Data(pending.utf8), requested: [account, other], mode: .auto)
        // Auto targets only due slots. A failed completion has no new observation or debit.
        let completed = pending.replacingOccurrences(of: "pending", with: "completed")
        XCTAssertEqual(try CloudJob.decode(Data(completed.utf8), requested: [account, other], mode: .auto, previous: issued).status, .completed)
        for invalid in [pending.replacingOccurrences(of: id, with: UUID().uuidString),
                        pending.replacingOccurrences(of: account.uuidString, with: other.uuidString),
                        pending.replacingOccurrences(of: "10:05:00", with: "10:06:00"),
                        pending.replacingOccurrences(of: "\"debited\":false", with: "\"debited\":true"),
                        pending.replacingOccurrences(of: "pending", with: "unknown")] {
            XCTAssertThrowsError(try CloudJob.decode(Data(invalid.utf8), requested: [account, other], mode: .auto, previous: issued))
        }
        XCTAssertThrowsError(try CloudJob.decode(Data(pending.utf8), requested: [other], mode: .auto))
        XCTAssertThrowsError(try CloudJob.decode(Data(pending.replacingOccurrences(of: "auto", with: "force").utf8), requested: [account, other], mode: .force))
        let cached = pending.replacingOccurrences(of: "pending", with: "cached")
            .replacingOccurrences(of: "[\"\(account.uuidString)\"]", with: "[]")
        XCTAssertEqual(try CloudJob.decode(Data(cached.utf8), requested: [account, other], mode: .auto).status, .cached)
        XCTAssertThrowsError(try CloudJob.decode(Data(pending.replacingOccurrences(of: "pending", with: "cached").utf8), requested: [account], mode: .auto))
    }

    func testCloudSnapshotAllowsMoreThanFreeRegistrationCap() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: cloudFixture) as? [String: Any])
        let template = try XCTUnwrap((root["accounts"] as? [[String: Any]])?.first)
        root["accounts"] = (0..<11).map { _ -> [String: Any] in
            var account = template
            account["accountId"] = UUID().uuidString
            return account
        }
        let snapshot = try CloudSnapshot.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(snapshot.accounts.count, 11)
        XCTAssertEqual(snapshot.smallSurfaceSnapshot.providers.count, 1)
    }

    func testRefreshBatchPreservesSubsetAndEnforcesOwnershipAndFiftyLimit() {
        let slots = (0..<61).map { _ in CloudAccount(id: UUID(), provider: .codex) }
        var batch = CloudBatchSelection()
        batch.reconcile(slots: slots)
        XCTAssertEqual(batch.ids, Array(slots.prefix(50).map(\.id)))
        let subset = [slots[3].id, slots[27].id, slots[60].id]
        XCTAssertTrue(batch.select(subset, slots: slots))
        batch.reconcile(slots: Array(slots.reversed()))
        XCTAssertEqual(batch.ids, subset)
        for invalid in [Array(slots.prefix(51).map(\.id)), [slots[3].id, slots[3].id], [slots[3].id, UUID()]] {
            XCTAssertFalse(CloudBatchSelection.valid(invalid, slots: slots))
            XCTAssertFalse(batch.select(invalid, slots: slots))
            XCTAssertEqual(batch.ids, subset)
        }
        XCTAssertTrue(CloudBatchSelection.valid(Array(slots.prefix(50).map(\.id)), slots: slots))
        batch.reconcile(slots: slots.filter { $0.id != slots[27].id })
        XCTAssertEqual(batch.ids, [slots[3].id, slots[60].id])
        XCTAssertTrue(batch.select([], slots: slots))
        batch.reconcile(slots: slots)
        XCTAssertTrue(batch.ids.isEmpty) // An explicit empty selection is not silently refilled.
        XCTAssertFalse(CloudBatchSelection.valid(batch.ids, slots: slots))
        XCTAssertFalse(CollectorApproval.valid(code: "AB0123EF", selected: Set(slots.prefix(51).map(\.id)), slots: slots))
    }

    @MainActor
    func testLiveAcceptsSelectedSubsetAndRestoresDifferentServerSubset() throws {
        let model = CloudModel()
        model.foreground = false // No network work is scheduled by this contract test.
        let slots = (0..<60).map { _ in CloudAccount(id: UUID(), provider: .codex) }
        model.slots = slots
        let selected = [slots[4].id, slots[58].id]
        model.selectRefreshSlots(selected)
        let json = """
        {"tier":"pro","limits":{"accounts":25,"collectors":5,"autoMinutes":20,"allowedAutoMinutes":[20,30,60,120],"earlyBatchesPerDay":null,"live":true},"autoMinutes":20,"earlyBatchesUsed":0,"liveSessionsUsed":0,"liveSessionsLimit":5,"purchasesAvailable":false}
        """
        model.me = try CloudMe.decode(Data(json.utf8))
        model.startLive()
        XCTAssertTrue(model.liveEnabled) // More than 50 registrations do not block a small batch.
        model.clear()
        model.slots = slots
        model.selectRefreshSlots(selected)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        root["liveSession"] = ["accountIds": [slots[22].id.uuidString],
                               "startedAt": "2099-01-01T00:00:00.000Z", "deadline": "2099-01-01T00:30:00.000Z"]
        model.me = try CloudMe.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertTrue(model.selectionLocked)
        model.selectRefreshSlots([slots[1].id])
        XCTAssertEqual(model.refreshSelection.ids, selected)
        model.startLive()
        XCTAssertTrue(model.liveEnabled) // Restore need not equal every registration or the UI selection.
        XCTAssertEqual(model.liveDeadline, model.me?.liveSession?.deadlineDate)
        model.clear()
    }

    @MainActor
    func testCloudModelSelectionSurvivesReadsAndClearsOnLogout() {
        let model = CloudModel()
        let slots = (0..<60).map { _ in CloudAccount(id: UUID(), provider: .claude) }
        model.slots = slots
        model.selectRefreshSlots([slots[9].id, slots[59].id])
        model.slots = Array(slots.reversed())
        XCTAssertEqual(model.refreshSelection.ids, [slots[9].id, slots[59].id])
        model.liveEnabled = true
        model.selectRefreshSlots([slots[1].id])
        XCTAssertEqual(model.refreshSelection.ids, [slots[9].id, slots[59].id])
        model.clear()
        XCTAssertTrue(model.refreshSelection.ids.isEmpty)
        model.slots = [slots[1]]
        XCTAssertEqual(model.refreshSelection.ids, [slots[1].id])
    }

    func testCollectorApprovalRequiresOwnedSlotsAndExactCode() {
        let first = CloudAccount(id: UUID(), provider: .codex)
        let duplicate = CloudAccount(id: UUID(), provider: .codex)
        let other = CloudAccount(id: UUID(), provider: .claude)
        let slots = [first, duplicate, other]
        XCTAssertTrue(CollectorApproval.valid(code: "AB0123EF", selected: [first.id, other.id], slots: slots))
        XCTAssertTrue(CollectorApproval.valid(code: "AB0123EF", selected: [first.id, duplicate.id], slots: slots))
        XCTAssertFalse(CollectorApproval.valid(code: "AB0123EF", selected: [UUID()], slots: slots))
        XCTAssertFalse(CollectorApproval.valid(code: "AB0123EF", selected: [], slots: slots))
        for code in ["ab0123ef", "AB0123EG", " AB0123EF", "AB0123E", "ＡＢ0123EF"] {
            XCTAssertFalse(CollectorApproval.valid(code: code, selected: [first.id], slots: slots))
        }
    }

    func testCloudRejectsDuplicateAccountsAndInsecureServer() throws {
        let duplicate = String(decoding: cloudFixture, as: UTF8.self).replacingOccurrences(
            of: "22222222-2222-4222-8222-222222222222", with: "11111111-1111-4111-8111-111111111111")
        XCTAssertThrowsError(try CloudSnapshot.decode(Data(duplicate.utf8)))
        XCTAssertThrowsError(try CloudSnapshot.decode(Data(repeating: 32, count: 256 * 1024 + 1)))
        XCTAssertThrowsError(try CloudClient(baseURL: "http://usage.mvtp.cloud"))
        XCTAssertThrowsError(try CloudClient(baseURL: "https://user:password@example.com"))
        XCTAssertThrowsError(try CloudClient(baseURL: "https://example.com?secret=x"))
        XCTAssertEqual(try CloudClient(baseURL: "https://usage.mvtp.cloud").baseURL.host, "usage.mvtp.cloud")
    }

    @MainActor
    func testModeSwitchInvalidatesOldCompletionsAndClearsBothCaches() {
        let model = DockModel()
        model.snapshot = .preview
        let oldRevision = model.pairingRevision
        let oldCloudRevision = model.cloud.revision
        model.cloud.clear()
        XCTAssertGreaterThan(model.pairingRevision, oldRevision)
        XCTAssertGreaterThan(model.cloud.revision, oldCloudRevision)
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.cloud.snapshot)
        XCTAssertNil(SnapshotStore.load())
        XCTAssertNil(CloudCache.load())
    }

    @MainActor
    func testCloudSignInRequiresBothConsentsBeforeStartingAuthorization() async {
        for (storage, processing) in [(false, false), (true, false), (false, true)] {
            let model = CloudModel()
            model.foreground = true
            // An invalid target distinguishes consent rejection from URL/network failure.
            await model.connect(base: "not-a-server", quotaStorageConsent: storage, collectorProcessingConsent: processing)
            XCTAssertTrue(model.status.contains("Consent required"))
            XCTAssertFalse(model.busy)
        }
    }

    private let fixture = Data("""
    {"schemaVersion":1,"generatedAt":"2026-10-13T10:00:00Z","demo":false,"providers":[{"id":"codex","name":"Codex","plan":null,"state":"unavailable","source":"codexbar","message":null,"observedAt":null,"windows":[{"id":"primary","label":"Session","remainingPercent":null,"resetsAt":null}]}]}
    """.utf8)

    func testNullRemainsUnknownAndRoundTripsAsNull() throws {
        let snapshot = try Snapshot.decode(fixture)
        let provider = try XCTUnwrap(snapshot.providers.first)
        XCTAssertNil(provider.plan)
        XCTAssertNil(provider.windows.first?.clampedRemaining)
        XCTAssertTrue(provider.isStale())
        let data = try snapshot.encoded()
        XCTAssertEqual(try Snapshot.decode(data), snapshot)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encodedProvider = try XCTUnwrap((root["providers"] as? [[String: Any]])?.first)
        XCTAssertTrue(encodedProvider["plan"] is NSNull)
        XCTAssertTrue(encodedProvider["observedAt"] is NSNull)
        let window = try XCTUnwrap((encodedProvider["windows"] as? [[String: Any]])?.first)
        XCTAssertTrue(window["remainingPercent"] is NSNull)
        XCTAssertTrue(window["resetsAt"] is NSNull)
    }

    func testClampDoesNotTurnUnknownIntoZero() {
        for (input, expected) in [(Double(-8), Double(0)), (180, 100), (0, 0)] {
            XCTAssertEqual(QuotaWindow(id: "x", label: "x", remainingPercent: input, resetsAt: nil).clampedRemaining, expected)
        }
        XCTAssertNil(QuotaWindow(id: "x", label: "x", remainingPercent: nil, resetsAt: nil).clampedRemaining)
    }

    func testStalenessAndDemo() throws {
        let snapshot = Snapshot.preview
        XCTAssertTrue(snapshot.demo)
        XCTAssertTrue(snapshot.providers.allSatisfy { $0.source == .demo })
        let provider = try XCTUnwrap(snapshot.providers.first)
        let observed = try XCTUnwrap(provider.observedAt)
        XCTAssertFalse(provider.isStale(at: observed.addingTimeInterval(900)))
        XCTAssertTrue(provider.isStale(at: observed.addingTimeInterval(901)))
    }

    func testDisplayWindowsNeverGaugeLookupFailuresAndPreserveWindows() {
        let reset = Date(timeIntervalSince1970: 1234)
        let windows = [QuotaWindow(id: "session", label: "Session", remainingPercent: 0, resetsAt: reset),
                       QuotaWindow(id: "weekly", label: "Weekly", remainingPercent: 72, resetsAt: nil)]
        for state in [ProviderState.available, .unavailable, .error] {
            let provider = Provider(id: .codex, name: "Codex", plan: nil, state: state,
                                    source: .codexbar, message: nil, observedAt: reset, windows: windows)
            XCTAssertEqual(provider.displayWindows.map(\.id), ["session", "weekly"])
            XCTAssertEqual(provider.displayWindows.first?.resetsAt, reset)
            XCTAssertEqual(provider.observedAt, reset)
            if state == .available {
                XCTAssertEqual(provider.displayWindows, windows)
            } else {
                XCTAssertTrue(provider.displayWindows.allSatisfy { $0.clampedRemaining == nil })
            }
        }
    }

    func testForegroundRefreshDefaultsOnAndHonorsManualOnly() throws {
        let suite = "QuotaDockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(RefreshSettings.foregroundEnabled(in: defaults))
        defaults.set(false, forKey: RefreshSettings.foregroundKey)
        XCTAssertFalse(RefreshSettings.foregroundEnabled(in: defaults))
        defaults.set(true, forKey: RefreshSettings.foregroundKey)
        XCTAssertTrue(RefreshSettings.foregroundEnabled(in: defaults))
    }

    func testRejectsUnsupportedVersionOversizeAndBadDates() {
        XCTAssertThrowsError(try Snapshot.decode(Data(String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8)))
        XCTAssertThrowsError(try Snapshot.decode(Data(repeating: 32, count: 256 * 1024 + 1)))
        XCTAssertThrowsError(try Snapshot.decode(Data(String(decoding: fixture, as: UTF8.self).replacingOccurrences(of: "2026-10-13T10:00:00Z", with: "bad-date").utf8)))
    }

    func testHTTPSOnlyPairing() throws {
        XCTAssertThrowsError(try Pairing(baseURL: "http://example.com", token: "secret"))
        XCTAssertThrowsError(try Pairing(baseURL: "https://user:pass@example.com", token: "secret"))
        XCTAssertThrowsError(try Pairing(baseURL: "https://example.com?token=secret", token: "secret"))
        XCTAssertThrowsError(try Pairing(baseURL: "https://example.com", token: "secret\nheader"))
        for token in ["secret\u{0}header", "space token", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try Pairing(baseURL: "https://example.com", token: token))
        }
        XCTAssertEqual(try Pairing(baseURL: "https://example.com", token: "secret").endpoint.path, "/v1/snapshot")
    }

    func testNetworkRequestAndSafeResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let client = BridgeClient(session: URLSession(configuration: configuration))
        let snapshot = try await client.fetch(Pairing(baseURL: "https://example.com", token: "test-token"))
        XCTAssertEqual(snapshot.providers.first?.message, "Usage unavailable")
        XCTAssertNil(snapshot.providers.first?.windows.first?.clampedRemaining)
        do {
            _ = try await client.fetch(Pairing(baseURL: "https://example.com/reject", token: "test-token"))
            XCTFail("Must reject non-200 responses")
        } catch BridgeTransportError.unauthorized { } catch { XCTFail("Unexpected error type") }
        do {
            _ = try await client.fetch(Pairing(baseURL: "https://example.com/oversized", token: "test-token"))
            XCTFail("Must stop oversized response streams")
        } catch BridgeTransportError.transport { } catch { XCTFail("Unexpected error type") }
    }
}

private final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertTrue(request.url?.path.hasSuffix("/v1/snapshot") == true)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let status = request.url?.path.contains("reject") == true ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if request.url?.path.contains("oversized") == true {
            client?.urlProtocol(self, didLoad: Data(repeating: 32, count: 256 * 1024 + 1))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didLoad: Data("""
        {"schemaVersion":1,"generatedAt":"2026-10-13T10:00:00.123Z","demo":false,"providers":[{"id":"codex","name":"Codex","plan":null,"state":"error","source":"codexbar","message":"private diagnostic","observedAt":null,"windows":[{"id":"primary","label":"Session","remainingPercent":99,"resetsAt":null}]}]}
        """.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
