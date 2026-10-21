import Foundation

// iPhone-only adapter. Do not compile Cloud.swift or its network client into
// extensions. The caller must pass the generation captured before its request.
extension CloudSnapshot {
    func accountSurfaceSnapshot(generation: UUID) throws -> AccountSurfaceSnapshot {
        guard !demo else { throw SnapshotError.invalid }
        let value = AccountSurfaceSnapshot(generatedAt: generatedAt, generation: generation,
            accounts: try accounts.map { try AccountSurfaceSnapshot.Account(id: $0.id, reading: $0.reading) })
        _ = try value.encoded()
        return value
    }
}
