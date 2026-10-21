import Foundation

enum RefreshSettings {
    static let foregroundKey = "foregroundAutoRefresh"
    static func foregroundEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: foregroundKey) == nil || defaults.bool(forKey: foregroundKey)
    }
}

enum SnapshotStore {
    static let maximumPayloadBytes = 256 * 1024
    // Phone-process quarantine when a requested persistent transition fails.
    // Other processes rely on the on-disk fence, not this memory flag.
    static var blocked = false
    static var groupURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }
    static var files: CacheFiles? {
        groupURL.map { CacheFiles(manifestURL: $0.appendingPathComponent("cache-generation")) }
    }
    static var directory: URL? { groupURL?.appendingPathComponent("QuotaDock-cache", isDirectory: true) }
    static var generation: UUID? { files.flatMap { try? $0.generation() } }

    static var accountCache: AccountSurfaceCache? {
        guard !blocked, let files, let directory else { return nil }
        return AccountSurfaceCache(files: files, directory: directory)
    }
    static var accountInbox: AccountSurfaceInbox? {
        guard let cache = accountCache, let groupURL else { return nil }
        return AccountSurfaceInbox(cache: cache, cursorURL: groupURL.appendingPathComponent("account-surface-cursor"))
    }
    static func loadAccounts() -> AccountSurfaceSnapshot? {
        #if os(watchOS)
        return accountInbox?.load()
        #else
        return accountCache?.load()
        #endif
    }
    static func saveAccounts(_ snapshot: AccountSurfaceSnapshot) throws {
        guard let cache = accountCache else { throw SnapshotError.invalid }
        try cache.save(snapshot)
        try? cache.files.removeInactive(.accounts, in: cache.directory)
    }

    // Establish an empty cache namespace only when no manifest exists. Never
    // repair malformed/unreadable state or derive a fence from a credential.
    static func prepareGeneration() throws -> UUID {
        guard let files else { throw SnapshotError.invalid }
        do { return try files.generation() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return try files.invalidate()
        }
    }
    static func load() -> Snapshot? {
        #if os(watchOS)
        if accountInbox?.hasAuthority == true { return loadAccounts()?.legacyProjection ?? accountInbox?.loadLegacy() }
        #endif
        guard let entry = entry() else { return nil }
        return try? Snapshot.decode(entry.data).sanitized
    }
    // Local persistence time, not a provider observation or delivery acknowledgement.
    static var savedAt: Date? {
        #if os(watchOS)
        if accountInbox?.hasAuthority == true {
            guard loadAccounts() != nil, let files, let directory else { return nil }
            return (try? files.read(.accounts, in: directory, maximumBytes: maximumPayloadBytes))?.savedAt
        }
        #endif
        guard let entry = entry(), (try? Snapshot.decode(entry.data)) != nil else { return nil }
        return entry.savedAt
    }
    private static func entry() -> CacheFiles.Entry? {
        guard !blocked, let files, let directory else { return nil }
        return try? files.read(.snapshot, in: directory, maximumBytes: maximumPayloadBytes)
    }
    static func save(_ snapshot: Snapshot, generation: UUID) throws {
        guard !blocked, let files, let directory else { throw SnapshotError.invalid }
        let data = try snapshot.sanitized.encoded()
        guard data.count <= maximumPayloadBytes else { throw SnapshotError.invalid }
        // Validate before replacing a usable cache, including the schema version.
        _ = try Snapshot.decode(data)
        try files.save(data, kind: .snapshot, in: directory, generation: generation, maximumBytes: maximumPayloadBytes)
    }
    #if os(watchOS)
    static func replaceFromCompanion(_ snapshot: Snapshot) throws {
        guard let files else { throw SnapshotError.invalid }
        _ = try Snapshot.decode(snapshot.sanitized.encoded())
        try save(snapshot, generation: files.invalidate())
        // Cleanup failure does not undo the committed reading. Retry next time;
        // obsolete generations remain unreadable even when removal is denied.
        if let directory { try? files.removeInactive(.snapshot, in: directory) }
    }
    #endif
}
