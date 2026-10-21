import Foundation

// The union is phone-private. Neither the cache manifest nor Watch/widget
// payloads contain this record or any credential bytes.
struct ConnectionRecord: Codable {
    enum Mode: String, Codable { case signedOut, bridge, cloud }
    let version: Int
    let generation: UUID
    let mode: Mode
    let credential: Data?

    init(generation: UUID, mode: Mode, credential: Data? = nil) throws {
        version = 1
        self.generation = generation
        self.mode = mode
        self.credential = credential
        try validate()
    }

    func validate() throws {
        guard version == 1 else { throw SnapshotError.invalid }
        switch mode {
        case .signedOut: guard credential == nil else { throw SnapshotError.invalid }
        case .bridge, .cloud:
            guard let credential, !credential.isEmpty, credential.count <= 8192 else { throw SnapshotError.invalid }
        }
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 12288 else { throw SnapshotError.invalid }
        let record = try JSONDecoder().decode(Self.self, from: data)
        try record.validate()
        return record
    }

    func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 12288 else { throw SnapshotError.invalid }
        return data
    }
}

// All production instances use the same object. No suspension is permitted
// between checking an expected authority and writing its replacement.
final class ConnectionStorage {
    private let lock = NSRecursiveLock()
    private let read: () throws -> Data
    private let write: (Data) throws -> Void
    let files: CacheFiles
    private var blocked = false

    init(files: CacheFiles, read: @escaping () throws -> Data, write: @escaping (Data) throws -> Void) {
        self.files = files
        self.read = read
        self.write = write
    }

    var isBlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return blocked
    }

    func current() throws -> ConnectionRecord {
        lock.lock(); defer { lock.unlock() }
        guard !blocked else { throw SnapshotError.unpaired }
        let record = try ConnectionRecord.decode(read())
        guard try files.generation() == record.generation else { throw SnapshotError.unpaired }
        return record
    }

    @discardableResult
    func select(_ mode: ConnectionRecord.Mode, credential: Data? = nil) throws -> ConnectionRecord {
        lock.lock(); defer { lock.unlock() }
        // Reject malformed destinations before invalidating a working connection.
        _ = try ConnectionRecord(generation: UUID(), mode: mode, credential: credential)
        blocked = true
        let next = try ConnectionRecord(generation: files.invalidate(), mode: mode, credential: credential)
        try write(next.encoded())
        blocked = false
        return try current()
    }

    func updateCloud(_ credential: Data, expected: Data, generation: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let old = try current()
        guard old.mode == .cloud, old.generation == generation, old.credential == expected else {
            throw SnapshotError.unpaired
        }
        let next = try ConnectionRecord(generation: generation, mode: .cloud, credential: credential)
        try write(next.encoded())
    }

    // Rejection retains sanitized observations, unlike an explicit logout.
    // If its authority write fails, a fresh cache fence quarantines restart.
    func rejectCloud(expected: Data, generation: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let old = try current()
        guard old.mode == .cloud, old.generation == generation, old.credential == expected else {
            throw SnapshotError.unpaired
        }
        blocked = true
        do {
            try write(ConnectionRecord(generation: generation, mode: .signedOut).encoded())
            blocked = false
        } catch {
            _ = try? files.invalidate()
            throw error
        }
    }
}
