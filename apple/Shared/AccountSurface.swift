import Foundation

// v3 is deliberately separate from the unique-provider v1 bridge contract.
// No labels, upstream messages, credentials, or account names enter this type.
struct AccountSurfaceSnapshot: Codable, Equatable {
    struct Account: Codable, Identifiable, Equatable {
        let id: UUID
        let provider: ProviderID
        let plan: String?
        let state: ProviderState
        let source: QuotaSource
        let observedAt: Date?
        let windows: [QuotaWindow]
        var identifier: String { "account-" + id.uuidString.lowercased() }
        var reading: Provider {
            Provider(id: provider, name: provider.displayName, plan: plan, state: state,
                     source: source, message: nil, observedAt: observedAt, windows: windows)
        }
        init(id: UUID, reading: Provider) throws {
            // Validate raw quota before sanitizing; never clamp invalid input.
            let raw = Snapshot(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 0),
                               demo: false, providers: [reading])
            _ = try Snapshot.decode(raw.encoded())
            guard reading.source != .demo else { throw SnapshotError.invalid }
            let clean = raw.sanitized.providers[0]
            self.id = id; provider = clean.id; plan = clean.plan; state = clean.state
            source = clean.source
            observedAt = clean.observedAt; windows = clean.windows
        }
    }
    let schemaVersion: Int
    let generatedAt: Date
    let generation: UUID
    let accounts: [Account]

    init(generatedAt: Date, generation: UUID, accounts: [Account]) {
        schemaVersion = 3; self.generatedAt = generatedAt
        self.generation = generation; self.accounts = accounts
    }

    func account(_ id: UUID?) -> Account? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }
    func window(account id: UUID?, windowID: String) -> QuotaWindow? {
        account(id)?.reading.displayWindows.first { $0.id == windowID }
    }
    var legacyProjection: Snapshot {
        var seen = Set<ProviderID>()
        return Snapshot(schemaVersion: 1, generatedAt: generatedAt, demo: false,
            providers: accounts.filter { seen.insert($0.provider).inserted }.map(\.reading)).sanitized
    }
    static func deepLink(_ id: UUID) -> URL {
        URL(string: "quotadock://account/" + id.uuidString.lowercased())!
    }
    static func accountID(from url: URL) -> UUID? {
        guard url.scheme == "quotadock", url.host == "account", url.query == nil,
              url.fragment == nil, url.user == nil, url.password == nil, url.port == nil,
              url.pathComponents.count == 2 else { return nil }
        return UUID(uuidString: url.lastPathComponent)
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        let data = try encoder.encode(self)
        _ = try Self.decode(data)
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "generatedAt", "generation", "accounts"],
              let accounts = root["accounts"] as? [[String: Any]] else {
            throw SnapshotError.invalid
        }
        for account in accounts {
            guard Set(account.keys).isSubset(of: ["id", "provider", "plan", "state", "source", "observedAt", "windows"]),
                  let windows = account["windows"] as? [[String: Any]], windows.count <= 3 else { throw SnapshotError.invalid }
            for window in windows {
                guard Set(window.keys).isSubset(of: ["id", "label", "remainingPercent", "resetsAt"]) else { throw SnapshotError.invalid }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try Snapshot.date(from: $0.singleValueContainer().decode(String.self)) }
        let value = try decoder.decode(Self.self, from: data)
        guard value.schemaVersion == 3, Set(value.accounts.map(\.id)).count == value.accounts.count,
              value.generatedAt.timeIntervalSince1970.isFinite else { throw SnapshotError.invalid }
        for account in value.accounts {
            guard account.source != .demo else { throw SnapshotError.invalid }
            // Uses the unchanged v1 vocabulary validation, one account at a time.
            _ = try Snapshot.decode(Snapshot(schemaVersion: 1, generatedAt: value.generatedAt,
                demo: false, providers: [account.reading]).encoded())
        }
        return value
    }
}

// Public selection/cache boundary, usable by extensions and portable tests.
// No fallback to a first account, v1, demo, or another generation is permitted.
struct AccountSurfaceCache {
    let files: CacheFiles
    let directory: URL
    func load() -> AccountSurfaceSnapshot? {
        guard let entry = try? files.read(.accounts, in: directory, maximumBytes: 256 * 1024),
              let value = try? AccountSurfaceSnapshot.decode(entry.data),
              value.generation == entry.generation,
              (try? files.generation()) == entry.generation else { return nil }
        return value
    }
    func save(_ value: AccountSurfaceSnapshot) throws {
        try files.save(value.encoded(), kind: .accounts, in: directory,
                       generation: value.generation, maximumBytes: 256 * 1024)
    }
    func selected(_ id: UUID?) -> AccountSurfaceSnapshot.Account? { load()?.account(id) }
}

// Application-context sequence is independent of account/connection generations.
// It survives phone authority changes. The receiver pins the paired publisher;
// a reinstall/new phone requires an explicit local reset, never automatic trust.
struct AccountSurfaceDelivery: Codable {
    let publisher: UUID
    let sequence: UInt64
    let snapshot: Data?
    var legacy: Data? = nil
    func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        _ = try Self.decode(data)
        return data
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["publisher", "sequence", "snapshot", "legacy"]) else { throw SnapshotError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.sequence > 0 else { throw SnapshotError.invalid }
        guard value.snapshot == nil || value.legacy == nil else { throw SnapshotError.invalid }
        if let snapshot = value.snapshot { _ = try AccountSurfaceSnapshot.decode(snapshot) }
        if let data = value.legacy {
            let snapshot = try Snapshot.decode(data)
            guard !snapshot.demo, !snapshot.providers.contains(where: { $0.source == .demo }),
                  try snapshot.sanitized.encoded() == data else { throw SnapshotError.invalid }
        }
        return value
    }
}

struct AccountSurfaceInbox {
    private struct Cursor: Codable {
        let publisher: UUID
        let sequence: UInt64
        let generation: UUID
    }
    let cache: AccountSurfaceCache
    let cursorURL: URL
    var hasAuthority: Bool { FileManager.default.fileExists(atPath: cursorURL.path) }
    private func cursor() throws -> Cursor {
        let size = try cursorURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 1024 else { throw SnapshotError.invalid }
        let data = try Data(contentsOf: cursorURL)
        guard data.count <= 1024 else { throw SnapshotError.invalid }
        return try JSONDecoder().decode(Cursor.self, from: data)
    }
    func load() -> AccountSurfaceSnapshot? {
        guard let cursor = try? cursor(), let value = cache.load(),
              value.generation == cursor.generation,
              let after = try? self.cursor(), after.generation == cursor.generation,
              after.publisher == cursor.publisher, after.sequence == cursor.sequence else { return nil }
        return value
    }
    func loadLegacy() -> Snapshot? {
        guard let before = try? cursor(),
              let entry = try? cache.files.read(.snapshot, in: cache.directory, maximumBytes: 256 * 1024),
              entry.generation == before.generation, let after = try? cursor(),
              after.generation == before.generation,
              let value = try? Snapshot.decode(entry.data), !value.demo else { return nil }
        return value.sanitized
    }
    func receive(_ data: Data) throws {
        let delivery = try AccountSurfaceDelivery.decode(data)
        if hasAuthority {
            let previous = try cursor() // Corruption is not permission to reset trust.
            guard previous.publisher == delivery.publisher,
                  delivery.sequence > previous.sequence else { throw SnapshotError.invalid }
        }
        try commit(delivery)
    }
    // Only an explicit user-confirmed action using the currently paired
    // WCSession context may call this. Never invoke it for incoming callbacks.
    func trustPairedPublisher(_ data: Data) throws {
        let delivery = try AccountSurfaceDelivery.decode(data)
        if hasAuthority, let previous = try? cursor(), previous.publisher == delivery.publisher {
            try receive(data) // Trust is not permission to roll back a sequence.
        } else {
            try commit(delivery)
        }
    }
    private func commit(_ delivery: AccountSurfaceDelivery) throws {
        let pending = Cursor(publisher: delivery.publisher, sequence: delivery.sequence, generation: UUID())
        // Commit the fence first. Failed invalidation/write cannot resurrect the
        // previous payload, even after process reconstruction. The pending
        // generation names no file. CacheFiles alone chooses the fresh namespace.
        try JSONEncoder().encode(pending).write(to: cursorURL, options: .atomic)
        let next = try cache.files.invalidate()
        let cursor = Cursor(publisher: delivery.publisher, sequence: delivery.sequence, generation: next)
        try JSONEncoder().encode(cursor).write(to: cursorURL, options: .atomic)
        if let data = delivery.snapshot {
            let source = try AccountSurfaceSnapshot.decode(data)
            try cache.save(AccountSurfaceSnapshot(generatedAt: source.generatedAt,
                generation: next, accounts: source.accounts))
        } else if let data = delivery.legacy {
            try cache.files.save(data, kind: .snapshot, in: cache.directory, generation: next, maximumBytes: 256 * 1024)
        }
        try? cache.files.removeInactive(.accounts, in: cache.directory)
        try? cache.files.removeInactive(.snapshot, in: cache.directory)
    }
}

struct AccountSurfacePublisher {
    private struct State: Codable { let publisher: UUID; let sequence: UInt64 }
    let stateURL: URL
    // Serialize callers in the phone process. Never reset a malformed counter.
    func next(snapshot: AccountSurfaceSnapshot?, legacy: Snapshot? = nil) throws -> Data {
        let old: State
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let size = try stateURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 1024 else { throw SnapshotError.invalid }
            let data = try Data(contentsOf: stateURL)
            guard data.count <= 1024 else { throw SnapshotError.invalid }
            old = try JSONDecoder().decode(State.self, from: data)
        } else { old = State(publisher: UUID(), sequence: 0) }
        guard old.sequence < UInt64.max else { throw SnapshotError.invalid }
        let next = State(publisher: old.publisher, sequence: old.sequence + 1)
        try JSONEncoder().encode(next).write(to: stateURL, options: .atomic)
        let payload = try snapshot?.encoded()
        let delivery = AccountSurfaceDelivery(publisher: next.publisher, sequence: next.sequence,
            snapshot: payload, legacy: try legacy?.sanitized.encoded())
        // Base64/envelope overhead must also fit the boundary. Too large means
        // unavailable, not a truncated list or a retained old authority.
        if let data = try? delivery.encoded() { return data }
        return try AccountSurfaceDelivery(publisher: next.publisher, sequence: next.sequence, snapshot: nil).encoded()
    }
}
