import Foundation

// A latest-value outbox, not a delivery acknowledgement. Only sanitized quota
// bytes cross this boundary; activation always replaces memory with phone disk.
struct WatchTransfer {
    private(set) var pending: Data?

    mutating func enqueue(_ snapshot: Snapshot) {
        pending = Self.payload(snapshot)
    }

    mutating func reconcile(phoneSnapshot: Snapshot?, at date: Date = Date()) {
        let live: Snapshot? = phoneSnapshot.flatMap { snapshot in
            snapshot.demo || snapshot.providers.contains(where: { $0.source == .demo }) ? nil : snapshot
        }
        enqueue(live ?? Snapshot(schemaVersion: 1, generatedAt: date, demo: false, providers: []))
    }

    mutating func accepted() { pending = nil }

    private static func payload(_ snapshot: Snapshot) -> Data? {
        guard !snapshot.demo, !snapshot.providers.contains(where: { $0.source == .demo }),
              let data = try? snapshot.sanitized.encoded(), data.count <= 256 * 1024,
              (try? Snapshot.decode(data)) != nil else { return nil }
        return data
    }
}
