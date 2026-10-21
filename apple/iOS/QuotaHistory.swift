import Foundation

// History is phone-memory data, never a replacement for the current snapshot,
// a widget/Watch payload, or a source of inferred quota replenishment.
struct CloudHistorySettings: Decodable, Equatable {
    let enabled: Bool
    let retentionDays: Int
    let maximumSamplesPerAccount: Int
    static let keys: Set<String> = ["enabled", "retentionDays", "maximumSamplesPerAccount"]

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == keys else { throw SnapshotError.invalid }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.retentionDays == 7, result.maximumSamplesPerAccount == 1000 else { throw SnapshotError.invalid }
        return result
    }
}

struct CloudHistoryObservation: Identifiable {
    let observedAt: String
    let observedDate: Date
    let reading: Provider
    var id: Date { observedDate }
}

struct CloudHistoryPage {
    let accountId: UUID
    let provider: ProviderID
    let settings: CloudHistorySettings
    let observations: [CloudHistoryObservation]
    let nextCursor: String?

    static func cursorDate(_ value: String) throws -> Date {
        guard value.utf8.count == 24,
              value.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z\z"#,
                          options: .regularExpression) != nil else { throw SnapshotError.invalid }
        let date = try Snapshot.date(from: value)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.string(from: date) == value else { throw SnapshotError.invalid }
        return date
    }

    static func decode(_ data: Data, accountID: UUID, provider: ProviderID,
                       before: String? = nil) throws -> Self {
        guard data.count <= 256 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == CloudHistorySettings.keys.union(["accountId", "provider", "observations", "nextCursor"]),
              let id = root["accountId"] as? String, UUID(uuidString: id) == accountID,
              root["provider"] as? String == provider.rawValue,
              let rows = root["observations"] as? [[String: Any]], rows.count <= 250 else { throw SnapshotError.invalid }
        let settings = try CloudHistorySettings.decode(JSONSerialization.data(withJSONObject:
            root.filter { CloudHistorySettings.keys.contains($0.key) }))
        let cursor: String?
        if root["nextCursor"] is NSNull { cursor = nil }
        else if let value = root["nextCursor"] as? String { cursor = value }
        else { throw SnapshotError.invalid }
        guard settings.enabled || (rows.isEmpty && cursor == nil) else { throw SnapshotError.invalid }
        var previous = try before.map { try cursorDate($0) }
        var observations: [CloudHistoryObservation] = []
        for row in rows {
            guard Set(row.keys) == Set(["plan", "state", "source", "observedAt", "windows"]),
                  row["state"] as? String == "available", row["source"] as? String == "codexbar",
                  let text = row["observedAt"] as? String,
                  let windows = row["windows"] as? [[String: Any]],
                  windows.allSatisfy({ Set($0.keys) == Set(["id", "label", "remainingPercent", "resetsAt"])
                      && ["primary", "secondary", "tertiary"].contains($0["id"] as? String ?? "") }) else {
                throw SnapshotError.invalid
            }
            // Reuse the current quota vocabulary and explicit-null validation,
            // while retaining the source ISO text rather than reformatting it.
            var entry = row
            entry["id"] = provider.rawValue; entry["name"] = provider.displayName; entry["message"] = NSNull()
            let snapshot = try Snapshot.decode(JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "generatedAt": text, "demo": false, "providers": [entry]]))
            guard let reading = snapshot.providers.first, let date = reading.observedAt,
                  reading.windows.contains(where: { $0.remainingPercent != nil }),
                  previous.map({ date < $0 }) ?? true else { throw SnapshotError.invalid }
            observations.append(CloudHistoryObservation(observedAt: text, observedDate: date, reading: reading))
            previous = date
        }
        if let cursor {
            guard let last = observations.last, try cursorDate(cursor) == last.observedDate else { throw SnapshotError.invalid }
        }
        return Self(accountId: accountID, provider: provider, settings: settings,
                    observations: observations, nextCursor: cursor)
    }
}
