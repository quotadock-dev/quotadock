import Foundation

// Phone-local presentation preference, not collection consent or notification
// authorization. No observations, identifiers or credentials are persisted here.
enum QuotaAlerts {
    static let thresholds = [10, 20, 30]
    static let key = "inAppQuotaAlerts.v1"

    static func threshold(in defaults: UserDefaults = .standard) -> Int? {
        guard let data = defaults.data(forKey: key), data.count <= 32,
              let value = try? JSONDecoder().decode(Int.self, from: data),
              thresholds.contains(value) else { return nil }
        return value
    }

    @discardableResult
    static func save(threshold: Int?, in defaults: UserDefaults = .standard) -> Bool {
        if let threshold {
            guard thresholds.contains(threshold), let data = try? JSONEncoder().encode(threshold) else { return false }
            defaults.set(data, forKey: key)
            return defaults.data(forKey: key) == data
        }
        defaults.removeObject(forKey: key)
        return defaults.object(forKey: key) == nil
    }

    static func lowWindows(in provider: Provider, threshold: Int?, now: Date = Date()) -> [QuotaWindow] {
        guard let threshold, thresholds.contains(threshold), provider.state == .available,
              provider.source == .codexbar, let observed = provider.observedAt,
              now.timeIntervalSince(observed) >= 0, !provider.isStale(at: now) else { return [] }
        return provider.windows.filter {
            guard let value = $0.remainingPercent, value.isFinite, (0...100).contains(value) else { return false }
            return value <= Double(threshold)
        }
    }
}
