import XCTest
import Security
@testable import QuotaDock

// Uses the hosted app's real Keychain groups and App Group, never injected
// credential storage. Run only on a disposable simulator: this replaces its
// selected connection. verify-persistence.py runs each phase in a new process.
final class NativePersistenceTests: XCTestCase {
    private let phases = ["seed", "bridge", "cloud", "renewed", "rejected",
                          "bridge-again", "cloud-again", "switched-bridge", "signed-out", "interrupted"]
    private var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("native-persistence-verification.json")
    }
    // Only verification metadata (generations/PID), never credential storage.
    // XCTest can terminate a short phase before UserDefaults flushes its writes.
    private var state: [String: String] {
        get {
            guard let data = try? Data(contentsOf: stateURL) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            do {
                try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(newValue).write(to: stateURL, options: .atomic)
            } catch { XCTFail("Could not persist verification metadata: \(error)") }
        }
    }
    private let bridge = try! Pairing(baseURL: "https://bridge.example.invalid", token: "synthetic-bridge-only")
    private var cloud: CloudSession {
        CloudSession(baseURL: URL(string: "https://cloud.example.invalid")!,
                     token: String(repeating: "a", count: 43), expiresAt: Date(timeIntervalSince1970: 4102444800),
                     refreshToken: String(repeating: "b", count: 43),
                     familyId: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                     refreshExpiresAt: Date(timeIntervalSince1970: 4102531200))
    }
    private var renewed: CloudSession {
        CloudSession(baseURL: cloud.baseURL, token: String(repeating: "c", count: 43),
                     expiresAt: cloud.expiresAt, refreshToken: String(repeating: "d", count: 43),
                     familyId: cloud.familyId, refreshExpiresAt: cloud.refreshExpiresAt)
    }
    private var otherCloud: CloudSession {
        CloudSession(baseURL: cloud.baseURL, token: String(repeating: "e", count: 43),
                     expiresAt: cloud.expiresAt, refreshToken: String(repeating: "f", count: 43),
                     familyId: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
                     refreshExpiresAt: cloud.refreshExpiresAt)
    }
    private var observations: CloudSnapshot {
        get throws {
            try CloudSnapshot.decode(Data("""
            {"schemaVersion":2,"generatedAt":"2026-10-13T10:30:00.999Z","demo":false,"accounts":[
              {"accountId":"11111111-1111-4111-8111-111111111111","provider":"codex","name":"private label","plan":"ChatGPT Pro","state":"available","source":"codexbar","observedAt":"2026-10-13T10:00:00.123Z","windows":[{"id":"primary","label":"Session","remainingPercent":73,"resetsAt":null}],"lastError":null},
              {"accountId":"22222222-2222-4222-8222-222222222222","provider":"grok","name":"Grok","plan":null,"state":"unavailable","source":"codexbar","observedAt":null,"windows":[{"id":"primary","label":"Session","remainingPercent":null,"resetsAt":null}],"lastError":"private diagnostic"}
            ]}
            """.utf8))
        }
    }

    func testProductionPersistence() throws {
        #if targetEnvironment(simulator)
        let phase = ProcessInfo.processInfo.environment["QUOTADOCK_PERSISTENCE_PHASE"]
        if let phase {
            XCTAssertTrue(phases.contains(phase))
            if phase != "seed" {
                let previousPID = try XCTUnwrap(state["pid"], "A preceding process must have committed this phase's metadata")
                XCTAssertNotEqual(previousPID, String(ProcessInfo.processInfo.processIdentifier),
                                  "The relaunch runner must start a new host process")
            }
            try exercise(phase)
            state["pid"] = String(ProcessInfo.processInfo.processIdentifier)
            print("PERSISTENCE phase=\(phase) pid=\(ProcessInfo.processInfo.processIdentifier) passed")
        } else {
            let language = DockL10n.preferences.object(forKey: DockL10n.languageKey)
            let refresh = UserDefaults.standard.object(forKey: RefreshSettings.foregroundKey)
            defer {
                _ = try? ConnectionStore.select(.signedOut)
                try? FileManager.default.removeItem(at: stateURL)
                DockL10n.preferences.set(language, forKey: DockL10n.languageKey)
                UserDefaults.standard.set(refresh, forKey: RefreshSettings.foregroundKey)
            }
            for phase in phases { try exercise(phase) }
        }
        #else
        throw XCTSkip("Synthetic authority replacement is simulator-only")
        #endif
    }

    private func exercise(_ phase: String) throws {
        let files = try XCTUnwrap(SnapshotStore.files, "Host must retain its real App Group entitlement")
        switch phase {
        case "seed":
            UserDefaults.standard.set(false, forKey: RefreshSettings.foregroundKey)
            state = [:]
            let status = SecItemDelete(query(service: "QuotaDock.connection.v1", account: "authority") as CFDictionary)
            XCTAssertTrue([errSecSuccess, errSecItemNotFound].contains(status))
            XCTAssertThrowsError(try ConnectionKeychain.read())
            try PairingStore.save(bridge) // exercises SecItemAdd, not just update
            state["bridge-generation"] = try ConnectionStore.current().generation.uuidString
            DockL10n.save(.en)
            try publish()
        case "bridge":
            try assertSelected(.bridge)
            XCTAssertEqual(try PairingStore.load().token, bridge.token)
            XCTAssertNil(CloudSessionStore.load())
            try assertObservations(language: .en)
            let old = try generation("bridge-generation")
            _ = try ConnectionStore.select(.cloud, credential: CloudSessionStore.encoded(cloud))
            state["cloud-generation"] = try ConnectionStore.current().generation.uuidString
            try assertFenced(old)
            try publish()
        case "cloud":
            try assertSelected(.cloud)
            XCTAssertEqual(try CloudSessionStore.encoded(XCTUnwrap(CloudSessionStore.load())),
                           try CloudSessionStore.encoded(cloud))
            XCTAssertThrowsError(try PairingStore.load())
            try assertObservations(language: .en)
            XCTAssertThrowsError(try ConnectionStore.assertBridge(bridge, generation: generation("bridge-generation")))
            try ConnectionStore.renew(renewed, replacing: cloud, generation: generation("cloud-generation"))
            XCTAssertEqual(SnapshotStore.generation, try generation("cloud-generation"))
            DockL10n.save(.ko)
        case "renewed":
            try assertSelected(.cloud)
            XCTAssertEqual(try CloudSessionStore.encoded(XCTUnwrap(CloudSessionStore.load())),
                           try CloudSessionStore.encoded(renewed))
            try assertObservations(language: .ko)
            let current = try generation("cloud-generation")
            XCTAssertThrowsError(try ConnectionStore.assertCloud(cloud, generation: current))
            try ConnectionStore.assertCloud(renewed, generation: current)
            try ConnectionStore.reject(renewed, generation: current)
        case "rejected":
            try assertSelected(.signedOut)
            XCTAssertNil(CloudSessionStore.load())
            XCTAssertThrowsError(try PairingStore.load())
            try assertObservations(language: .ko) // rejection retains usable observations
            XCTAssertThrowsError(try ConnectionStore.renew(renewed, replacing: cloud,
                                                          generation: generation("cloud-generation")))
            try PairingStore.save(bridge)
            state["second-bridge-generation"] = try ConnectionStore.current().generation.uuidString
            try assertFenced(generation("cloud-generation"))
            try publish()
        case "bridge-again":
            try assertSelected(.bridge)
            XCTAssertEqual(try PairingStore.load().token, bridge.token)
            try assertObservations(language: .ko)
            _ = try ConnectionStore.select(.cloud, credential: CloudSessionStore.encoded(otherCloud))
            state["second-cloud-generation"] = try ConnectionStore.current().generation.uuidString
            try assertFenced(generation("second-bridge-generation"))
            try publish()
        case "cloud-again":
            try assertSelected(.cloud)
            XCTAssertEqual(try CloudSessionStore.encoded(XCTUnwrap(CloudSessionStore.load())),
                           try CloudSessionStore.encoded(otherCloud))
            try assertObservations(language: .ko)
            XCTAssertThrowsError(try ConnectionStore.renew(renewed, replacing: cloud,
                                                          generation: generation("cloud-generation")))
            try PairingStore.save(bridge)
            state["third-bridge-generation"] = try ConnectionStore.current().generation.uuidString
            try assertFenced(generation("second-cloud-generation"))
            try publish()
        case "switched-bridge":
            try assertSelected(.bridge)
            XCTAssertEqual(try PairingStore.load().token, bridge.token)
            XCTAssertNil(CloudSessionStore.load())
            try assertObservations(language: .ko)
            XCTAssertThrowsError(try ConnectionStore.assertCloud(otherCloud,
                                                                 generation: generation("second-cloud-generation")))
            let current = try ConnectionStore.select(.cloud, credential: CloudSessionStore.encoded(otherCloud))
            try assertFenced(generation("third-bridge-generation"))
            try publish()
            _ = try ConnectionStore.select(.signedOut)
            try assertFenced(current)
        case "signed-out":
            try assertSelected(.signedOut)
            XCTAssertThrowsError(try PairingStore.load())
            XCTAssertNil(CloudSessionStore.load())
            XCTAssertNil(SnapshotStore.load())
            XCTAssertNil(CloudCache.load())
            // Real obsolete Keychain items must never be a fallback, even when
            // the selected authority is absent or the manifest is mismatched.
            try addLegacy(service: "QuotaDock.bridge", account: "pairing", group: "KeychainGroup",
                          data: ConnectionStore.encoded(bridge))
            try addLegacy(service: "QuotaDock.cloud.v2", account: "session", group: "CloudKeychainGroup",
                          data: CloudSessionStore.encoded(cloud))
            XCTAssertEqual(SecItemDelete(query(service: "QuotaDock.connection.v1", account: "authority") as CFDictionary), errSecSuccess)
            XCTAssertThrowsError(try ConnectionStore.current())
            XCTAssertThrowsError(try PairingStore.load())
            XCTAssertNil(CloudSessionStore.load())
            // Persist the exact state left by termination after fence advance,
            // before the union replacement; no in-memory blocked flag is used.
            try ConnectionKeychain.write(ConnectionRecord(generation: files.generation(), mode: .cloud,
                                                          credential: CloudSessionStore.encoded(cloud)).encoded())
            state["interrupted-generation"] = try files.invalidate().uuidString
        case "interrupted":
            let fence = try generation("interrupted-generation")
            XCTAssertEqual(try files.generation(), fence)
            XCTAssertThrowsError(try ConnectionStore.current())
            XCTAssertThrowsError(try PairingStore.load())
            XCTAssertNil(CloudSessionStore.load())
            XCTAssertNil(SnapshotStore.load())
            XCTAssertNil(CloudCache.load())
            XCTAssertEqual(try ConnectionRecord.decode(ConnectionKeychain.read()).mode, .cloud)
            XCTAssertEqual(try files.generation(), fence, "Reading must not repair the fence from obsolete authority")
            _ = try ConnectionStore.select(.signedOut)
            XCTAssertTrue(ConnectionStore.cleanupComplete)
            XCTAssertFalse(PairingStore.legacyExists)
            XCTAssertFalse(CloudSessionStore.legacyExists)
            try assertSelected(.signedOut)
            XCTAssertEqual(DockL10n.selection(), .ko)
        default: XCTFail("Unknown persistence phase: \(phase)")
        }
    }

    private func generation(_ name: String) throws -> UUID {
        try XCTUnwrap(state[name].flatMap(UUID.init(uuidString:)))
    }

    private func publish() throws {
        let current = try ConnectionStore.current().generation
        XCTAssertTrue(CloudCache.save(try observations, generation: current))
        try SnapshotStore.save(observations.smallSurfaceSnapshot, generation: current)
    }

    private func assertObservations(language: DockLanguage) throws {
        let saved = try XCTUnwrap(SnapshotStore.load())
        XCTAssertEqual(saved, try observations.smallSurfaceSnapshot.sanitized)
        XCTAssertFalse(saved.demo)
        XCTAssertEqual(saved.generatedAt.timeIntervalSince1970, 1791887400.999, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(saved.providers.first?.observedAt).timeIntervalSince1970, 1791885600.123, accuracy: 0.0001)
        XCTAssertTrue(saved.providers[0].isStale(at: Date(timeIntervalSince1970: 1791887401)))
        XCTAssertNil(saved.providers[1].observedAt)
        XCTAssertNil(saved.providers[1].displayWindows.first?.remainingPercent)
        XCTAssertEqual(saved.providers.map(\.source), [.codexbar, .codexbar])
        let full = try XCTUnwrap(CloudCache.load())
        XCTAssertEqual(full.accounts.map(\.observedAt), try observations.accounts.map(\.observedAt))
        XCTAssertEqual(DockL10n.selection(), language)
        var transfer = WatchTransfer()
        transfer.reconcile(phoneSnapshot: SnapshotStore.load())
        XCTAssertEqual(try Snapshot.decode(XCTUnwrap(transfer.pending)), saved)
        let bytes = try saved.encoded()
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(text.contains(bridge.token))
        XCTAssertFalse(text.contains(cloud.token))
    }

    private func assertFenced(_ old: UUID) throws {
        let files = try XCTUnwrap(SnapshotStore.files)
        XCTAssertNotEqual(try files.generation(), old)
        // Recreate physically retained obsolete files after cleanup. The fence,
        // not successful deletion, must prevent their use on the next launch.
        let shared = try XCTUnwrap(SnapshotStore.directory)
        let privateCache = try XCTUnwrap(CloudCache.directory)
        try observations.smallSurfaceSnapshot.encoded().write(to: files.file(.snapshot, in: shared, generation: old))
        try observations.cacheData().write(to: files.file(.cloud, in: privateCache, generation: old))
        XCTAssertThrowsError(try SnapshotStore.save(observations.smallSurfaceSnapshot, generation: old))
        XCTAssertFalse(CloudCache.save(try observations, generation: old))
        XCTAssertNil(SnapshotStore.load())
        XCTAssertNil(CloudCache.load())
    }

    private func assertSelected(_ mode: ConnectionRecord.Mode) throws {
        XCTAssertEqual(try ConnectionStore.current().mode, mode)
        var q = query(service: "QuotaDock.connection.v1", account: "authority")
        q[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(q as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        if mode == .signedOut { XCTAssertNil(try ConnectionStore.current().credential) }
    }

    private func query(service: String, account: String, group: String = "CloudKeychainGroup") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: Bundle.main.object(forInfoDictionaryKey: group) as! String]
    }

    private func addLegacy(service: String, account: String, group: String, data: Data) throws {
        var q = query(service: service, account: account, group: group)
        let removed = SecItemDelete(q as CFDictionary)
        XCTAssertTrue([errSecSuccess, errSecItemNotFound].contains(removed))
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        XCTAssertEqual(SecItemAdd(q as CFDictionary, nil), errSecSuccess)
    }
}
