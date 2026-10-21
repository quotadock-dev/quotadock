import XCTest
import Security
import Combine
@testable import QuotaDock

final class CloudPaginationTests: XCTestCase {
    private var previousCacheBlock = false
    override func setUp() {
        super.setUp()
        // These cases inject transport and sessions. Isolate their cache state
        // from another case's deliberately failed persistent disconnection.
        previousCacheBlock = SnapshotStore.blocked
        SnapshotStore.blocked = false
    }
    override func tearDown() {
        SnapshotStore.blocked = previousCacheBlock
        super.tearDown()
    }

    private var freeMetadata: Data {
        Data("""
        {"tier":"free","limits":{"accounts":3,"autoMinutes":120,"allowedAutoMinutes":[120],"earlyBatchesPerDay":10,"live":false},"autoMinutes":120,"earlyBatchesUsed":7,"liveSessionsUsed":0,"liveSessionsLimit":0,"purchasesAvailable":false}
        """.utf8)
    }
    private func uuid(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "%08x-0000-4000-8000-000000000000", index))!
    }
    private func page(_ ids: [UUID], next: UUID? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "accounts": ids.map { ["id": $0.uuidString, "provider": "codex"] },
            "nextCursor": next.map { $0.uuidString as Any } ?? NSNull()
        ])
    }
    private func snapshotPage(_ ids: [UUID], next: UUID? = nil, demo: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2, "generatedAt": "2026-10-13T10:30:00Z", "demo": demo,
            "accounts": ids.map { ["accountId": $0.uuidString, "provider": "codex",
                "state": "available", "source": "codexbar", "observedAt": "2026-10-13T10:00:00Z",
                "windows": []] as [String: Any] },
            "nextCursor": next.map { $0.uuidString as Any } ?? NSNull()
        ])
    }
    func testCursorTraversalPreservesDistinctSameProviderSlotsAndBatch() async throws {
        let ids = (1...275).map(uuid)
        let slots = try await CloudPagination.accounts { path in
            let after = URLComponents(string: "https://example.com/" + path)?.queryItems?
                .first(where: { $0.name == "after" })?.value
            let start = after.flatMap { UUID(uuidString: $0) }.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            XCTAssertTrue(path.contains("limit=250"))
            let end = min(start + 250, ids.count)
            return try self.page(Array(ids[start..<end]), next: end < ids.count ? ids[end - 1] : nil)
        }
        XCTAssertEqual(slots.map(\.id), ids)
        var batch = CloudBatchSelection()
        batch.reconcile(slots: slots)
        XCTAssertEqual(batch.ids, Array(ids.prefix(50)))
        XCTAssertTrue(batch.select([ids[74]], slots: slots))
        batch.reconcile(slots: slots)
        XCTAssertEqual(batch.ids, [ids[74]])
        let snapshot = try await CloudPagination.snapshot(slots: slots) { path in
            let after = URLComponents(string: "https://example.com/" + path)?.queryItems?
                .first(where: { $0.name == "after" })?.value
            let start = after.flatMap { UUID(uuidString: $0) }.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            XCTAssertTrue(path.contains("limit=250"))
            let end = min(start + 250, ids.count)
            return try self.snapshotPage(Array(ids[start..<end]), next: end < ids.count ? ids[end - 1] : nil)
        }
        XCTAssertEqual(snapshot.accounts.map(\.id), ids)
        XCTAssertEqual(snapshot.smallSurfaceSnapshot.providers.count, 1)
    }
    func testRejectsDuplicateUnsortedNonadvancingAndMissingCursor() async throws {
        let invalid = [try page([uuid(1), uuid(1)]), try page([uuid(2), uuid(1)]),
                       try page([uuid(1)], next: uuid(2)), try page([], next: uuid(1)),
                       Data("{\"accounts\":[]}".utf8)]
        for data in invalid {
            do {
                _ = try await CloudPagination.accounts { _ in data }
                XCTFail("Malformed page accepted")
            } catch { }
        }
        do {
            _ = try await CloudPagination.accounts { _ in try self.page([self.uuid(1)], next: self.uuid(1)) }
            XCTFail("Repeated page accepted")
        } catch { }
    }
    func testLegacyFallbackOnlyForMissingFirstEndpoint() async throws {
        let legacy = Data("{\"accounts\":[{\"id\":\"\(uuid(1))\",\"provider\":\"codex\"}]}".utf8)
        let result = try await CloudPagination.accounts { path in
            if path.hasPrefix("v2/accounts/page") { throw CloudHTTPError.notFound }
            return legacy
        }
        XCTAssertEqual(result.map(\.id), [uuid(1)])
        for failure in [SnapshotError.response, SnapshotError.invalid] {
            do {
                _ = try await CloudPagination.accounts { path in
                    if path.hasPrefix("v2/accounts/page") { throw failure }
                    XCTFail("Non-404 failure attempted legacy fallback")
                    return legacy
                }
                XCTFail("Failed endpoint accepted")
            } catch { }
        }
        do {
            _ = try await CloudPagination.accounts { path in
                if path.contains("after=") { throw CloudHTTPError.notFound }
                if path.hasPrefix("v2/accounts/page") { return try self.page([self.uuid(1)], next: self.uuid(1)) }
                XCTFail("Mid-traversal 404 attempted fallback")
                return legacy
            }
            XCTFail("Incomplete traversal accepted")
        } catch { }
    }
    func testRejectsForeignMissingAndDemoSnapshotRows() async throws {
        let slots = [CloudAccount(id: uuid(1), provider: .codex)]
        for data in [try snapshotPage([uuid(2)]), try snapshotPage([]), try snapshotPage([uuid(1)], demo: true)] {
            do {
                _ = try await CloudPagination.snapshot(slots: slots) { _ in data }
                XCTFail("Invalid snapshot accepted")
            } catch { }
        }
    }
    func testEndlessAdvancingPagesAreBounded() async throws {
        do {
            _ = try await CloudPagination.accounts { path in
                let after = URLComponents(string: "https://example.com/" + path)?.queryItems?
                    .first(where: { $0.name == "after" })?.value
                let value = after.flatMap { Int($0.prefix(8), radix: 16) } ?? 0
                return try self.page([self.uuid(value + 1)], next: self.uuid(value + 1))
            }
            XCTFail("Unending pagination accepted")
        } catch { }
    }
    func testLargeCacheIsExplicitSubsetWithOriginalTimes() throws {
        let original = try CloudSnapshot.decode(snapshotPage([uuid(1)]))
        let account = original.accounts[0]
        let rows = (1...5000).map { index in
            CloudSnapshot.Account(accountId: uuid(index), provider: account.provider, plan: account.plan,
                state: account.state, source: account.source, observedAt: account.observedAt,
                windows: account.windows, lastError: nil)
        }
        let large = CloudSnapshot(schemaVersion: 2, generatedAt: original.generatedAt, demo: false, accounts: rows)
        let data = try large.cacheData()
        XCTAssertLessThanOrEqual(data.count, 256 * 1024)
        let cached = try CloudSnapshot.decode(data)
        XCTAssertEqual(cached.cachedSubset, true)
        XCTAssertEqual(cached.accounts.map(\.id), Array(rows.prefix(50)).map(\.id))
        XCTAssertEqual(cached.generatedAt, original.generatedAt)
        XCTAssertEqual(cached.accounts[0].observedAt, account.observedAt)
        XCTAssertEqual(large.accounts.count, 5000)
        XCTAssertEqual(try CloudSnapshot.decode(cached.cacheData()).cachedSubset, true)
    }
    @MainActor
    func testReadReturnsAllFiveThousandSlotsUsingOnlyTwentySnapshotPages() async throws {
        let model = CloudModel()
        model.session = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(3600))
        defer { model.clear() }
        let ids = (1...5000).map(uuid)
        let original = try CloudSnapshot.decode(snapshotPage([ids[0]]))
        var paths: [String] = []
        var publications = 0
        model.onSnapshot = { _ in publications += 1 }
        await model.read(fetchData: { path in
            paths.append(path)
            if path == "v2/me" {
                return Data("""
                {"tier":"pro","limits":{"accounts":25,"collectors":5,"autoMinutes":20,"allowedAutoMinutes":[20,30,60,120],"earlyBatchesPerDay":null,"live":true},"autoMinutes":20,"earlyBatchesUsed":0,"liveSessionsUsed":0,"liveSessionsLimit":5,"purchasesAvailable":false}
                """.utf8)
            }
            if path == "v2/collectors" { return Data("{\"collectors\":[]}".utf8) }
            guard path.hasPrefix("v2/snapshot/page?limit=250") else {
                XCTFail("Redundant or unexpected endpoint: \(path)"); throw SnapshotError.invalid
            }
            let after = URLComponents(string: "https://example.invalid/" + path)?.queryItems?
                .first(where: { $0.name == "after" })?.value
            let start = after.flatMap { UUID(uuidString: $0) }.flatMap { ids.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            let end = min(start + 250, ids.count)
            return try self.snapshotPage(Array(ids[start..<end]), next: end < ids.count ? ids[end - 1] : nil)
        }, intentCopyMatching: { _, _ in errSecItemNotFound })
        XCTAssertEqual(paths.count, 22)
        XCTAssertEqual(paths.filter { $0.hasPrefix("v2/snapshot/page?") }.count, 20)
        XCTAssertEqual(paths.filter { $0 == "v2/me" }.count, 1)
        XCTAssertEqual(paths.filter { $0 == "v2/collectors" }.count, 1)
        XCTAssertFalse(paths.contains { $0.hasPrefix("v2/accounts") })
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(model.slots.map(\.id), ids)
        XCTAssertEqual(model.snapshot?.accounts.map(\.id), ids)
        XCTAssertEqual(model.snapshot?.accounts.last?.id, ids.last)
        XCTAssertEqual(model.snapshot?.generatedAt, original.generatedAt)
        XCTAssertTrue(model.snapshot?.accounts.allSatisfy { $0.observedAt == original.accounts[0].observedAt } == true)
        XCTAssertEqual(model.refreshSelection.ids, Array(ids.prefix(50)))

        let selected = [ids[4999], ids[74], ids[2500]]
        model.selectRefreshSlots(selected)
        XCTAssertEqual(model.refreshSelection.ids, selected)
        let collectors = try JSONDecoder().decode([CloudCollector].self, from: Data("""
        [{"id":"\(uuid(6000))","accountIds":["\(ids[74])"],"expiresAt":"2099-10-13T10:00:00Z"}]
        """.utf8))
        model.collectors = collectors
        model.liveEnabled = true
        let status = model.status
        let cached = try XCTUnwrap(CloudCache.load())
        paths.removeAll()
        await model.read(entitlementsOnly: true, fetchData: { path in
            paths.append(path)
            guard path == "v2/me" else {
                XCTFail("Entitlement read traversed quotas: \(path)")
                throw SnapshotError.invalid
            }
            return self.freeMetadata
        })
        XCTAssertEqual(paths, ["v2/me"])
        XCTAssertEqual(model.me?.tier, .free)
        XCTAssertEqual(model.me?.autoMinutes, 120)
        XCTAssertEqual(model.me?.earlyBatchesUsed, 7)
        XCTAssertTrue(model.budget.hasPrefix(DockL10n.text("Free")))
        XCTAssertTrue(model.budget.contains("7/10"))
        XCTAssertFalse(model.liveEnabled)
        XCTAssertNil(model.liveDeadline)
        XCTAssertFalse(model.selectionLocked)
        XCTAssertEqual(model.slots.map(\.id), ids)
        XCTAssertEqual(model.snapshot?.accounts.map(\.id), ids)
        XCTAssertEqual(model.snapshot?.generatedAt, original.generatedAt)
        XCTAssertTrue(model.snapshot?.accounts.allSatisfy { $0.observedAt == original.accounts[0].observedAt } == true)
        XCTAssertEqual(model.refreshSelection.ids, selected)
        XCTAssertEqual(model.collectors.map(\.id), collectors.map(\.id))
        XCTAssertEqual(model.collectors.first?.accountIds, collectors.first?.accountIds)
        XCTAssertEqual(model.collectors.first?.expiresAt, collectors.first?.expiresAt)
        XCTAssertEqual(model.status, status)
        XCTAssertEqual(publications, 1)
        let retainedCache = try XCTUnwrap(CloudCache.load())
        XCTAssertEqual(retainedCache.accounts.map(\.id), cached.accounts.map(\.id))
        XCTAssertEqual(retainedCache.accounts.map(\.observedAt), cached.accounts.map(\.observedAt))
        XCTAssertEqual(retainedCache.generatedAt, cached.generatedAt)
        XCTAssertEqual(retainedCache.cachedSubset, cached.cachedSubset)
    }
    @MainActor
    func testEntitlementRequestsDuringQuotaReadCoalesceAndPublishUpdatedBudget() async throws {
        let model = CloudModel()
        model.session = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(3600))
        defer { model.clear() }
        let enteredSnapshot = expectation(description: "Quota read suspended")
        let updatedBudget = expectation(description: "Pending entitlement budget published")
        let observation = model.$budget.filter { $0.hasPrefix(DockL10n.text("Free")) && $0.contains("7/10") }
            .sink { _ in updatedBudget.fulfill() }
        defer { observation.cancel() }
        var resumeSnapshot: CheckedContinuation<Void, Never>?
        var paths: [String] = []
        var publications = 0
        var metadataReads = 0
        model.onSnapshot = { _ in publications += 1 }
        let quotaRead = Task { @MainActor in
            await model.read(fetchData: { path in
                paths.append(path)
                if path == "v2/me" {
                    metadataReads += 1
                    if metadataReads > 1 { return self.freeMetadata }
                    return Data("""
                    {"tier":"pro","limits":{"accounts":25,"collectors":5,"autoMinutes":20,"allowedAutoMinutes":[20,30,60,120],"earlyBatchesPerDay":null,"live":true},"autoMinutes":20,"earlyBatchesUsed":0,"liveSessionsUsed":0,"liveSessionsLimit":5,"purchasesAvailable":false}
                    """.utf8)
                }
                if path == "v2/snapshot/page?limit=250" {
                    await withCheckedContinuation { continuation in
                        resumeSnapshot = continuation
                        enteredSnapshot.fulfill()
                    }
                    return try self.snapshotPage([self.uuid(1)])
                }
                if path == "v2/collectors" { return Data("{\"collectors\":[]}".utf8) }
                XCTFail("Unexpected endpoint: \(path)")
                throw SnapshotError.invalid
            }, intentCopyMatching: { _, _ in errSecItemNotFound })
        }
        defer { quotaRead.cancel() }
        await fulfillment(of: [enteredSnapshot], timeout: 2)
        let continuation = try XCTUnwrap(resumeSnapshot)
        for _ in 0..<3 {
            await model.read(entitlementsOnly: true, fetchData: { _ in
                XCTFail("Queued call should coalesce, not fetch immediately")
                throw SnapshotError.invalid
            })
        }
        XCTAssertEqual(metadataReads, 1)
        continuation.resume()
        await quotaRead.value
        await fulfillment(of: [updatedBudget], timeout: 2)
        XCTAssertEqual(model.me?.tier, .free)
        XCTAssertEqual(model.me?.earlyBatchesUsed, 7)
        XCTAssertTrue(model.budget.hasPrefix(DockL10n.text("Free")))
        XCTAssertTrue(model.budget.contains("7/10"))
        XCTAssertEqual(paths, ["v2/me", "v2/snapshot/page?limit=250", "v2/collectors", "v2/me"])
        XCTAssertEqual(model.slots.map(\.id), [uuid(1)])
        XCTAssertEqual(model.snapshot?.accounts.map(\.id), [uuid(1)])
        XCTAssertEqual(model.refreshSelection.ids, [uuid(1)])
        XCTAssertEqual(publications, 1)
    }
    @MainActor
    func testAccountSwitchKeepsNewReadOwnershipWhileSupersededMetadataReturns() async throws {
        let model = CloudModel()
        model.session = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(3600))
        defer { model.clear() }
        let enteredMetadata = expectation(description: "Account A metadata suspended")
        let enteredSnapshot = expectation(description: "Account B snapshot suspended")
        let oldReadFinished = expectation(description: "Account A read discarded")
        let newReadFinished = expectation(description: "Account B full read finished")
        let updatedBudget = expectation(description: "Account B coalesced budget published")
        let observation = model.$budget.filter { $0.hasPrefix(DockL10n.text("Free")) && $0.contains("9/10") }
            .sink { _ in updatedBudget.fulfill() }
        defer { observation.cancel() }
        var resumeMetadata: CheckedContinuation<Void, Never>?
        var resumeSnapshot: CheckedContinuation<Void, Never>?
        var metadataReleased = false
        var snapshotReleased = false
        func releaseMetadata() {
            metadataReleased = true
            let continuation = resumeMetadata
            resumeMetadata = nil
            continuation?.resume()
        }
        func releaseSnapshot() {
            snapshotReleased = true
            let continuation = resumeSnapshot
            resumeSnapshot = nil
            continuation?.resume()
        }
        defer { releaseMetadata(); releaseSnapshot() }
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 6_000_000_000) }
            catch { return }
            XCTFail("Account-switch read suspension exceeded watchdog deadline")
            releaseMetadata()
            releaseSnapshot()
        }
        defer { watchdog.cancel() }
        var oldPaths: [String] = []
        let oldRead = Task { @MainActor in
            await model.read(entitlementsOnly: true, fetchData: { path in
                oldPaths.append(path)
                XCTAssertEqual(path, "v2/me")
                await withCheckedContinuation { continuation in
                    if metadataReleased { continuation.resume() }
                    else { resumeMetadata = continuation }
                    enteredMetadata.fulfill()
                }
                return Data("""
                {"tier":"pro","limits":{"accounts":25,"collectors":5,"autoMinutes":20,"allowedAutoMinutes":[20,30,60,120],"earlyBatchesPerDay":null,"live":true},"autoMinutes":20,"earlyBatchesUsed":0,"liveSessionsUsed":0,"liveSessionsLimit":5,"purchasesAvailable":false}
                """.utf8)
            })
            oldReadFinished.fulfill()
        }
        defer { oldRead.cancel() }
        await fulfillment(of: [enteredMetadata], timeout: 2)
        // A distinct authority resets read ownership through the session interface.
        model.session = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "b", count: 43), expiresAt: Date().addingTimeInterval(3600))
        var paths: [String] = []
        var metadataReads = 0
        var publications = 0
        model.onSnapshot = { _ in publications += 1 }
        let newRead = Task { @MainActor in
            await model.read(fetchData: { path in
                paths.append(path)
                switch path {
                case "v2/me":
                    metadataReads += 1
                    if metadataReads == 1 { return self.freeMetadata }
                    return Data(String(decoding: self.freeMetadata, as: UTF8.self)
                        .replacingOccurrences(of: "\"earlyBatchesUsed\":7", with: "\"earlyBatchesUsed\":9").utf8)
                case "v2/snapshot/page?limit=250":
                    await withCheckedContinuation { continuation in
                        if snapshotReleased { continuation.resume() }
                        else { resumeSnapshot = continuation }
                        enteredSnapshot.fulfill()
                    }
                    return try self.snapshotPage([self.uuid(9)])
                case "v2/collectors": return Data("{\"collectors\":[]}".utf8)
                default: XCTFail("Unexpected endpoint: \(path)"); throw SnapshotError.invalid
                }
            }, intentCopyMatching: { _, _ in errSecItemNotFound })
            newReadFinished.fulfill()
        }
        defer { newRead.cancel() }
        await fulfillment(of: [enteredSnapshot], timeout: 2)
        releaseMetadata()
        await fulfillment(of: [oldReadFinished], timeout: 2)
        XCTAssertNotEqual(model.me?.tier, .pro)
        XCTAssertFalse(model.budget.hasPrefix("Pro"))
        XCTAssertEqual(publications, 0)
        for _ in 0..<3 {
            await model.read(entitlementsOnly: true, fetchData: { _ in
                XCTFail("Account A completion released account B's coalescing ownership")
                throw SnapshotError.invalid
            })
        }
        XCTAssertEqual(metadataReads, 1)
        XCTAssertEqual(paths, ["v2/me", "v2/snapshot/page?limit=250"])
        releaseSnapshot()
        await fulfillment(of: [newReadFinished, updatedBudget], timeout: 2)
        XCTAssertEqual(oldPaths, ["v2/me"])
        XCTAssertEqual(paths, ["v2/me", "v2/snapshot/page?limit=250", "v2/collectors", "v2/me"])
        XCTAssertEqual(metadataReads, 2)
        XCTAssertEqual(model.me?.tier, .free)
        XCTAssertEqual(model.me?.earlyBatchesUsed, 9)
        XCTAssertTrue(model.budget.hasPrefix(DockL10n.text("Free")))
        XCTAssertTrue(model.budget.contains("9/10"))
        XCTAssertEqual(model.slots.map(\.id), [uuid(9)])
        XCTAssertEqual(model.snapshot?.accounts.map(\.id), [uuid(9)])
        XCTAssertEqual(model.refreshSelection.ids, [uuid(9)])
        XCTAssertEqual(publications, 1)
    }
    @MainActor
    func testSignoutDiscardsInFlightAndPendingEntitlementReads() async throws {
        let model = CloudModel()
        model.session = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(3600))
        defer { model.clear() }
        model.snapshot = try CloudSnapshot.decode(snapshotPage([uuid(1)]))
        model.slots = [CloudAccount(id: uuid(1), provider: .codex)]
        let enteredMetadata = expectation(description: "Metadata response suspended")
        var resumeMetadata: CheckedContinuation<Void, Never>?
        var paths: [String] = []
        var publications = 0
        model.onSnapshot = { _ in publications += 1 }
        let entitlementRead = Task { @MainActor in
            await model.read(entitlementsOnly: true, fetchData: { path in
                paths.append(path)
                XCTAssertEqual(path, "v2/me")
                await withCheckedContinuation { continuation in
                    resumeMetadata = continuation
                    enteredMetadata.fulfill()
                }
                return self.freeMetadata
            })
        }
        defer { entitlementRead.cancel() }
        await fulfillment(of: [enteredMetadata], timeout: 2)
        let continuation = try XCTUnwrap(resumeMetadata)
        await model.read(entitlementsOnly: true, fetchData: { _ in
            XCTFail("Pending entitlement read fetched before signout")
            throw SnapshotError.invalid
        })
        model.clear()
        continuation.resume()
        await entitlementRead.value
        // A further receipt notification has no authority after signout either.
        await model.read(entitlementsOnly: true, fetchData: { _ in
            XCTFail("Signed-out receipt notification fetched metadata")
            throw SnapshotError.invalid
        })
        XCTAssertEqual(paths, ["v2/me"])
        XCTAssertNil(model.session)
        XCTAssertNil(model.me)
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(model.slots.isEmpty)
        XCTAssertTrue(model.refreshSelection.ids.isEmpty)
        XCTAssertTrue(model.collectors.isEmpty)
        XCTAssertEqual(model.budget, "")
        XCTAssertFalse(model.liveEnabled)
        XCTAssertEqual(publications, 0)
        XCTAssertNil(CloudCache.load())
    }
    func testRejectsMoreThanFiveThousandSnapshotSlots() async throws {
        var requests = 0
        do {
            _ = try await CloudPagination.snapshot { _ in
                let start = requests * 250 + 1
                requests += 1
                let ids = (start..<(start + 250)).map(self.uuid)
                return try self.snapshotPage(ids, next: ids.last)
            }
            XCTFail("A traversal requiring more than 5,000 slots was accepted")
        } catch { }
        XCTAssertEqual(requests, 20)
    }
    func testAuthoritativeLegacyFallbackStillValidatesOwnedSlots() async throws {
        for foreign in [false, true] {
            var paths: [String] = []
            do {
                let result = try await CloudPagination.snapshot { path in
                    paths.append(path)
                    switch path {
                    case "v2/snapshot/page?limit=250", "v2/accounts/page?limit=250":
                        throw CloudHTTPError.notFound
                    case "v2/accounts": return try self.page([self.uuid(1)])
                    case "v2/snapshot": return try self.snapshotPage([self.uuid(foreign ? 2 : 1)])
                    default: XCTFail("Unexpected fallback endpoint"); throw SnapshotError.invalid
                    }
                }
                XCTAssertFalse(foreign)
                XCTAssertEqual(result.accounts.map(\.id), [uuid(1)])
            } catch { XCTAssertTrue(foreign) }
            XCTAssertEqual(paths, ["v2/snapshot/page?limit=250", "v2/accounts/page?limit=250", "v2/accounts", "v2/snapshot"])
        }
    }
    @MainActor
    func testReadWithoutAuthorityOrForegroundRetainsObservationsAndSelection() async throws {
        let model = CloudModel()
        model.session = nil
        let original = try CloudSnapshot.decode(snapshotPage([uuid(1)]))
        model.snapshot = original
        model.slots = [CloudAccount(id: uuid(1), provider: .codex)]
        await model.read()
        XCTAssertEqual(model.snapshot?.accounts.map(\.id), original.accounts.map(\.id))
        XCTAssertEqual(model.snapshot?.generatedAt, original.generatedAt)
        XCTAssertEqual(model.refreshSelection.ids, [uuid(1)])
        model.foreground = false
        await model.read(internalWork: true)
        XCTAssertEqual(model.snapshot?.accounts[0].observedAt, original.accounts[0].observedAt)
        XCTAssertEqual(model.refreshSelection.ids, [uuid(1)])
    }

    func testCollectionHealthKeepsObservationReportAndQueuePollDistinct() async throws {
        let observed = "2026-10-21T05:00:00.123Z"
        let reported = "2026-10-21T06:07:00.456Z"
        let polled = "2026-10-21T06:08:00.789Z"
        let result = try await CloudCollectionHealth.read { path in
            if path == "v2/collectors" {
                return try JSONSerialization.data(withJSONObject: ["collectors": [
                    ["id": self.uuid(99).uuidString, "accountIds": [self.uuid(7).uuidString], "expiresAt": "2099-01-01T00:00:00Z"],
                    ["id": self.uuid(101).uuidString, "accountIds": [self.uuid(1).uuidString], "expiresAt": "2099-01-01T00:00:00Z", "lastPolledAt": polled]
                ]])
            }
            if path.contains("after=") {
                return try JSONSerialization.data(withJSONObject: ["accounts": [
                    ["accountId": self.uuid(7).uuidString, "provider": "codex", "observedAt": NSNull(), "lastReportAt": NSNull(), "lastError": NSNull()]
                ], "nextCursor": NSNull(), "reportRetentionDays": 90])
            }
            return try JSONSerialization.data(withJSONObject: ["accounts": [
                ["accountId": self.uuid(1).uuidString, "provider": "claude", "observedAt": observed, "lastReportAt": reported, "lastError": "No fresh measured quota is available."]
            ], "nextCursor": self.uuid(1).uuidString, "reportRetentionDays": 90])
        }
        XCTAssertEqual(result.accounts.map(\.id), [uuid(1), uuid(7)])
        XCTAssertEqual(result.accounts.map(\.provider), [.claude, .codex])
        XCTAssertEqual(try XCTUnwrap(result.accounts[0].observedAt).timeIntervalSince1970, 1_792_558_800.123, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(result.accounts[0].lastReportAt).timeIntervalSince1970, 1_792_562_820.456, accuracy: 0.000001)
        XCTAssertNotNil(result.accounts[0].lastError)
        XCTAssertNil(result.accounts[1].observedAt)
        XCTAssertNil(result.accounts[1].lastReportAt)
        XCTAssertNil(result.collectors[0].lastPolledAt)
        XCTAssertEqual(try XCTUnwrap(result.collectors[1].lastPolledAt).timeIntervalSince1970, 1_792_562_880.789, accuracy: 0.000001)
        XCTAssertEqual(result.collectors[0].accountIds, [uuid(7)])
    }

    func testCollectionHealthRejectsInvalidMetadataWithoutInventingAReading() async throws {
        for (retention, timestamp) in [(30, "2026-10-21T05:00:00Z"), (90, "not-a-date")] {
            do {
                _ = try await CloudCollectionHealth.read { _ in
                    try JSONSerialization.data(withJSONObject: ["accounts": [
                        ["accountId": self.uuid(1).uuidString, "provider": "codex", "observedAt": timestamp, "lastReportAt": NSNull(), "lastError": NSNull()]
                    ], "nextCursor": NSNull(), "reportRetentionDays": retention])
                }
                XCTFail("Invalid collection metadata accepted")
            } catch { }
        }
        do {
            _ = try await CloudCollectionHealth.read { _ in throw CloudHTTPError.notFound }
            XCTFail("Missing health endpoint synthesized data")
        } catch CloudHTTPError.notFound { }
    }
}
