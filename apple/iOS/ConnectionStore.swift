import Foundation
import Security

enum ConnectionStore {
    private(set) static var cleanupComplete = true
    private static let storage: ConnectionStorage? = {
        guard let files = SnapshotStore.files else { return nil }
        return ConnectionStorage(files: files, read: ConnectionKeychain.read, write: ConnectionKeychain.write)
    }()

    static func current() throws -> ConnectionRecord {
        guard let storage else { throw SnapshotError.unpaired }
        return try storage.current()
    }

    @discardableResult
    static func select(_ mode: ConnectionRecord.Mode, credential: Data? = nil) throws -> UUID {
        guard let storage else { throw SnapshotError.unpaired }
        if mode == .bridge {
            guard let credential else { throw SnapshotError.invalid }
            try JSONDecoder().decode(Pairing.self, from: credential).validate()
        } else if mode == .cloud {
            guard let credential else { throw SnapshotError.invalid }
            try JSONDecoder().decode(CloudSession.self, from: credential).validate()
        }
        let next: ConnectionRecord
        do { next = try storage.select(mode, credential: credential) }
        catch {
            SnapshotStore.blocked = storage.isBlocked
            cleanupComplete = false
            throw error
        }
        SnapshotStore.blocked = false
        // Cleanup cannot select a connection. Inactive generations and legacy
        // credential items are never a recovery/fallback source.
        let bridgeRemoved = PairingStore.removeLegacy()
        let cloudRemoved = CloudSessionStore.removeLegacy()
        var removed = bridgeRemoved && cloudRemoved
        if let group = SnapshotStore.groupURL {
            removed = removeFile(group.appendingPathComponent("snapshot.json")) && removed
        }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            removed = removeFile(caches.appendingPathComponent("QuotaDock-cloud-snapshot.json")) && removed
        }
        removed = cleanup(.snapshot, in: SnapshotStore.directory) && removed
        removed = cleanup(.accounts, in: SnapshotStore.directory) && removed
        removed = cleanup(.cloud, in: CloudCache.directory) && removed
        cleanupComplete = removed
        return next.generation
    }

    private static func cleanup(_ kind: CacheFiles.Kind, in directory: URL?) -> Bool {
        guard let directory, let files = SnapshotStore.files else { return false }
        do {
            try files.removeInactive(kind, in: directory)
            return true
        } catch { return false }
    }

    private static func removeFile(_ url: URL) -> Bool {
        do { try FileManager.default.removeItem(at: url); return true }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return true }
        catch { return false }
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    static func assertBridge(_ pairing: Pairing, generation: UUID) throws {
        let record = try current()
        guard record.mode == .bridge, record.generation == generation, let data = record.credential else {
            throw SnapshotError.unpaired
        }
        let saved = try JSONDecoder().decode(Pairing.self, from: data)
        guard saved.endpoint == pairing.endpoint, saved.token == pairing.token else { throw SnapshotError.unpaired }
    }

    static func assertCloud(_ session: CloudSession, generation: UUID?) throws {
        let record = try current()
        guard record.mode == .cloud, record.generation == generation, let data = record.credential else {
            throw SnapshotError.unpaired
        }
        let saved = try JSONDecoder().decode(CloudSession.self, from: data)
        try saved.validate()
        guard saved.sameAuthority(as: session), saved.token == session.token else { throw SnapshotError.unpaired }
    }

    static func renew(_ next: CloudSession, replacing old: CloudSession, generation: UUID?) throws {
        try next.validate()
        guard next.sameAuthority(as: old), let storage, let generation else { throw SnapshotError.unpaired }
        try storage.updateCloud(encoded(next), expected: encoded(old), generation: generation)
    }

    static func reject(_ old: CloudSession, generation: UUID?) throws {
        guard let storage, let generation else { throw SnapshotError.unpaired }
        do { try storage.rejectCloud(expected: encoded(old), generation: generation) }
        catch {
            SnapshotStore.blocked = storage.isBlocked
            throw error
        }
    }
}

enum ConnectionKeychain {
    private static var query: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "QuotaDock.connection.v1", kSecAttrAccount as String: "authority"]
        // Reuse the existing phone-only cloud group; no widget/Watch grant.
        if let group = Bundle.main.object(forInfoDictionaryKey: "CloudKeychainGroup") as? String {
            result[kSecAttrAccessGroup as String] = group
        }
        return result
    }

    static func read() throws -> Data {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count <= 12288 else { throw SnapshotError.unpaired }
        return data
    }

    static func write(_ data: Data) throws {
        try write(data, update: SecItemUpdate, add: SecItemAdd)
    }

    static func write(_ data: Data,
                      update: (CFDictionary, CFDictionary) -> OSStatus,
                      add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus) throws {
        _ = try ConnectionRecord.decode(data)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard add(item as CFDictionary, nil) == errSecSuccess else { throw SnapshotError.unpaired }
        } else if status != errSecSuccess { throw SnapshotError.unpaired }
    }
}
