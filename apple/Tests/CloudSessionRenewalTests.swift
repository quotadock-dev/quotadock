import XCTest
import Security
@testable import QuotaDock

final class CloudSessionRenewalTests: XCTestCase {
    private func original() -> CloudSession {
        CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: Date().addingTimeInterval(-1),
            refreshToken: String(repeating: "b", count: 43), familyId: UUID(),
            refreshExpiresAt: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86400))
    }
    private func response(_ session: CloudSession, issuedAt: Date = Date()) throws -> Data {
        let formatter = ISO8601DateFormatter()
        return try JSONSerialization.data(withJSONObject: [
            "sessionToken": String(repeating: "c", count: 43), "expiresIn": 3600,
            "expiresAt": formatter.string(from: issuedAt.addingTimeInterval(3600)),
            "refreshToken": String(repeating: "d", count: 43),
            "familyId": session.familyId!.uuidString.lowercased(),
            "refreshExpiresAt": formatter.string(from: session.refreshExpiresAt!)])
    }

    @MainActor
    func testConcurrentCallersShareOneRotationAndPreserveObservationsAndIntent() async throws {
        let model = CloudModel(), old = original()
        model.session = old
        let slot = UUID()
        model.slots = [CloudAccount(id: slot, provider: .codex)]
        let observed = Date(timeIntervalSince1970: 1791936000)
        model.snapshot = CloudSnapshot(schemaVersion: 2, generatedAt: observed, demo: false,
            accounts: [.init(accountId: slot, provider: .codex, plan: "ChatGPT Plus", state: .available,
                source: .codexbar, observedAt: observed,
                windows: [QuotaWindow(id: "primary", label: "Session", remainingPercent: 73, resetsAt: nil)], lastError: nil)])
        model.liveDeadline = Date().addingTimeInterval(900)
        let deadline = model.liveDeadline, revision = model.revision
        let intent = try CloudRefreshIntent(revision: revision, ids: [slot], mode: .force)
        let record = try CloudRefreshIntentStore.encode(intent, session: old)
        var sends = 0, saves: [CloudSession] = []
        let data = try response(old)
        let fetch: (Data) async throws -> Data = { _ in
            sends += 1
            await Task.yield()
            return data
        }
        async let first = model.authorizedClient(fetchRenewal: fetch, save: { saves.append($0) })
        async let second = model.authorizedClient(fetchRenewal: fetch, save: { saves.append($0) })
        let clients = try await (first, second)
        XCTAssertEqual(clients.0.token, String(repeating: "c", count: 43))
        XCTAssertEqual(clients.0.token, clients.1.token)
        XCTAssertEqual(sends, 1)
        XCTAssertNotNil(saves.first?.pendingRenewal)
        XCTAssertNil(model.session?.pendingRenewal)
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.slots.map(\.id), [slot])
        XCTAssertEqual(model.snapshot?.accounts.first?.windows.first?.remainingPercent, 73)
        XCTAssertEqual(model.snapshot?.accounts.first?.plan, "ChatGPT Plus")
        XCTAssertEqual(model.snapshot?.accounts.first?.observedAt, observed)
        XCTAssertEqual(model.snapshot?.generatedAt, observed)
        XCTAssertEqual(model.liveDeadline, deadline)
        let recovered = try XCTUnwrap(CloudRefreshIntentStore.decode(record, session: try XCTUnwrap(model.session), revision: revision))
        XCTAssertEqual(recovered.body, intent.body)
    }

    @MainActor
    func testAccountSwitchStartsIndependentRenewalAndLateOldCleanupPreservesCoalescing() async throws {
        // Deliberately ignore transport cancellation, but never leave a checked
        // continuation suspended indefinitely, even when an assertion fails.
        @MainActor final class SuspendedTransport {
            var continuation: CheckedContinuation<Data, Error>?
            var timeout: Task<Void, Never>?

            func fetch(started: XCTestExpectation) async throws -> Data {
                try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    started.fulfill()
                    timeout = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: 5_000_000_000) }
                        catch { return }
                        finish(.failure(URLError(.timedOut)))
                    }
                }
            }

            func finish(_ result: Result<Data, Error>) {
                let pending = continuation
                continuation = nil
                timeout?.cancel()
                timeout = nil
                pending?.resume(with: result)
            }
        }

        let model = CloudModel(), accountA = original()
        let accountB = CloudSession(baseURL: accountA.baseURL,
            token: String(repeating: "e", count: 43), expiresAt: accountA.expiresAt,
            refreshToken: String(repeating: "f", count: 43), familyId: UUID(),
            refreshExpiresAt: accountA.refreshExpiresAt)
        let responseA = try response(accountA)
        var replyB = try XCTUnwrap(JSONSerialization.jsonObject(with: response(accountB)) as? [String: Any])
        replyB["sessionToken"] = String(repeating: "g", count: 43)
        replyB["refreshToken"] = String(repeating: "h", count: 43)
        let responseB = try JSONSerialization.data(withJSONObject: replyB)
        let transportA = SuspendedTransport(), transportB = SuspendedTransport()
        let startedA = expectation(description: "A transport suspended")
        let startedB = expectation(description: "B starts its own rotation while A is suspended")
        let completedA = expectation(description: "A rejects its late response")
        let completedB = expectation(description: "B completes")
        let completedSecondB = expectation(description: "Second B completes")
        let enteredSecondB = expectation(description: "Second B requests authorization")
        let prematureSecondB = expectation(description: "Second B must wait for B transport")
        prematureSecondB.isInverted = true
        var saves: [CloudSession] = []
        var sendsB = 0
        var resultA: Result<String, Error>?
        var resultB: Result<String, Error>?
        var resultSecondB: Result<String, Error>?
        var secondTransportCalls = 0
        var releasedB = false
        model.session = accountA
        let firstA = Task { @MainActor in
            do {
                let client = try await model.authorizedClient(fetchRenewal: { _ in
                    try await transportA.fetch(started: startedA)
                }, save: { saves.append($0) })
                resultA = .success(try XCTUnwrap(client.token))
            } catch { resultA = .failure(error) }
            completedA.fulfill()
        }
        var firstB: Task<Void, Never>?
        var secondB: Task<Void, Never>?
        defer {
            firstA.cancel(); firstB?.cancel(); secondB?.cancel()
            model.foreground = false
            transportA.finish(.failure(CancellationError()))
            transportB.finish(.failure(CancellationError()))
        }
        await fulfillment(of: [startedA], timeout: 2)
        model.session = accountB
        firstB = Task { @MainActor in
            do {
                let client = try await model.authorizedClient(fetchRenewal: { _ in
                    sendsB += 1
                    return try await transportB.fetch(started: startedB)
                }, save: { saves.append($0) })
                resultB = .success(try XCTUnwrap(client.token))
            } catch { resultB = .failure(error) }
            completedB.fulfill()
        }
        await fulfillment(of: [startedB], timeout: 2)
        XCTAssertEqual(sendsB, 1)
        XCTAssertEqual(model.session?.familyId, accountB.familyId)
        XCTAssertNotNil(model.session?.pendingRenewal)

        // Let the obsolete caller finish while B still owns a suspended rotation.
        transportA.finish(.success(responseA))
        await fulfillment(of: [completedA], timeout: 2)
        if case .failure(let error) = resultA { XCTAssertTrue(error is CancellationError) }
        else { XCTFail("A must not authorize after the account switch") }
        XCTAssertEqual(model.session?.token, accountB.token)
        XCTAssertEqual(model.session?.familyId, accountB.familyId)
        XCTAssertFalse(saves.contains { $0.familyId == accountA.familyId && $0.pendingRenewal == nil })

        secondB = Task { @MainActor in
            enteredSecondB.fulfill()
            do {
                let client = try await model.authorizedClient(fetchRenewal: { _ in
                    secondTransportCalls += 1
                    throw SnapshotError.invalid
                }, save: { saves.append($0) })
                resultSecondB = .success(try XCTUnwrap(client.token))
            } catch { resultSecondB = .failure(error) }
            if !releasedB { prematureSecondB.fulfill() }
            completedSecondB.fulfill()
        }
        await fulfillment(of: [enteredSecondB], timeout: 2)
        await fulfillment(of: [prematureSecondB], timeout: 0.1)
        XCTAssertEqual(secondTransportCalls, 0)
        XCTAssertEqual(model.session?.token, accountB.token)
        releasedB = true
        transportB.finish(.success(responseB))
        await fulfillment(of: [completedB, completedSecondB], timeout: 2)
        let tokenB = try XCTUnwrap(resultB).get()
        XCTAssertEqual(tokenB, String(repeating: "g", count: 43))
        XCTAssertEqual(try XCTUnwrap(resultSecondB).get(), tokenB)
        XCTAssertEqual(model.session?.token, tokenB)
        XCTAssertEqual(model.session?.refreshToken, String(repeating: "h", count: 43))
        XCTAssertEqual(model.session?.familyId, accountB.familyId)
        XCTAssertNil(model.session?.pendingRenewal)
        XCTAssertEqual(sendsB, 1)
        XCTAssertEqual(secondTransportCalls, 0)
        XCTAssertEqual(saves.filter { $0.pendingRenewal == nil }.map(\.familyId), [accountB.familyId])
    }

    @MainActor
    func testTransientRetryUsesIdenticalBodyAndRestartUsesPersistedKey() async throws {
        let model = CloudModel(), old = original()
        model.session = old
        var bodies: [Data] = [], stored = old
        let data = try response(old)
        _ = try await model.authorizedClient(fetchRenewal: { body in
            bodies.append(body)
            if bodies.count == 1 { throw URLError(.networkConnectionLost) }
            return data
        }, save: { stored = $0 })
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bodies[0]) as? [String: String])
        var pending = old
        pending.pendingRenewal = UUID(uuidString: root["idempotencyKey"]!)
        pending.pendingRenewalStartedAt = Date()
        pending.pendingRenewalSends = 1
        let restored = try JSONDecoder().decode(CloudSession.self, from: JSONEncoder().encode(pending))
        model.session = restored
        _ = try await model.authorizedClient(fetchRenewal: { body in
            XCTAssertEqual(body, bodies[0]); return data
        }, save: { stored = $0 })
        XCTAssertNil(stored.pendingRenewal)
    }

    @MainActor
    func testMalformedMismatchAndAtomicReplacementFailureRetainPendingOldCredential() async throws {
        for kind in 0..<3 {
            let model = CloudModel(), old = original()
            model.session = old
            var stored = old
            var other = old; other.familyId = UUID()
            let data = kind == 0 ? Data("{}".utf8) : try response(kind == 1 ? other : old)
            do {
                _ = try await model.authorizedClient(fetchRenewal: { _ in data }, save: { next in
                    if next.pendingRenewal == nil {
                        let bytes = try ConnectionRecord(generation: UUID(), mode: .cloud,
                            credential: CloudSessionStore.encoded(next)).encoded()
                        try ConnectionKeychain.write(bytes, update: { _, _ in errSecInteractionNotAllowed },
                            add: { _, _ in XCTFail("Replacement must not add"); return errSecSuccess })
                    }
                    stored = next
                })
                XCTFail("Unconfirmed replacement installed")
            } catch { }
            XCTAssertEqual(model.session?.token, old.token)
            XCTAssertEqual(stored.token, old.token)
            XCTAssertNotNil(stored.pendingRenewal)
        }
    }

    @MainActor
    func testLockClearAndAccountSwitchRejectLateCompletion() async throws {
        for kind in 0..<3 {
            let model = CloudModel(), old = original()
            model.session = old
            let data = try response(old)
            var replacements = 0
            do {
                _ = try await model.authorizedClient(fetchRenewal: { _ in
                    if kind == 0 { model.foreground = false }
                    else if kind == 1 { model.clear() }
                    else { model.session = self.original() }
                    return data
                }, save: { if $0.pendingRenewal == nil { replacements += 1 } })
                XCTFail("Late authority published")
            } catch { }
            XCTAssertEqual(replacements, 0)
            XCTAssertNotEqual(model.session?.token, String(repeating: "c", count: 43))
            if kind == 0 { XCTAssertNotNil(model.session?.pendingRenewal) }
        }
    }

    @MainActor
    func testLegacyExpiredAccessRequiresSignInWithoutTransport() async throws {
        let model = CloudModel(), old = original()
        model.session = CloudSession(baseURL: old.baseURL, token: old.token, expiresAt: old.expiresAt)
        do {
            _ = try await model.authorizedClient(fetchRenewal: { _ in XCTFail("Legacy refresh sent"); return Data() },
                save: { _ in XCTFail("Legacy credentials replaced") })
            XCTFail("Expired access authorized")
        } catch { }
        XCTAssertNil(model.session)
        XCTAssertTrue(model.status.contains("Sign in again"))
    }

    @MainActor
    func testPendingSaveFailureAndExpiredRetryWindowNeverSend() async throws {
        for expired in [false, true] {
            let model = CloudModel()
            var old = original()
            if expired {
                old.pendingRenewal = UUID()
                old.pendingRenewalStartedAt = Date().addingTimeInterval(-61)
                old.pendingRenewalSends = 1
            }
            model.session = old
            do {
                _ = try await model.authorizedClient(fetchRenewal: { _ in
                    XCTFail("Unsafe renewal sent"); return Data()
                }, save: { _ in throw SnapshotError.unpaired })
                XCTFail("Unpersisted or stale attempt accepted")
            } catch { }
            XCTAssertEqual(model.session?.token, old.token)
            XCTAssertEqual(model.session?.pendingRenewal, old.pendingRenewal)
        }
    }

    func testIdenticalResponseDoesNotExtendAccessWhenReceivedAgain() throws {
        let issued = Date(timeIntervalSince1970: 1791936000)
        let old = CloudSession(baseURL: URL(string: "https://example.invalid/api")!,
            token: String(repeating: "a", count: 43), expiresAt: issued.addingTimeInterval(-1),
            refreshToken: String(repeating: "b", count: 43), familyId: UUID(),
            refreshExpiresAt: issued.addingTimeInterval(86400))
        let data = try response(old, issuedAt: issued)
        let first = try CloudSession.login(data, baseURL: old.baseURL, previous: old, now: issued)
        let retried = try CloudSession.login(data, baseURL: old.baseURL, previous: old,
                                           now: issued.addingTimeInterval(59))
        XCTAssertEqual(first.expiresAt, Date(timeIntervalSince1970: 1791939600))
        XCTAssertEqual(retried.expiresAt, Date(timeIntervalSince1970: 1791939600))
        XCTAssertEqual(retried.refreshExpiresAt, issued.addingTimeInterval(86400))
    }

    func testIncompletePendingRecordIsRejectedBeforeCredentialStorage() throws {
        var invalid = original()
        invalid.pendingRenewal = UUID()
        invalid.pendingRenewalStartedAt = Date()
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertThrowsError(try CloudSessionStore.encoded(invalid))
    }

    func testStrictResponseShapeAndFixedFamily() throws {
        let old = original()
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: response(old)) as? [String: Any])
        let bad: [[String: Any]] = [
            valid.merging(["unexpected": true]) { _, new in new },
            valid.merging(["refreshToken": NSNull()]) { _, new in new },
            valid.merging(["familyId": old.familyId!.uuidString.uppercased()]) { _, new in new },
            valid.merging(["expiresIn": 3601]) { _, new in new },
            valid.merging(["refreshToken": old.refreshToken!]) { _, new in new },
            valid.merging(["refreshToken": String(repeating: "c", count: 43)]) { _, new in new },
            valid.merging(["sessionToken": old.token]) { _, new in new },
            valid.merging(["expiresAt": NSNull()]) { _, new in new },
            valid.merging(["expiresAt": "2099-01-01T00:00:00Z"]) { _, new in new },
            valid.merging(["refreshExpiresAt": "2099-01-01T00:00:00Z"]) { _, new in new }
        ]
        for root in bad {
            XCTAssertThrowsError(try CloudSession.login(JSONSerialization.data(withJSONObject: root),
                baseURL: old.baseURL, previous: old))
        }
        let legacy = CloudSession(baseURL: old.baseURL, token: old.token, expiresAt: old.expiresAt)
        let decoded = try JSONDecoder().decode(CloudSession.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.familyId)
        XCTAssertNil(decoded.pendingRenewal)
    }
}
