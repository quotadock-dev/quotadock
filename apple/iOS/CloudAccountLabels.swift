import Foundation

// Phone-private preferences only. Never attach labels to quota/cache models.
// A login family is an authority, not an inferred provider identity. Legacy
// sessions use the persisted connection generation and fail closed on switches.
final class CloudAccountLabels {
    private let defaults: UserDefaults
    private let key = "cloudAccountLabels.v1"
    static let maximumLength = 120
    static let maximumEntries = 1000

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func scope(server: URL, authority: UUID) -> String {
        server.absoluteString + "\n" + authority.uuidString.lowercased()
    }

    private func entry(scope: String, slot: UUID) -> String {
        scope + "\n" + slot.uuidString.lowercased()
    }

    func label(scope: String, slot: UUID) -> String {
        let values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return Self.clean(values[entry(scope: scope, slot: slot)] ?? "")
    }

    private static func clean(_ value: String) -> String {
        let singleLine = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) &&
            !CharacterSet.newlines.contains($0) &&
            !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value)
        }
        return String(String(String.UnicodeScalarView(singleLine))
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumLength))
    }

    @discardableResult
    func set(_ value: String, scope: String, slot: UUID) -> Bool {
        var values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let id = entry(scope: scope, slot: slot)
        let label = Self.clean(value)
        if label.isEmpty { values.removeValue(forKey: id) }
        else {
            guard values[id] != nil || values.count < Self.maximumEntries else { return false }
            values[id] = label
        }
        defaults.set(values, forKey: key)
        return true
    }

    func remove(scope: String) {
        let values = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        defaults.set(values.filter { !$0.key.hasPrefix(scope + "\n") }, forKey: key)
    }
}
