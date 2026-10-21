import XCTest
#if canImport(QuotaDockStorage)
@testable import QuotaDockStorage
#else
@testable import QuotaDock
#endif

final class ConnectionStorageTests: XCTestCase {
    func testPrivateAccountLabels() throws {
        let suite = "QuotaDock-label-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let labels = CloudAccountLabels(defaults: defaults)
        let authority = UUID(), slot = UUID()
        let a = CloudAccountLabels.scope(server: URL(string: "https://one.example")!, authority: authority)
        let b = CloudAccountLabels.scope(server: URL(string: "https://two.example")!, authority: authority)
        let c = CloudAccountLabels.scope(server: URL(string: "https://one.example")!, authority: UUID())
        XCTAssertTrue(labels.set("  work@example.test  ", scope: a, slot: slot))
        let reopened = CloudAccountLabels(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reopened.label(scope: a, slot: slot), "work@example.test")
        XCTAssertEqual(reopened.label(scope: b, slot: slot), "")
        XCTAssertEqual(reopened.label(scope: c, slot: slot), "")
        XCTAssertEqual(reopened.label(scope: a, slot: UUID()), "")
        XCTAssertTrue(labels.set(String(repeating: "한", count: 200), scope: a, slot: slot))
        XCTAssertEqual(labels.label(scope: a, slot: slot).count, 120)
        XCTAssertTrue(labels.set("\n\t  ", scope: a, slot: slot))
        XCTAssertEqual(reopened.label(scope: a, slot: slot), "")
        XCTAssertTrue(labels.set("a\n\u{202E}b", scope: a, slot: slot))
        XCTAssertEqual(labels.label(scope: a, slot: slot), "ab")
        let otherSlots = (1..<CloudAccountLabels.maximumEntries).map { _ in UUID() }
        for id in otherSlots {
            XCTAssertTrue(labels.set("name", scope: a, slot: id))
        }
        XCTAssertFalse(labels.set("overflow", scope: b, slot: slot))
        XCTAssertTrue(labels.set("updated", scope: a, slot: slot))
        XCTAssertTrue(labels.set("", scope: a, slot: slot))
        XCTAssertTrue(labels.set("room again", scope: b, slot: slot))
        labels.remove(scope: a)
        XCTAssertEqual(reopened.label(scope: a, slot: slot), "")
        XCTAssertEqual(reopened.label(scope: a, slot: otherSlots[0]), "")
        XCTAssertEqual(reopened.label(scope: b, slot: slot), "room again")
        XCTAssertTrue(labels.set("new name", scope: c, slot: slot))
    }

    private var root: URL!
    private var files: CacheFiles!
    private let ownerA = Data("synthetic-cloud-A".utf8)
    private let ownerB = Data("synthetic-bridge-B".utf8)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        files = CacheFiles(manifestURL: root.appendingPathComponent("generation"))
    }
    override func tearDownWithError() throws {
        // Restore only this disposable directory if an assertion interrupted a
        // permission-failure test; never alter an application or shared cache.
        let payloads = root.appendingPathComponent("payloads")
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloads.path)
        try FileManager.default.removeItem(at: root)
    }

    private func storage(_ read: @escaping () throws -> Data,
                         _ write: @escaping (Data) throws -> Void) -> ConnectionStorage {
        ConnectionStorage(files: files, read: read, write: write)
    }

    func testLogoutAndBothSwitchDirectionsSurviveUndeletedOldPayloads() throws {
        let transitions: [(ConnectionRecord.Mode, ConnectionRecord.Mode)] = [
            (.cloud, .bridge), (.bridge, .cloud), (.cloud, .signedOut), (.bridge, .signedOut)
        ]
        for (first, second) in transitions {
            var bytes = Data()
            let store = storage({ bytes }, { bytes = $0 })
            let old = try store.select(first, credential: ownerA)
            let payloads = root.appendingPathComponent("payloads")
            try files.save(ownerA, kind: .snapshot, in: payloads, generation: old.generation, maximumBytes: 256)
            let next = try store.select(second, credential: second == .signedOut ? nil : ownerB)
            XCTAssertNotEqual(next.generation, old.generation)
            XCTAssertEqual(try Data(contentsOf: files.file(.snapshot, in: payloads, generation: old.generation)), ownerA)
            XCTAssertThrowsError(try files.read(.snapshot, in: payloads, maximumBytes: 256))
            let restarted = storage({ bytes }, { bytes = $0 })
            XCTAssertEqual(try restarted.current().mode, second)
            XCTAssertEqual(try restarted.current().credential, second == .signedOut ? nil : ownerB)
            XCTAssertThrowsError(try files.save(ownerA, kind: .snapshot, in: payloads, generation: old.generation, maximumBytes: 256))
            if second != .signedOut {
                try files.save(ownerB, kind: .snapshot, in: payloads, generation: next.generation, maximumBytes: 256)
                XCTAssertEqual(try files.read(.snapshot, in: payloads, maximumBytes: 256).data, ownerB)
            }
        }
    }

    func testInterruptedOrFailedAuthorityCommitNeverRepairsMismatch() throws {
        var bytes = Data()
        let original = storage({ bytes }, { bytes = $0 })
        let old = try original.select(.cloud, credential: ownerA)
        let oldBytes = bytes
        let failed = storage({ bytes }, { _ in throw SnapshotError.unpaired })
        XCTAssertThrowsError(try failed.select(.bridge, credential: ownerB))
        XCTAssertEqual(bytes, oldBytes, "Replacement failure must preserve previous credential bytes")
        XCTAssertThrowsError(try failed.current())
        XCTAssertThrowsError(try original.current())
        let restarted = storage({ bytes }, { bytes = $0 })
        XCTAssertThrowsError(try restarted.current())
        XCTAssertNotEqual(try files.generation(), old.generation)
        let recovered = try restarted.select(.bridge, credential: ownerB)
        XCTAssertEqual(try restarted.current().generation, recovered.generation)
    }

    func testLateRenewalCannotRestoreLoggedOutSwitchedOrReconnectedAuthority() throws {
        for destination in [ConnectionRecord.Mode.signedOut, .bridge, .cloud] {
            var bytes = Data()
            let store = storage({ bytes }, { bytes = $0 })
            let old = try store.select(.cloud, credential: ownerA)
            let next = try store.select(destination, credential: destination == .signedOut ? nil : ownerB)
            let committed = bytes
            XCTAssertThrowsError(try store.updateCloud(Data("late-renewal-A".utf8), expected: ownerA, generation: old.generation))
            XCTAssertEqual(bytes, committed)
            XCTAssertEqual(try store.current().generation, next.generation)
            XCTAssertEqual(try store.current().mode, destination)
        }
    }

    func testRenewalKeepsCacheGenerationAndRequiresExactCurrentCredential() throws {
        var bytes = Data()
        let store = storage({ bytes }, { bytes = $0 })
        let old = try store.select(.cloud, credential: ownerA)
        try files.save(ownerA, kind: .cloud, in: root, generation: old.generation, maximumBytes: 256)
        try store.updateCloud(ownerB, expected: ownerA, generation: old.generation)
        XCTAssertEqual(try store.current().credential, ownerB)
        XCTAssertEqual(try store.current().generation, old.generation)
        XCTAssertEqual(try files.read(.cloud, in: root, maximumBytes: 256).data, ownerA)
        XCTAssertThrowsError(try store.updateCloud(ownerA, expected: ownerA, generation: old.generation))
        try store.rejectCloud(expected: ownerB, generation: old.generation)
        XCTAssertEqual(try store.current().mode, .signedOut)
        XCTAssertEqual(try files.read(.cloud, in: root, maximumBytes: 256).data, ownerA)
    }

    func testUnreadableMalformedLegacyOrMissingStateNeverSelectsFallback() throws {
        var bytes = Data()
        let store = storage({ bytes }, { bytes = $0 })
        XCTAssertThrowsError(try store.current())
        _ = try files.invalidate()
        for malformed in [Data(), Data("{}".utf8), Data("legacy credential".utf8), Data(repeating: 32, count: 12289)] {
            bytes = malformed
            XCTAssertThrowsError(try store.current())
        }
        _ = try store.select(.bridge, credential: ownerB)
        let unreadable = storage({ throw SnapshotError.unpaired }, { bytes = $0 })
        XCTAssertThrowsError(try unreadable.current())
        try Data("not a generation".utf8).write(to: files.manifestURL, options: .atomic)
        XCTAssertThrowsError(try store.current())
    }

    func testMalformedDestinationDoesNotFenceUsableAuthority() throws {
        var bytes = Data()
        let store = storage({ bytes }, { bytes = $0 })
        let old = try store.select(.bridge, credential: ownerB)
        for (mode, credential) in [(ConnectionRecord.Mode.cloud, nil), (.bridge, Data()), (.signedOut, ownerA)] {
            XCTAssertThrowsError(try store.select(mode, credential: credential))
            XCTAssertEqual(try store.current().generation, old.generation)
        }
    }

    func testFailedRejectionQuarantinesRestartRatherThanRestoringRejectedCredential() throws {
        var bytes = Data()
        let store = storage({ bytes }, { bytes = $0 })
        let old = try store.select(.cloud, credential: ownerA)
        let failed = storage({ bytes }, { _ in throw SnapshotError.unpaired })
        XCTAssertThrowsError(try failed.rejectCloud(expected: ownerA, generation: old.generation))
        XCTAssertThrowsError(try failed.current())
        XCTAssertThrowsError(try storage({ bytes }, { bytes = $0 }).current())
    }

    func testFailedFirstDurableWriteDoesNotClaimLogoutOrReplacePreviousCredential() throws {
        #if os(Linux)
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires a non-root process") }
        #endif
        var bytes = Data()
        let store = storage({ bytes }, { bytes = $0 })
        let old = try store.select(.cloud, credential: ownerA)
        let original = bytes
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try store.select(.signedOut))
        XCTAssertEqual(bytes, original)
        XCTAssertThrowsError(try store.current())
        // No successful durable write means restart cannot remember the failed
        // intent. The UI must report UNCONFIRMED, never successful sign-out.
        let restarted = storage({ bytes }, { bytes = $0 })
        XCTAssertEqual(try restarted.current().generation, old.generation)
        XCTAssertEqual(try restarted.current().mode, .cloud)
    }

    func testUnknownWriteOutcomeKeepsProcessBlockedAndRestartSelectsOnlyCommittedDestination() throws {
        var bytes = Data()
        let store = storage({ bytes }, { bytes = $0 })
        _ = try store.select(.cloud, credential: ownerA)
        let uncertain = storage({ bytes }, { bytes = $0; throw SnapshotError.unpaired })
        XCTAssertThrowsError(try uncertain.select(.bridge, credential: ownerB))
        XCTAssertThrowsError(try uncertain.current())
        let restarted = storage({ bytes }, { bytes = $0 })
        XCTAssertEqual(try restarted.current().mode, .bridge)
        XCTAssertEqual(try restarted.current().credential, ownerB)
    }

    func testCacheSizeBoundaryRetainsPreviousPayloadAndRejectsOversizedDiskData() throws {
        let current = try files.invalidate()
        let limit = 256 * 1024
        let usable = Data(repeating: 42, count: limit)
        try files.save(usable, kind: .cloud, in: root, generation: current, maximumBytes: limit)
        XCTAssertEqual(try files.read(.cloud, in: root, maximumBytes: limit).data, usable)
        let oversized = Data(repeating: 91, count: limit + 1)
        XCTAssertThrowsError(try files.save(oversized, kind: .cloud, in: root, generation: current, maximumBytes: limit))
        XCTAssertEqual(try files.read(.cloud, in: root, maximumBytes: limit).data, usable)
        try oversized.write(to: files.file(.cloud, in: root, generation: current), options: .atomic)
        XCTAssertThrowsError(try files.read(.cloud, in: root, maximumBytes: limit))
    }

    func testRepeatedCacheReplacementCleansObsoleteSnapshotsButPreservesCurrentAndOtherFiles() throws {
        let unrelated = root.appendingPathComponent("snapshot-unrelated.json")
        try ownerA.write(to: unrelated)
        let first = try files.invalidate()
        try files.save(ownerA, kind: .cloud, in: root, generation: first, maximumBytes: 256)
        for _ in 0..<10 {
            let next = try files.invalidate()
            try files.save(ownerB, kind: .snapshot, in: root, generation: next, maximumBytes: 256)
        }
        let current = try files.generation()
        try files.removeInactive(.snapshot, in: root)
        try files.removeInactive(.snapshot, in: root)
        XCTAssertEqual(try files.read(.snapshot, in: root, maximumBytes: 256).data, ownerB)
        XCTAssertEqual(try Data(contentsOf: unrelated), ownerA)
        XCTAssertEqual(try Data(contentsOf: files.file(.cloud, in: root, generation: first)), ownerA)
        let remaining = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("snapshot-") && $0 != unrelated.lastPathComponent }
        XCTAssertEqual(remaining, [files.file(.snapshot, in: root, generation: current).lastPathComponent])
    }

    func testReadableUndeletableCacheIsExcludedByDurableFence() throws {
        #if os(Linux)
        guard geteuid() != 0 else { throw XCTSkip("Permission denial requires a non-root process") }
        #endif
        let old = try files.invalidate()
        let payloads = root.appendingPathComponent("payloads")
        try files.save(ownerA, kind: .snapshot, in: payloads, generation: old, maximumBytes: 256)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: payloads.path)
        let next = try files.invalidate()
        XCTAssertThrowsError(try files.remove(.snapshot, in: payloads, generation: old))
        XCTAssertThrowsError(try files.removeInactive(.snapshot, in: payloads))
        XCTAssertEqual(try Data(contentsOf: files.file(.snapshot, in: payloads, generation: old)), ownerA)
        XCTAssertThrowsError(try CacheFiles(manifestURL: files.manifestURL).read(.snapshot, in: payloads, maximumBytes: 256))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: payloads.path)
        try files.save(ownerB, kind: .snapshot, in: payloads, generation: next, maximumBytes: 256)
        try files.removeInactive(.snapshot, in: payloads)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.file(.snapshot, in: payloads, generation: old).path))
        XCTAssertEqual(try files.read(.snapshot, in: payloads, maximumBytes: 256).data, ownerB)
        XCTAssertThrowsError(try files.remove(.snapshot, in: payloads, generation: next))
    }
}
