import XCTest
#if os(Linux)
import Glibc
#else
import Darwin
#endif
#if canImport(QuotaDockStorage)
@testable import QuotaDockStorage
#else
@testable import QuotaDock
#endif

final class AccountSurfaceTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_700_000_000.125)
    private func account(_ id: UUID = UUID(), remaining: Double? = 0,
                         state: ProviderState = .available) throws -> AccountSurfaceSnapshot.Account {
        try .init(id: id, reading: Provider(id: .claude, name: "private@example.invalid", plan: "Pro",
            state: state, source: .codexbar, message: "credential=private-value", observedAt: observed,
            windows: [QuotaWindow(id: "primary", label: "Session", remainingPercent: remaining,
                                  resetsAt: observed.addingTimeInterval(3600))]))
    }
    private func sandbox(_ run: (URL, AccountSurfaceCache) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = CacheFiles(manifestURL: root.appendingPathComponent("generation"))
        _ = try files.invalidate()
        try run(root, AccountSurfaceCache(files: files, directory: root.appendingPathComponent("cache")))
    }
    private func snapshot(_ cache: AccountSurfaceCache, _ accounts: [AccountSurfaceSnapshot.Account]) throws -> AccountSurfaceSnapshot {
        .init(generatedAt: observed, generation: try cache.files.generation(), accounts: accounts)
    }
    func testReconstructedDiskSelectionSurvivesReorderAndDeletionNeverSubstitutes() throws {
        try sandbox { _, cache in
            let first = try account(), second = try account(remaining: 73)
            try cache.save(snapshot(cache, [first, second]))
            let reconstructed = AccountSurfaceCache(files: cache.files, directory: cache.directory)
            XCTAssertEqual(reconstructed.selected(second.id)?.identifier, second.identifier)
            try cache.save(snapshot(cache, [second, first]))
            XCTAssertEqual(reconstructed.selected(second.id)?.windows.first?.remainingPercent, 73)
            try cache.save(snapshot(cache, [first]))
            XCTAssertNil(reconstructed.selected(second.id))
            XCTAssertNil(reconstructed.selected(nil))
            XCTAssertEqual(reconstructed.selected(first.id)?.windows.first?.remainingPercent, 0)
        }
    }
    func testAbsentCacheGenerationSwitchAndLateWriteAreUnavailable() throws {
        try sandbox { _, cache in
            let selected = try account()
            XCTAssertNil(cache.selected(selected.id))
            let old = try snapshot(cache, [selected])
            try cache.save(old)
            _ = try cache.files.invalidate()
            XCTAssertNil(cache.selected(selected.id))
            XCTAssertThrowsError(try cache.save(old))
            XCTAssertNil(cache.selected(selected.id))
            try cache.save(snapshot(cache, [try account()]))
            XCTAssertNil(cache.selected(selected.id))
        }
    }
    func testMissingWindowIsNotFirstWindowAndOriginalTimesAndNullZeroSurvive() throws {
        try sandbox { _, cache in
            let zero = try account(), unknown = try account(remaining: nil), unavailable = try account(remaining: 92, state: .error)
            try cache.save(snapshot(cache, [zero, unknown, unavailable]))
            let value = try XCTUnwrap(cache.load())
            XCTAssertNil(value.window(account: zero.id, windowID: "secondary"))
            XCTAssertEqual(value.window(account: zero.id, windowID: "primary")?.remainingPercent, 0)
            XCTAssertNil(value.window(account: unknown.id, windowID: "primary")?.remainingPercent)
            XCTAssertNil(value.window(account: unavailable.id, windowID: "primary")?.remainingPercent)
            XCTAssertEqual(value.account(zero.id)?.observedAt, observed)
            XCTAssertEqual(value.generatedAt, observed)
            XCTAssertEqual(value.window(account: zero.id, windowID: "primary")?.resetsAt, observed.addingTimeInterval(3600))
            XCTAssertTrue(try XCTUnwrap(value.account(zero.id)).reading.isStale(at: observed.addingTimeInterval(901)))
        }
    }
    func testSanitizedAllowlistBoundsAndLegacyUniqueProviderRule() throws {
        try sandbox { _, cache in
            let a = try account(), b = try account()
            let data = try snapshot(cache, [a, b]).encoded()
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertFalse(text.contains("private")); XCTAssertFalse(text.contains("credential"))
            XCTAssertFalse(text.contains("message")); XCTAssertFalse(text.contains("name"))
            XCTAssertEqual(try AccountSurfaceSnapshot.decode(data).accounts.count, 2)
            let duplicate = try snapshot(cache, [a, a])
            XCTAssertThrowsError(try duplicate.encoded())
            let legacy = Snapshot(schemaVersion: 1, generatedAt: observed, demo: false, providers: [a.reading, b.reading])
            XCTAssertThrowsError(try Snapshot.decode(legacy.encoded()))
            let projected = try snapshot(cache, [a, b]).legacyProjection
            XCTAssertEqual(try Snapshot.decode(projected.encoded()).providers.count, 1)
            for level in ["root", "account", "window"] {
                var root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                var accounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
                switch level {
                case "root": root["email"] = "private@example.invalid"
                case "account": accounts[0]["name"] = "private@example.invalid"; root["accounts"] = accounts
                default:
                    var windows = try XCTUnwrap(accounts[0]["windows"] as? [[String: Any]])
                    windows[0]["token"] = "private"; accounts[0]["windows"] = windows; root["accounts"] = accounts
                }
                XCTAssertThrowsError(try AccountSurfaceSnapshot.decode(JSONSerialization.data(withJSONObject: root)))
            }
            XCTAssertThrowsError(try AccountSurfaceSnapshot.decode(Data(repeating: 32, count: 256 * 1024 + 1)))
            XCTAssertThrowsError(try account(remaining: 101))
            XCTAssertThrowsError(try AccountSurfaceSnapshot.Account(id: UUID(), reading: Snapshot.preview.providers[0]))
        }
    }
    func testWatchPublisherRestartDelayedTransferAndAuthoritySwitch() throws {
        try sandbox { root, cache in
            let state = root.appendingPathComponent("publisher")
            let inbox = AccountSurfaceInbox(cache: cache, cursorURL: root.appendingPathComponent("cursor"))
            let a = try account(), b = try account()
            let old = try AccountSurfacePublisher(stateURL: state).next(snapshot: snapshot(cache, [a]))
            let latest = try AccountSurfacePublisher(stateURL: state).next(snapshot: snapshot(cache, [b]))
            try inbox.receive(latest)
            let reconstructed = AccountSurfaceInbox(cache: cache, cursorURL: inbox.cursorURL)
            XCTAssertEqual(reconstructed.load()?.account(b.id)?.id, b.id)
            XCTAssertThrowsError(try reconstructed.receive(old))
            XCTAssertNil(reconstructed.load()?.account(a.id))
            let clear = try AccountSurfacePublisher(stateURL: state).next(snapshot: nil)
            try reconstructed.receive(clear)
            XCTAssertNil(reconstructed.load())
            XCTAssertThrowsError(try reconstructed.receive(latest))
            XCTAssertNil(reconstructed.load())
            let foreign = try AccountSurfacePublisher(stateURL: root.appendingPathComponent("other-publisher")).next(snapshot: snapshot(cache, [a]))
            XCTAssertThrowsError(try reconstructed.receive(foreign))
            XCTAssertNil(reconstructed.load())
            try reconstructed.trustPairedPublisher(foreign)
            XCTAssertNotNil(reconstructed.load()?.account(a.id))
            XCTAssertThrowsError(try reconstructed.receive(clear))
            XCTAssertThrowsError(try reconstructed.trustPairedPublisher(foreign))
            XCTAssertNotNil(reconstructed.load()?.account(a.id))
        }
    }
    func testFailedWatchWriteFencesPreviouslyReadableDiskAfterRestart() throws {
        try sandbox { root, cache in
            let publisher = AccountSurfacePublisher(stateURL: root.appendingPathComponent("publisher"))
            let inbox = AccountSurfaceInbox(cache: cache, cursorURL: root.appendingPathComponent("cursor"))
            let a = try account()
            let old = try publisher.next(snapshot: snapshot(cache, [a]))
            try inbox.receive(old)
            XCTAssertNotNil(inbox.load()?.account(a.id))
            // A non-directory cache path reliably fails writes even as root.
            try FileManager.default.removeItem(at: cache.directory)
            try Data().write(to: cache.directory)
            let next = try publisher.next(snapshot: snapshot(cache, [a]))
            XCTAssertThrowsError(try inbox.receive(next))
            let restarted = AccountSurfaceInbox(cache: cache, cursorURL: inbox.cursorURL)
            XCTAssertNil(restarted.load())
            XCTAssertThrowsError(try restarted.receive(old))
            try FileManager.default.removeItem(at: cache.directory)
            try restarted.receive(publisher.next(snapshot: snapshot(cache, [a])))
            XCTAssertNotNil(restarted.load()?.account(a.id))
        }
    }
    func testFailedNamespaceTransitionCannotRestoreReadableOldWatchQuota() throws {
        if getuid() == 0 { throw XCTSkip("Permission denial requires a non-root process") }
        try sandbox { root, _ in
            let authority = root.appendingPathComponent("authority")
            try FileManager.default.createDirectory(at: authority, withIntermediateDirectories: true)
            let files = CacheFiles(manifestURL: authority.appendingPathComponent("generation"))
            _ = try files.invalidate()
            let cache = AccountSurfaceCache(files: files, directory: root.appendingPathComponent("readings"))
            let inbox = AccountSurfaceInbox(cache: cache, cursorURL: root.appendingPathComponent("cursor"))
            let publisher = AccountSurfacePublisher(stateURL: root.appendingPathComponent("publisher"))
            let a = try account()
            try inbox.receive(publisher.next(snapshot: snapshot(cache, [a])))
            XCTAssertNotNil(inbox.load()?.account(a.id))
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: authority.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authority.path) }
            XCTAssertThrowsError(try inbox.receive(publisher.next(snapshot: nil)))
            // Old data and its namespace really remain readable. The independent
            // committed receive fence, not cleanup, prevents rollback after restart.
            XCTAssertNotNil(cache.selected(a.id))
            let restarted = AccountSurfaceInbox(cache: cache, cursorURL: inbox.cursorURL)
            XCTAssertNil(restarted.load())
            XCTAssertNil(restarted.loadLegacy())
        }
    }
    func testCorruptAuthorityDoesNotResetTrust() throws {
        try sandbox { root, cache in
            let inbox = AccountSurfaceInbox(cache: cache, cursorURL: root.appendingPathComponent("cursor"))
            try Data("broken".utf8).write(to: inbox.cursorURL)
            let data = try AccountSurfacePublisher(stateURL: root.appendingPathComponent("publisher")).next(snapshot: snapshot(cache, [try account()]))
            XCTAssertThrowsError(try inbox.receive(data)); XCTAssertNil(inbox.load())
        }
    }
    func testBridgeCompatibilityIsExplicitAndNeverUUIDSelectionFallback() throws {
        try sandbox { root, cache in
            let publisher = AccountSurfacePublisher(stateURL: root.appendingPathComponent("publisher"))
            let inbox = AccountSurfaceInbox(cache: cache, cursorURL: root.appendingPathComponent("cursor"))
            let a = try account()
            let bridge = Snapshot(schemaVersion: 1, generatedAt: observed, demo: false, providers: [a.reading])
            let legacy = try publisher.next(snapshot: nil, legacy: bridge)
            try inbox.receive(legacy)
            XCTAssertEqual(inbox.loadLegacy(), bridge.sanitized)
            XCTAssertNil(inbox.load())
            XCTAssertNil(cache.selected(a.id))
            try inbox.receive(publisher.next(snapshot: snapshot(cache, [a])))
            XCTAssertNotNil(inbox.load()?.account(a.id))
            XCTAssertNil(inbox.loadLegacy())
            XCTAssertThrowsError(try inbox.receive(legacy))
            try inbox.receive(publisher.next(snapshot: nil))
            XCTAssertNil(inbox.load()); XCTAssertNil(inbox.loadLegacy())
            // Demo/unsanitized legacy bytes cannot hide arbitrary properties in
            // the otherwise strict v3 envelope. Old v1 decoding is unchanged.
            let bad = AccountSurfaceDelivery(publisher: UUID(), sequence: 1, snapshot: nil,
                                             legacy: try Snapshot.preview.encoded())
            XCTAssertThrowsError(try bad.encoded())
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bridge.sanitized.encoded()) as? [String: Any])
            root["email"] = "private@example.invalid"
            let injected = AccountSurfaceDelivery(publisher: UUID(), sequence: 1, snapshot: nil,
                legacy: try JSONSerialization.data(withJSONObject: root))
            XCTAssertThrowsError(try injected.encoded())
        }
    }
    func testDeepLinksAreUUIDScopedNotAnAccountFallback() {
        let id = UUID()
        XCTAssertEqual(AccountSurfaceSnapshot.accountID(from: AccountSurfaceSnapshot.deepLink(id)), id)
        for text in ["quotadock://account/not-a-uuid", "https://account/\(id)", "quotadock://account/\(id)?email=x", "quotadock://account/\(id)/extra"] {
            XCTAssertNil(AccountSurfaceSnapshot.accountID(from: URL(string: text)!))
        }
    }
}
