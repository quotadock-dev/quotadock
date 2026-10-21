import Foundation

// A generation is a logical invalidation fence, not a provider timestamp. Old
// files can remain after failed cleanup without becoming readable quota again.
struct CacheFiles {
    enum Kind: String { case snapshot, cloud, accounts }
    struct Entry {
        let data: Data
        let generation: UUID
        let savedAt: Date?
    }
    let manifestURL: URL

    func generation() throws -> UUID {
        let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == 36 else { throw SnapshotError.invalid }
        let bytes = try Data(contentsOf: manifestURL)
        guard bytes.count == 36, let text = String(data: bytes, encoding: .utf8),
              let id = UUID(uuidString: text), id.uuidString.lowercased() == text else { throw SnapshotError.invalid }
        return id
    }

    @discardableResult
    func invalidate() throws -> UUID {
        let next = UUID()
        try Self.write(Data(next.uuidString.lowercased().utf8), to: manifestURL)
        guard try generation() == next else { throw SnapshotError.invalid }
        return next
    }

    func read(_ kind: Kind, in directory: URL, maximumBytes: Int) throws -> Entry {
        let current = try generation()
        let url = file(kind, in: directory, generation: current)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size >= 0, size <= maximumBytes else { throw SnapshotError.invalid }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes, try generation() == current else { throw SnapshotError.invalid }
        return Entry(data: data, generation: current, savedAt: values.contentModificationDate)
    }

    func save(_ data: Data, kind: Kind, in directory: URL, generation expected: UUID,
              maximumBytes: Int) throws {
        guard data.count <= maximumBytes, try generation() == expected else { throw SnapshotError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.write(data, to: file(kind, in: directory, generation: expected), phonePrivate: kind == .cloud)
        // A late old-owner write is confined to its old generation, even if a
        // different process advanced the fence while the write was in flight.
        guard try generation() == expected else { throw SnapshotError.invalid }
    }

    func file(_ kind: Kind, in directory: URL, generation: UUID) -> URL {
        directory.appendingPathComponent("\(kind.rawValue)-\(generation.uuidString.lowercased()).json")
    }

    // The caller captures an OLD generation before a transition. Never enumerate
    // or remove whatever happens to be current after asynchronous work.
    func remove(_ kind: Kind, in directory: URL, generation old: UUID) throws {
        guard try generation() != old else { throw SnapshotError.invalid }
        let url = file(kind, in: directory, generation: old)
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }

    // Retry obsolete-file cleanup on each successful transition/Watch update.
    // Only canonical filenames belong to us; deletion rechecks the live fence.
    func removeInactive(_ kind: Kind, in directory: URL) throws {
        let urls: [URL]
        do { urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return }
        let prefix = kind.rawValue + "-"
        for url in urls where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
            let text = String(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
            guard let old = UUID(uuidString: text), old.uuidString.lowercased() == text else { continue }
            if old != (try generation()) { try remove(kind, in: directory, generation: old) }
        }
    }

    private static func write(_ data: Data, to url: URL, phonePrivate: Bool = false) throws {
        #if os(iOS) || os(watchOS)
        try data.write(to: url, options: phonePrivate ? [.atomic, .completeFileProtection]
                       : [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
