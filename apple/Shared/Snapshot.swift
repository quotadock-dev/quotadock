import Foundation

struct Snapshot: Codable, Equatable {
    let schemaVersion: Int
    let generatedAt: Date
    let demo: Bool
    let providers: [Provider]

    // Contract vocabulary shared with the bridge and private collector validation.
    private static let plans: Set<String> = ["Free", "Plus", "Pro", "Max", "Max 5x", "Max 20x", "Team", "Enterprise", "Standard", "Google AI Pro", "Google AI Ultra", "SuperGrok", "SuperGrok Heavy", "ChatGPT Plus", "ChatGPT Pro", "Claude Pro", "Claude Max"]
    private static let labels: Set<String> = ["Session", "Weekly", "Monthly", "Daily", "Credits", "Pro", "Flash", "Flash Lite", "5-hour", "7-day", "Pro tier", "Flash tier", "Flash Lite tier", "Additional", "Secondary"]
    // weekly and pro are used by the native preview, not the bridge's three slots.
    private static let windowIDs: Set<String> = ["primary", "secondary", "tertiary", "weekly", "pro"]

    static func date(from text: String) throws -> Date {
        guard text.utf8.count <= 64, text.utf8.allSatisfy({ $0 < 128 }),
              text.range(of: #"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})\z"#,
                         options: .regularExpression) != nil else { throw SnapshotError.invalid }
        var normalized = text
        if let dot = text.firstIndex(of: ".") {
            let start = text.index(after: dot)
            let end = text[start...].firstIndex(where: { !$0.isNumber }) ?? text.endIndex
            // The server's Date contract truncates to milliseconds. ICU can
            // silently drop the entire fraction when given many digits.
            let milliseconds = String(text[start..<end].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            normalized.replaceSubrange(start..<end, with: milliseconds)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = normalized.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let result = formatter.date(from: normalized) else { throw SnapshotError.invalid }
        return result
    }

    static func decode(_ data: Data) throws -> Snapshot {
        guard data.count <= 256 * 1024 else { throw SnapshotError.invalid }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]],
              providers.count <= 4 else { throw SnapshotError.invalid }
        for provider in providers {
            guard ["id", "name", "plan", "state", "source", "message", "observedAt", "windows"].allSatisfy({ provider.keys.contains($0) }),
                  let windows = provider["windows"] as? [[String: Any]],
                  windows.count <= 3 else { throw SnapshotError.invalid }
            for window in windows {
                guard ["id", "label", "remainingPercent", "resetsAt"].allSatisfy({ window.keys.contains($0) }) else { throw SnapshotError.invalid }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            return try date(from: text)
        }
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == 1,
              Set(snapshot.providers.map { $0.id.rawValue }).count == snapshot.providers.count else { throw SnapshotError.invalid }
        for provider in snapshot.providers {
            guard !provider.name.isEmpty, provider.name.utf8.count <= 64,
                  provider.plan.map({ plans.contains($0) }) ?? true,
                  provider.message.map({ $0.utf8.count <= 1024 }) ?? true,
                  provider.windows.count <= 3,
                  Set(provider.windows.map(\.id)).count == provider.windows.count else { throw SnapshotError.invalid }
            for window in provider.windows {
                guard windowIDs.contains(window.id), labels.contains(window.label),
                      window.remainingPercent.map({ $0.isFinite && (0...100).contains($0) }) ?? true else { throw SnapshotError.invalid }
            }
        }
        return snapshot
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        // Synthesized Codable omits nil keys; contract v1 requires explicit null.
        let data = try encoder.encode(self)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var providers = root["providers"] as? [[String: Any]] else { throw SnapshotError.invalid }
        for index in providers.indices {
            for key in ["plan", "message", "observedAt"] where providers[index][key] == nil {
                providers[index][key] = NSNull()
            }
            var windows = providers[index]["windows"] as? [[String: Any]] ?? []
            for window in windows.indices {
                for key in ["remainingPercent", "resetsAt"] where windows[window][key] == nil {
                    windows[window][key] = NSNull()
                }
            }
            providers[index]["windows"] = windows
        }
        root["providers"] = providers
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    // No arbitrary upstream message is persisted or forwarded to Watch.
    var sanitized: Snapshot {
        Snapshot(schemaVersion: schemaVersion, generatedAt: generatedAt, demo: demo,
                 providers: providers.map { provider in
            Provider(id: provider.id, name: provider.id.displayName,
                     plan: provider.plan.flatMap { Self.plans.contains($0) ? $0 : nil },
                     state: provider.state, source: provider.source,
                     message: provider.state == .available ? nil : "Usage unavailable",
                     observedAt: provider.observedAt, windows: provider.windows.map { window in
                QuotaWindow(id: window.id, label: Self.labels.contains(window.label) ? window.label : "Additional",
                            remainingPercent: provider.state == .available ? window.remainingPercent : nil,
                            resetsAt: window.resetsAt)
            })
        })
    }

    static var preview: Snapshot {
        Snapshot(schemaVersion: 1, generatedAt: Date(), demo: true, providers: [
            Provider(id: .claude, name: "Claude", plan: "Max", state: .available, source: .demo,
                     message: nil, observedAt: Date(), windows: [QuotaWindow(id: "primary", label: "Session", remainingPercent: 72, resetsAt: Date().addingTimeInterval(3600)),
                         QuotaWindow(id: "secondary", label: "Weekly", remainingPercent: 38, resetsAt: Date().addingTimeInterval(86400))]),
            Provider(id: .codex, name: "Codex", plan: "ChatGPT Plus", state: .available, source: .demo,
                     message: nil, observedAt: Date(), windows: [QuotaWindow(id: "weekly", label: "Weekly", remainingPercent: 43, resetsAt: nil)]),
            Provider(id: .gemini, name: "Gemini", plan: nil, state: .unavailable, source: .demo,
                     message: "Usage unavailable", observedAt: nil, windows: [QuotaWindow(id: "pro", label: "Pro tier", remainingPercent: nil, resetsAt: nil)]),
            Provider(id: .grok, name: "Grok", plan: nil, state: .unavailable, source: .demo,
                     message: "Usage unavailable", observedAt: nil, windows: [])
        ])
    }
}

enum SnapshotError: Error { case invalid, insecureURL, response, unpaired }
enum ProviderID: String, Codable {
    case claude, codex, gemini, grok
    var displayName: String { rawValue == "codex" ? "Codex" : rawValue.capitalized }
}
enum ProviderState: String, Codable { case available, unavailable, error }
enum QuotaSource: String, Codable { case codexbar, demo }

struct Provider: Codable, Identifiable, Equatable {
    let id: ProviderID
    let name: String
    let plan: String?
    let state: ProviderState
    let source: QuotaSource
    let message: String?
    let observedAt: Date?
    let windows: [QuotaWindow]

    // All surfaces, including accessories, must treat lookup failures as unknown.
    var displayWindows: [QuotaWindow] {
        windows.map { window in
            QuotaWindow(id: window.id, label: window.label,
                        remainingPercent: state == .available ? window.remainingPercent : nil,
                        resetsAt: window.resetsAt)
        }
    }

    func isStale(at date: Date = Date()) -> Bool {
        guard let observedAt else { return true }
        return date.timeIntervalSince(observedAt) > 15 * 60
    }
}

struct QuotaWindow: Codable, Identifiable, Equatable {
    let id: String
    let label: String
    let remainingPercent: Double?
    let resetsAt: Date?
    var clampedRemaining: Double? { remainingPercent.map { min(100, max(0, $0)) } }
    var remainingPercentText: String? {
        guard let remaining = clampedRemaining else { return nil }
        if remaining > 0 && remaining < 0.01 { return "<0.01%" }
        return "\(remaining.formatted(.number.precision(.fractionLength(0...2))))%"
    }
}
