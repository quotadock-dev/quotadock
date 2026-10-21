import Foundation
import Security
import CryptoKit
import AuthenticationServices
import SwiftUI
import UIKit

struct CloudAccount: Decodable, Identifiable {
    let id: UUID
    let provider: ProviderID
}

struct CloudChallenge: Decodable {
    let challengeId: String
    let nonce: String
    let expiresIn: Int
    static func decode(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["challengeId", "nonce", "expiresIn"]) else { throw SnapshotError.invalid }
        let result = try JSONDecoder().decode(Self.self, from: data)
        guard result.expiresIn == 300, result.challengeId.utf8.count == 36,
              UUID(uuidString: result.challengeId)?.uuidString.lowercased() == result.challengeId,
              result.nonce.utf8.count == 43,
              result.nonce.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw SnapshotError.invalid }
        return result
    }
}

struct CloudJob: Decodable {
    enum Status: String, Decodable { case pending, cached, completed, expired }
    enum Mode: String, Decodable { case auto, force, live }
    let id: UUID
    let status: Status
    let mode: Mode
    let accountIds: [UUID]
    let expiresAt: String
    let debited: Bool

    static func lookup(_ data: Data, requested: [UUID], mode: Mode) throws -> Self? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["job"]) else { throw SnapshotError.invalid }
        if root["job"] is NSNull { return nil }
        guard let job = root["job"] as? [String: Any] else { throw SnapshotError.invalid }
        return try decode(JSONSerialization.data(withJSONObject: job), requested: requested, mode: mode)
    }

    static func decode(_ data: Data, requested: [UUID], mode: Mode, previous: Self? = nil) throws -> Self {
        let job = try JSONDecoder().decode(Self.self, from: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: job.expiresAt)
        formatter.formatOptions = [.withInternetDateTime]
        guard !requested.isEmpty, requested.count <= 50, Set(requested).count == requested.count,
              job.mode == mode, job.accountIds.count <= 50,
              Set(job.accountIds).count == job.accountIds.count,
              Set(job.accountIds).isSubset(of: Set(requested)),
              (fractional ?? formatter.date(from: job.expiresAt)) != nil,
              !job.debited || job.status == .completed else { throw SnapshotError.invalid }
        if mode != .auto {
            guard Set(job.accountIds) == Set(requested) else { throw SnapshotError.invalid }
        }
        guard job.status == .cached ? job.accountIds.isEmpty : !job.accountIds.isEmpty else { throw SnapshotError.invalid }
        if let previous {
            guard job.id == previous.id, job.mode == previous.mode,
                  Set(job.accountIds) == Set(previous.accountIds), job.expiresAt == previous.expiresAt else {
                throw SnapshotError.invalid
            }
        }
        return job
    }
}

struct CloudMe: Decodable {
    enum Tier: String, Decodable { case free, plus, pro }
    struct LiveSession: Decodable {
        let accountIds: [UUID]
        let startedAt: String?
        let deadline: String?
        var deadlineDate: Date? {
            guard let deadline else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: deadline)
        }
    }
    struct Limits: Decodable {
        let accounts: Int?
        let collectors: Int?
        let autoMinutes: Int
        let allowedAutoMinutes: [Int]
        let earlyBatchesPerDay: Int?
        let live: Bool
    }
    let tier: Tier
    let limits: Limits
    let autoMinutes: Int
    let backgroundCollection: Bool?
    let earlyBatchesUsed: Int
    let liveSessionsUsed: Int
    let liveSessionsLimit: Int
    let liveSession: LiveSession?
    let purchasesAvailable: Bool
    let appAccountToken: UUID?
    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        let intervals = value.tier == .free ? [120] : value.tier == .plus ? [60] : [20, 30, 60, 120]
        guard value.limits.accounts == (value.tier == .free ? 3 : value.tier == .plus ? 10 : 25),
              value.limits.collectors == nil || value.limits.collectors == (value.tier == .free ? 1 : value.tier == .plus ? 3 : 5),
              value.limits.allowedAutoMinutes == intervals,
              intervals.contains(value.autoMinutes), value.autoMinutes == value.limits.autoMinutes,
              value.limits.live == (value.tier != .free),
              value.limits.earlyBatchesPerDay == (value.tier == .free ? 10 : nil),
              value.earlyBatchesUsed >= 0, value.liveSessionsUsed >= 0,
              value.liveSessionsLimit == (value.tier == .free ? 0 : 5),
              !value.purchasesAvailable || value.appAccountToken != nil else { throw SnapshotError.invalid }
        if let live = value.liveSession {
            guard value.tier != .free, !live.accountIds.isEmpty, live.accountIds.count <= 50,
                  Set(live.accountIds).count == live.accountIds.count,
                  (live.startedAt == nil) == (live.deadline == nil),
                  live.deadline == nil || live.deadlineDate != nil else { throw SnapshotError.invalid }
        }
        return value
    }
    var budget: String {
        DockL10n.format("%@ · %@ slots · auto %d min · early %@ · Live %d/%d %@",
            tier == .free ? DockL10n.text("Free") : tier.rawValue.capitalized,
            limits.accounts.map(String.init) ?? DockL10n.text("unlimited"), autoMinutes,
            limits.earlyBatchesPerDay.map { DockL10n.format("%d/%d per KST day", earlyBatchesUsed, $0) } ?? DockL10n.text("unlimited"),
            liveSessionsUsed, liveSessionsLimit, DockL10n.text(tier == .plus ? "subscription period" : "KST day"))
    }
}

struct CloudCollector: Decodable, Identifiable {
    let id: UUID
    let accountIds: [UUID]
    let expiresAt: Date
    private enum CodingKeys: String, CodingKey { case id, accountIds, expiresAt }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        accountIds = try values.decode([UUID].self, forKey: .accountIds)
        let timestamp = try values.decode(String.self, forKey: .expiresAt)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: timestamp)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: timestamp),
              accountIds.count <= 50, Set(accountIds).count == accountIds.count else { throw SnapshotError.invalid }
        expiresAt = date
    }
}

enum CollectorApproval {
    static func valid(code: String, selected: Set<UUID>, slots: [CloudAccount]) -> Bool {
        return code.count == 8 && code.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
            && CloudBatchSelection.valid(Array(selected), slots: slots)
    }
}

// In-memory only: selection is not an identity or a persisted credential.
struct CloudBatchSelection {
    private(set) var ids: [UUID] = []
    private var initialized = false
    static func valid(_ ids: [UUID], slots: [CloudAccount]) -> Bool {
        !ids.isEmpty && ids.count <= 50 && Set(ids).count == ids.count
            && Set(ids).isSubset(of: Set(slots.map(\.id)))
    }
    mutating func reconcile(slots: [CloudAccount]) {
        let owned = Set(slots.map(\.id))
        if !initialized, !slots.isEmpty {
            ids = Array(slots.map(\.id).prefix(50))
            initialized = true
        } else {
            ids.removeAll { !owned.contains($0) }
        }
    }
    mutating func select(_ ids: [UUID], slots: [CloudAccount]) -> Bool {
        guard ids.isEmpty || Self.valid(ids, slots: slots) else { return false }
        self.ids = ids
        initialized = true
        return true
    }
}

struct CloudSnapshot: Codable {
    struct Account: Codable, Identifiable {
        let accountId: UUID
        var id: UUID { accountId }
        let provider: ProviderID
        let plan: String?
        let state: ProviderState
        let source: QuotaSource
        let observedAt: Date?
        let windows: [QuotaWindow]
        let lastError: String?
        var reading: Provider {
            Provider(id: provider, name: provider.displayName, plan: plan, state: state,
                     source: source, message: nil, observedAt: observedAt, windows: windows)
        }
    }
    let schemaVersion: Int
    let generatedAt: Date
    let demo: Bool
    let accounts: [Account]
    var cachedSubset: Bool? = nil
    static func decode(_ data: Data) throws -> CloudSnapshot {
        guard data.count <= 256 * 1024 else { throw SnapshotError.invalid }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            return try Snapshot.date(from: value)
        }
        let result = try decoder.decode(Self.self, from: data)
        guard result.schemaVersion == 2,
              Set(result.accounts.map(\.id)).count == result.accounts.count else { throw SnapshotError.invalid }
        for account in result.accounts {
            // The same quota vocabulary and unique-window bounds protect v1/v2 caches.
            let reading = Snapshot(schemaVersion: 1, generatedAt: result.generatedAt,
                demo: result.demo, providers: [account.reading])
            _ = try Snapshot.decode(reading.encoded())
        }
        return result
    }
    // Legacy v1 only; configurable surfaces use accountSurfaceSnapshot(generation:).
    var smallSurfaceSnapshot: Snapshot {
        var seen = Set<ProviderID>()
        return Snapshot(schemaVersion: 1, generatedAt: generatedAt, demo: demo,
                        providers: accounts.filter { seen.insert($0.provider).inserted }.map(\.reading)).sanitized
    }
    func cacheData() throws -> Data {
        var clean = CloudSnapshot(schemaVersion: schemaVersion, generatedAt: generatedAt, demo: demo,
            accounts: accounts.map { account in
                let reading = Snapshot(schemaVersion: 1, generatedAt: generatedAt, demo: demo,
                                       providers: [account.reading]).sanitized.providers[0]
                return Account(accountId: account.id, provider: account.provider, plan: reading.plan,
                    state: reading.state, source: reading.source, observedAt: reading.observedAt,
                    windows: reading.windows, lastError: account.lastError == nil ? nil : "collection_unavailable")
            })
        clean.cachedSubset = cachedSubset
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        let data = try encoder.encode(clean)
        if data.count <= 256 * 1024 { return data }
        var subset = CloudSnapshot(schemaVersion: schemaVersion, generatedAt: generatedAt, demo: demo,
                                   accounts: Array(clean.accounts.prefix(50)))
        subset.cachedSubset = true
        let bounded = try encoder.encode(subset)
        guard bounded.count <= 256 * 1024 else { throw SnapshotError.invalid }
        return bounded
    }
}

// Full private slot cache stays on iPhone. Configurable surfaces receive a
// sanitized UUID-aware v3 projection, never account labels, emails or credentials.
enum CloudCache {
    static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("QuotaDock-cloud", isDirectory: true)
    }
    static func load() -> CloudSnapshot? {
        guard !SnapshotStore.blocked, let files = SnapshotStore.files, let directory,
              let entry = try? files.read(.cloud, in: directory, maximumBytes: 256 * 1024) else { return nil }
        return try? CloudSnapshot.decode(entry.data)
    }
    @discardableResult
    static func save(_ snapshot: CloudSnapshot, generation: UUID?) -> Bool {
        guard !SnapshotStore.blocked, !snapshot.demo, let files = SnapshotStore.files, let directory, let generation,
              let data = try? snapshot.cacheData() else { return false }
        do {
            try files.save(data, kind: .cloud, in: directory, generation: generation, maximumBytes: 256 * 1024)
            try SnapshotStore.saveAccounts(snapshot.accountSurfaceSnapshot(generation: generation))
            return true
        } catch { return false }
    }
}

struct CloudSession: Codable {
    let baseURL: URL
    let token: String
    let expiresAt: Date
    var refreshToken: String? = nil
    var familyId: UUID? = nil
    var refreshExpiresAt: Date? = nil
    var pendingRenewal: UUID? = nil
    var pendingRenewalStartedAt: Date? = nil
    var pendingRenewalSends: Int? = nil

    func sameAuthority(as other: Self) -> Bool {
        guard baseURL == other.baseURL, familyId == other.familyId,
              refreshExpiresAt == other.refreshExpiresAt else { return false }
        return familyId != nil || (token == other.token && expiresAt == other.expiresAt)
    }

    static func login(_ data: Data, baseURL: URL, previous: Self? = nil, now: Date = Date()) throws -> Self {
        struct Response: Decodable {
            let sessionToken: String; let expiresIn: Int
            let expiresAt: String?
            let refreshToken: String?; let familyId: String?; let refreshExpiresAt: String?
        }
        guard data.count <= 4096,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["sessionToken", "expiresIn"]) ||
                Set(root.keys) == Set(["sessionToken", "expiresIn", "expiresAt", "refreshToken", "familyId", "refreshExpiresAt"]) else { throw SnapshotError.invalid }
        let value = try JSONDecoder().decode(Response.self, from: data)
        guard (1...3600).contains(value.expiresIn) else { throw SnapshotError.invalid }
        var next = Self(baseURL: baseURL, token: value.sessionToken,
                        expiresAt: now.addingTimeInterval(Double(value.expiresIn)))
        if let raw = value.familyId, let timestamp = value.refreshExpiresAt,
           let accessTimestamp = value.expiresAt, let refresh = value.refreshToken {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: timestamp)
            let fractionalAccess = formatter.date(from: accessTimestamp)
            formatter.formatOptions = [.withInternetDateTime]
            guard raw.count == 36, let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw,
                  timestamp.utf8.count <= 32, timestamp.utf8.allSatisfy({ $0 < 128 }), timestamp.hasSuffix("Z"),
                  accessTimestamp.utf8.count <= 32, accessTimestamp.utf8.allSatisfy({ $0 < 128 }), accessTimestamp.hasSuffix("Z"),
                  let expiry = fractional ?? formatter.date(from: timestamp),
                  let accessExpiry = fractionalAccess ?? formatter.date(from: accessTimestamp),
                  expiry > now, expiry.timeIntervalSince(now) <= 30 * 86400 + 60,
                  accessExpiry > now, accessExpiry.timeIntervalSince(now) <= Double(value.expiresIn) + 60,
                  accessExpiry <= expiry else { throw SnapshotError.invalid }
            // Identical retries retain the original server deadline. Receiving
            // expiresIn again must not start another hour on the phone.
            next = Self(baseURL: baseURL, token: value.sessionToken, expiresAt: accessExpiry)
            next.refreshToken = refresh; next.familyId = id; next.refreshExpiresAt = expiry
        } else if root.count != 2 { throw SnapshotError.invalid }
        try next.validate()
        if let previous {
            guard next.sameAuthority(as: previous), next.token != previous.token,
                  next.refreshToken != previous.refreshToken else { throw SnapshotError.invalid }
        }
        return next
    }

    func validate() throws {
        _ = try Pairing(baseURL: baseURL.absoluteString, token: token)
        guard baseURL.absoluteString.utf8.count <= 2048, token.utf8.count == 43,
              token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              expiresAt.timeIntervalSince1970.isFinite else { throw SnapshotError.invalid }
        if let refreshToken, let familyId, let refreshExpiresAt {
            _ = familyId
            guard refreshToken != token, refreshToken.utf8.count == 43,
                  refreshToken.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
                  refreshExpiresAt.timeIntervalSince1970.isFinite,
                  expiresAt <= refreshExpiresAt.addingTimeInterval(1) else { throw SnapshotError.invalid }
            guard (pendingRenewal == nil) == (pendingRenewalStartedAt == nil),
                  (pendingRenewal == nil) == (pendingRenewalSends == nil),
                  pendingRenewalStartedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                  pendingRenewalSends.map({ (0...2).contains($0) && pendingRenewal != nil }) ?? true else { throw SnapshotError.invalid }
        } else {
            guard refreshToken == nil, familyId == nil, refreshExpiresAt == nil, pendingRenewal == nil,
                  pendingRenewalStartedAt == nil, pendingRenewalSends == nil else { throw SnapshotError.invalid }
        }
    }
}

enum CloudSessionStore {
    // Deliberately no shared access group: widgets and Watch cannot read this session.
    static var query: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "QuotaDock.cloud.v2", kSecAttrAccount as String: "session"]
        if let group = Bundle.main.object(forInfoDictionaryKey: "CloudKeychainGroup") as? String {
            result[kSecAttrAccessGroup as String] = group
        }
        return result
    }
    static func load() -> CloudSession? {
        guard let record = try? ConnectionStore.current(), record.mode == .cloud,
              let data = record.credential, data.count <= 4096,
              let session = try? JSONDecoder().decode(CloudSession.self, from: data),
              (try? session.validate()) != nil else { return nil }
        return session
    }
    static func encoded(_ session: CloudSession) throws -> Data {
        try session.validate()
        let data = try ConnectionStore.encoded(session)
        guard data.count <= 4096 else { throw SnapshotError.invalid }
        return data
    }
    static var legacyExists: Bool { SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess }
    static func removeLegacy() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

final class CloudRequestScope {
    private let lock = NSLock()
    private var sessions: [UUID: URLSession] = [:]
    func insert(_ session: URLSession, id: UUID) { lock.lock(); defer { lock.unlock() }; sessions[id] = session }
    func remove(_ id: UUID) { lock.lock(); defer { lock.unlock() }; sessions.removeValue(forKey: id) }
    func cancel() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        active.forEach { $0.invalidateAndCancel() }
    }
}

struct CloudClient {
    let baseURL: URL
    let token: String?
    let scope: CloudRequestScope?
    private let authorityCheck: (() throws -> Void)?
    init(baseURL: String, token: String? = nil, scope: CloudRequestScope? = nil,
         authorityCheck: (() throws -> Void)? = nil) throws {
        let pairing = try Pairing(baseURL: baseURL, token: token ?? "validation")
        self.baseURL = pairing.endpoint.deletingLastPathComponent().deletingLastPathComponent()
        self.token = token
        self.scope = scope
        self.authorityCheck = authorityCheck
    }
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 20, encodedBody: Data? = nil, maximumResponseBytes: Int = 256 * 1024) async throws -> Data {
        try Task.checkCancellation()
        guard timeout > 0, (1...2 * 1024 * 1024).contains(maximumResponseBytes) else { throw SnapshotError.invalid }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = min(15, timeout)
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirectPolicy(), delegateQueue: nil)
        let requestID = UUID()
        scope?.insert(session, id: requestID)
        defer { scope?.remove(requestID); session.invalidateAndCancel() }
        let parts = path.split(separator: "?", maxSplits: 1)
        var components = URLComponents(url: baseURL.appendingPathComponent(String(parts[0])), resolvingAgainstBaseURL: false)!
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if body != nil || encodedBody != nil {
            request.httpBody = try encodedBody ?? body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            guard (request.httpBody?.count ?? 0) <= 32 * 1024 else { throw SnapshotError.invalid }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // The captured credential must still be the selected phone authority at
        // admission. Detached logout/erasure deliberately have no such lease.
        try authorityCheck?()
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw SnapshotError.response }
        if response.statusCode == 404 { throw CloudHTTPError.notFound }
        if response.statusCode == 401 { throw CloudHTTPError.unauthorized }
        var data = Data()
        let successful = (200..<300).contains(response.statusCode)
        for try await byte in bytes {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw SnapshotError.invalid }
            guard data.count < (successful ? maximumResponseBytes : 4096) else {
                if !successful { throw CloudHTTPError.classify(status: response.statusCode, data: Data(), retryAfter: response.value(forHTTPHeaderField: "Retry-After")) }
                throw SnapshotError.invalid
            }
            data.append(byte)
        }
        if !successful { throw CloudHTTPError.classify(status: response.statusCode, data: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After")) }
        return data
    }

    // No ownership callbacks or cancelled model scope: logout/switch callers
    // clear local authority first, then revoke their captured installation.
    static func revoke(_ session: CloudSession) async throws {
        let client = try Self(baseURL: session.baseURL.absoluteString,
                              token: session.refreshToken == nil ? session.token : nil)
        _ = try await client.request(session.refreshToken == nil ? "v2/auth/logout" : "v2/auth/revoke",
            method: "POST", body: session.refreshToken.map { ["refreshToken": $0] } ?? [:])
    }
}

enum CloudHTTPError: Error, Equatable {
    case notFound, unauthorized
    case rejected(status: Int, code: String?)
    case transient(status: Int, code: String?, retryAfter: TimeInterval)
    static func classify(status: Int, data: Data, retryAfter: String?) -> Self {
        if status == 401 { return .unauthorized }
        if status == 404 { return .notFound }
        let allowed: Set<String> = ["rate_limited", "early_budget_exhausted", "live_budget_exhausted",
            "refresh_too_soon", "refresh_in_progress", "live_slot_conflict", "live_unavailable",
            "background_collection_disabled", "collector_scope", "account_limit",
            "auto_interval_unavailable", "invalid_request", "idempotency_conflict"]
        let root = data.count <= 4096 ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        let candidate = root?["error"] as? String
        let code = candidate.flatMap { $0.utf8.count <= 64 && allowed.contains($0) ? $0 : nil }
        if status == 429, let code, code != "rate_limited" {
            return .rejected(status: status, code: code)
        }
        if status == 429 || [500, 502, 503, 504].contains(status) {
            var delay: TimeInterval = 1
            if let retryAfter {
                guard retryAfter.count <= 128 else { return .rejected(status: status, code: code) }
                let numeric = retryAfter.allSatisfy(\.isNumber) && !retryAfter.isEmpty ? Double(retryAfter) : nil
                let parser = DateFormatter()
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.timeZone = TimeZone(secondsFromGMT: 0)
                parser.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                let seconds = numeric ?? parser.date(from: retryAfter)?.timeIntervalSinceNow
                // Never shorten a valid server wait to fit our retry budget.
                guard let seconds, seconds.isFinite, seconds <= 60 else {
                    return .rejected(status: status, code: code)
                }
                delay = max(1, seconds)
            }
            return .transient(status: status, code: code, retryAfter: delay)
        }
        return .rejected(status: status, code: code)
    }
    var definitiveRejection: Bool {
        if case .rejected(let status, _) = self { return (400..<500).contains(status) }
        return false
    }
    var userMessage: String {
        let code: String?
        switch self {
        case .rejected(_, let value), .transient(_, let value, _): code = value
        case .unauthorized: return "Sign in again. Original observations retained."
        case .notFound: return "Requested resource unavailable. Original observations retained."
        }
        switch code {
        case "early_budget_exhausted": return "Today's 10 Free early refreshes are used. Due collection remains available; the allowance resets at KST midnight."
        case "live_budget_exhausted": return "Live allowance is used. Plus resets per verified subscription period; Pro resets at KST midnight."
        case "refresh_too_soon": return "Wait at least one minute between collection jobs. Original observations retained."
        case "refresh_in_progress": return "Another collector job is pending. Read the cached snapshot or try after it completes."
        case "live_slot_conflict": return "Stop the previous Live session before changing its slots."
        case "rate_limited": return "Server rate limit reached. Wait before trying again. Original observations retained."
        case "account_limit": return "Your verified tier's provider-slot limit is reached."
        default: return "Request refused or temporarily unavailable. Original observations retained."
        }
    }
    static func retryDelay(_ error: Error) -> TimeInterval? {
        if case let Self.transient(_, _, delay) = error { return delay }
        if error is DecodingError { return 1 }
        if case SnapshotError.invalid = error { return 1 }
        if case SnapshotError.response = error { return 1 }
        if let error = error as? URLError,
           [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) { return 1 }
        return nil
    }
}

// Every continuation resolves the SAME request key first. Persist only the
// exact command, not a bearer token, transport deadline or unverified job.
struct CloudRefreshIntent {
    let revision: Int
    let ids: [UUID]
    let mode: CloudJob.Mode
    let idempotencyKey: UUID
    let body: Data
    var deadline: TimeInterval
    var attempts = 0
    var job: CloudJob?
    init(revision: Int, ids: [UUID], mode: CloudJob.Mode, idempotencyKey: UUID = UUID()) throws {
        guard !ids.isEmpty, ids.count <= 50, Set(ids).count == ids.count else { throw SnapshotError.invalid }
        self.revision = revision; self.ids = ids; self.mode = mode
        self.idempotencyKey = idempotencyKey
        deadline = ProcessInfo.processInfo.systemUptime + 60
        body = try JSONSerialization.data(withJSONObject: ["accountIds": ids.map(\.uuidString),
            "mode": mode.rawValue, "idempotencyKey": idempotencyKey.uuidString], options: [.sortedKeys])
    }
    init(revision: Int, body: Data) throws {
        guard !body.isEmpty, body.count <= 4096,
              let root = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              Set(root.keys) == Set(["accountIds", "mode", "idempotencyKey"]),
              let rawIDs = root["accountIds"] as? [String], !rawIDs.isEmpty, rawIDs.count <= 50,
              let rawMode = root["mode"] as? String, let mode = CloudJob.Mode(rawValue: rawMode),
              let rawKey = root["idempotencyKey"] as? String, let key = UUID(uuidString: rawKey) else {
            throw SnapshotError.invalid
        }
        let ids = rawIDs.compactMap(UUID.init(uuidString:))
        guard ids.count == rawIDs.count, Set(ids).count == ids.count else { throw SnapshotError.invalid }
        self.revision = revision; self.ids = ids; self.mode = mode
        idempotencyKey = key; self.body = body
        deadline = ProcessInfo.processInfo.systemUptime + 60
    }
    mutating func continueOperation() throws {
        try Task.checkCancellation()
        attempts = 0
        deadline = ProcessInfo.processInfo.systemUptime + 60
    }
    mutating func beginAttempt() throws -> TimeInterval {
        try Task.checkCancellation()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard attempts < 2, remaining > 0 else { throw SnapshotError.response }
        attempts += 1
        return min(20, remaining)
    }
}

enum CloudRefreshIntentStore {
    private struct Record: Codable {
        let version: Int
        let sessionFingerprint: Data
        let body: Data
    }
    // Same private phone-only Keychain group as the cloud session. It is never
    // copied to an App Group, a widget, Watch or a provider collector.
    static var query: [String: Any] {
        var result = CloudSessionStore.query
        result[kSecAttrAccount as String] = "refresh-intent"
        return result
    }
    private static func fingerprint(_ session: CloudSession) throws -> Data {
        try session.validate()
        if let family = session.familyId, let expiry = session.refreshExpiresAt {
            guard expiry > Date() else { throw CloudHTTPError.unauthorized }
            let binding = session.baseURL.absoluteString + "\n" + family.uuidString.lowercased() + "\n" + String(expiry.timeIntervalSince1970)
            return Data(SHA256.hash(data: Data(binding.utf8)))
        }
        guard session.expiresAt > Date() else { throw CloudHTTPError.unauthorized }
        let binding = session.baseURL.absoluteString + "\n" + session.token + "\n" +
            String(session.expiresAt.timeIntervalSince1970)
        return Data(SHA256.hash(data: Data(binding.utf8)))
    }
    static func encode(_ intent: CloudRefreshIntent, session: CloudSession) throws -> Data {
        guard intent.mode != .live else { throw SnapshotError.invalid }
        _ = try CloudRefreshIntent(revision: intent.revision, body: intent.body)
        let data = try JSONEncoder().encode(Record(version: 1,
            sessionFingerprint: fingerprint(session), body: intent.body))
        guard data.count <= 8192 else { throw SnapshotError.invalid }
        return data
    }
    static func decode(_ data: Data, session: CloudSession, revision: Int) throws -> CloudRefreshIntent? {
        guard data.count <= 8192 else { throw SnapshotError.invalid }
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.version == 1 else { throw SnapshotError.invalid }
        guard record.sessionFingerprint == (try fingerprint(session)) else { return nil }
        let intent = try CloudRefreshIntent(revision: revision, body: record.body)
        guard intent.mode != .live else { throw SnapshotError.invalid }
        return intent
    }
    static func load(session: CloudSession, revision: Int) throws -> CloudRefreshIntent? {
        try load(session: session, revision: revision, copyMatching: SecItemCopyMatching)
    }
    static func load(session: CloudSession, revision: Int,
                     copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus) throws -> CloudRefreshIntent? {
        var q = query
        q[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = copyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SnapshotError.unpaired }
        let intent = try decode(data, session: session, revision: revision)
        if intent == nil { remove() }
        return intent
    }
    static func save(_ intent: CloudRefreshIntent, session: CloudSession) throws {
        try save(intent, session: session, update: SecItemUpdate, add: SecItemAdd)
    }
    static func save(_ intent: CloudRefreshIntent, session: CloudSession,
                     update: (CFDictionary, CFDictionary) -> OSStatus,
                     add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus) throws {
        // Restarting Live remains explicit opt-in through the server session.
        if intent.mode == .live { remove(); return }
        let attributes: [String: Any] = [kSecValueData as String: try encode(intent, session: session),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = update(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard add(item as CFDictionary, nil) == errSecSuccess else { throw SnapshotError.unpaired }
        } else if status != errSecSuccess { throw SnapshotError.unpaired }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

final class CloudReadBudget {
    let deadline: TimeInterval
    private var bytes = 0
    private var lastStart: TimeInterval?
    init(seconds: TimeInterval = CloudPagination.operationSeconds) {
        deadline = ProcessInfo.processInfo.systemUptime + seconds
    }
    func validate() throws {
        try Task.checkCancellation()
        guard bytes <= CloudPagination.maximumBytes,
              ProcessInfo.processInfo.systemUptime < deadline else { throw SnapshotError.invalid }
    }
    func fetch(_ path: String, client: CloudClient,
               beforeRequest: () throws -> Void = {}) async throws -> Data {
        try validate()
        if let lastStart {
            let wait = lastStart + 0.5 - ProcessInfo.processInfo.systemUptime
            if wait > 0 {
                guard ProcessInfo.processInfo.systemUptime + wait < deadline else { throw SnapshotError.invalid }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        try validate()
        try beforeRequest()
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, bytes < CloudPagination.maximumBytes else { throw SnapshotError.invalid }
        lastStart = ProcessInfo.processInfo.systemUptime
        let data = try await client.request(path, timeout: min(20, remaining))
        bytes += data.count
        try validate()
        return data
    }
}

// One read (including metadata and legacy fallback): 60 seconds monotonic,
// 8 MiB aggregate, 20 pages per endpoint (at most 5,000 slots).
// The transport separately caps each response at 256 KiB and refuses redirects.
struct CloudPagination {
    static let operationSeconds: TimeInterval = 60
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumPages = 20
    struct Page<Row: Decodable>: Decodable {
        let accounts: [Row]
        let nextCursor: UUID?
        init(accounts: [Row], nextCursor: UUID?) { self.accounts = accounts; self.nextCursor = nextCursor }
        enum CodingKeys: String, CodingKey { case accounts, nextCursor }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accounts = try values.decode([Row].self, forKey: .accounts)
            // Missing cursor is malformed, not an implicit end of the list.
            guard values.contains(.nextCursor) else { throw SnapshotError.invalid }
            nextCursor = try values.decodeIfPresent(UUID.self, forKey: .nextCursor)
        }
    }
    static func collect<Row: Decodable>(path: String, id: (Row) -> UUID,
        fetch: (String) async throws -> Data, decode: (Data) throws -> Page<Row>) async throws -> [Row] {
        var rows: [Row] = []
        var cursor: UUID?
        for _ in 0..<maximumPages {
            try Task.checkCancellation()
            let query = "?limit=250" + (cursor.map { "&after=\($0.uuidString.lowercased())" } ?? "")
            let page: Page<Row>
            do { page = try decode(try await fetch(path + query)) }
            catch CloudHTTPError.notFound {
                // Only a missing first page means this server lacks the endpoint.
                guard cursor == nil else { throw SnapshotError.invalid }
                throw CloudHTTPError.notFound
            }
            guard page.accounts.count <= 250 else { throw SnapshotError.invalid }
            var previous = cursor?.uuidString.lowercased()
            for row in page.accounts {
                let key = id(row).uuidString.lowercased()
                guard previous.map({ key > $0 }) ?? true else { throw SnapshotError.invalid }
                previous = key
            }
            if let next = page.nextCursor {
                guard let last = page.accounts.last, next == id(last) else { throw SnapshotError.invalid }
            }
            rows += page.accounts
            guard let next = page.nextCursor else { return rows }
            cursor = next
        }
        throw SnapshotError.invalid
    }
    static func accounts(fetch: (String) async throws -> Data) async throws -> [CloudAccount] {
        do {
            return try await collect(path: "v2/accounts/page", id: { $0.id }, fetch: fetch) {
                try JSONDecoder().decode(Page<CloudAccount>.self, from: $0)
            }
        } catch CloudHTTPError.notFound {
            struct Legacy: Decodable { let accounts: [CloudAccount] }
            let rows = try JSONDecoder().decode(Legacy.self, from: try await fetch("v2/accounts")).accounts
            guard rows.count <= 5000, Set(rows.map(\.id)).count == rows.count else { throw SnapshotError.invalid }
            return rows
        }
    }
    static func snapshot(slots: [CloudAccount]? = nil, fetch: (String) async throws -> Data) async throws -> CloudSnapshot {
        var generatedAt: Date?
        var ownedSlots = slots
        let rows: [CloudSnapshot.Account]
        do {
            rows = try await collect(path: "v2/snapshot/page", id: { $0.id }, fetch: fetch) { data in
                let snapshot = try CloudSnapshot.decode(data)
                guard !snapshot.demo, snapshot.cachedSubset != true else { throw SnapshotError.invalid }
                if generatedAt == nil { generatedAt = snapshot.generatedAt }
                struct Cursor: Decodable {
                    let nextCursor: UUID?
                    enum CodingKeys: String, CodingKey { case nextCursor }
                    init(from decoder: Decoder) throws {
                        let values = try decoder.container(keyedBy: CodingKeys.self)
                        guard values.contains(.nextCursor) else { throw SnapshotError.invalid }
                        nextCursor = try values.decodeIfPresent(UUID.self, forKey: .nextCursor)
                    }
                }
                return Page(accounts: snapshot.accounts, nextCursor: try JSONDecoder().decode(Cursor.self, from: data).nextCursor)
            }
        } catch CloudHTTPError.notFound {
            if ownedSlots == nil { ownedSlots = try await accounts(fetch: fetch) }
            let legacy = try CloudSnapshot.decode(try await fetch("v2/snapshot"))
            guard !legacy.demo, legacy.cachedSubset != true else { throw SnapshotError.invalid }
            generatedAt = legacy.generatedAt
            rows = legacy.accounts
        }
        guard rows.count <= 5000, Set(rows.map(\.id)).count == rows.count,
              let generatedAt else { throw SnapshotError.invalid }
        if let slots = ownedSlots {
            guard slots.count <= 5000, Set(slots.map(\.id)).count == slots.count else { throw SnapshotError.invalid }
            let owned = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.provider) })
            guard rows.count == slots.count,
                  rows.allSatisfy({ owned[$0.id] == $0.provider }) else { throw SnapshotError.invalid }
        }
        return CloudSnapshot(schemaVersion: 2, generatedAt: generatedAt, demo: false, accounts: rows)
    }
}

@MainActor
final class CloudModel: NSObject, ObservableObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static let cachedStatus = "Cached server observations. Local collector required for new readings. Offline cache is limited to the first 50 slots if the full sanitized result exceeds 256 KiB; it is not a complete account list."
    let purchases = PurchasesModel()
    private let accountLabels = CloudAccountLabels()
    var labelScope: String? {
        guard let session, let authority = session.familyId ?? connectionGeneration else { return nil }
        return CloudAccountLabels.scope(server: session.baseURL, authority: authority)
    }
    func accountLabel(_ id: UUID) -> String {
        guard let labelScope else { return "" }
        return accountLabels.label(scope: labelScope, slot: id)
    }
    func accountTitle(_ id: UUID, provider: ProviderID) -> String {
        let label = accountLabel(id)
        return "\(provider.displayName) · \(label.isEmpty ? String(id.uuidString.prefix(8)) : label)"
    }
    func setAccountLabel(_ value: String, id: UUID) {
        guard let labelScope, slots.contains(where: { $0.id == id }) else { return }
        objectWillChange.send()
        if !accountLabels.set(value, scope: labelScope, slot: id) {
            status = "Local account label limit reached. Clear an unused label first."
        }
    }
    var connectionGeneration = try? SnapshotStore.prepareGeneration()
    @Published var session = CloudSessionStore.load() {
        didSet {
            if let oldValue, let session, session.sameAuthority(as: oldValue) { return }
            renewalTask?.task.cancel()
            renewalTask = nil
            revision += 1; refreshIntent = nil; loadedIntent = false; pendingEntitlementRead = false
            reading = false; readingRevision = nil; requests.cancel()
        }
    }
    @Published var snapshot = CloudSessionStore.load() == nil ? nil : CloudCache.load()
    @Published var slots: [CloudAccount] = [] {
        didSet {
            refreshSelection.reconcile(slots: slots)
            if let intent = refreshIntent, !CloudBatchSelection.valid(intent.ids, slots: slots) { refreshIntent = nil }
        }
    }
    @Published private(set) var refreshSelection = CloudBatchSelection()
    var selectionLocked: Bool { liveEnabled || me?.liveSession != nil || !liveSlotIDs.isEmpty }
    func selectRefreshSlots(_ ids: [UUID]) {
        guard !busy, !selectionLocked else { return }
        if !refreshSelection.select(ids, slots: slots) {
            status = "Select distinct owned slots, at most 50 per batch."
        } else if refreshIntent?.ids != ids {
            refreshIntent = nil
        }
    }
    @Published var status = "Cloud is optional. A local collector is required; this phone cannot collect provider quotas."
    @Published var budget = ""
    @Published var busy = false
    @Published var me: CloudMe?
    @Published var collectors: [CloudCollector] = []
    @Published var liveEnabled = false
    @Published var liveDeadline: Date?
    private var liveTask: Task<Void, Never>?
    private var liveStartedAt: Date?
    private var liveSlotIDs: [UUID] = []
    private var lastLiveRequest: Date?
    private var reading = false
    private var readingRevision: Int?
    private var pendingEntitlementRead = false
    private var loadedIntent = false
    private var refreshIntent: CloudRefreshIntent? {
        didSet { if refreshIntent == nil, loadedIntent { CloudRefreshIntentStore.remove() } }
    }
    let requests = CloudRequestScope()
    @Published var pendingMFA: CloudMFAChallenge?
    @Published var pendingRecoveryCodes: [String] = []
    var securityEpoch = 0
    private var renewalTask: (id: UUID, task: Task<CloudClient, Error>)?
    var foreground = true {
        didSet {
            if !foreground { securityEpoch += 1; pendingRecoveryCodes = []; pendingMFA = nil; renewalTask?.task.cancel(); pollingTask?.cancel(); liveTask?.cancel(); requests.cancel() }
            else if liveEnabled { scheduleLive() }
        }
    }
    var revision = 0
    var onSwitch: (() -> Void)?
    var onSnapshot: ((Snapshot) -> Void)?
    private var challenge: (id: String, base: String, revision: Int)?
    private var controller: ASAuthorizationController?
    private var pollingTask: Task<Void, Never>?
    private func leasedClient(_ session: CloudSession) throws -> CloudClient {
        let generation = connectionGeneration
        return try CloudClient(baseURL: session.baseURL.absoluteString, token: session.token, scope: requests,
            authorityCheck: { try ConnectionStore.assertCloud(session, generation: generation) })
    }
    var client: CloudClient? {
        guard let session else { return nil }
        guard session.expiresAt > Date() else {
            if session.familyId == nil { requireSignIn() }
            return nil
        }
        return try? leasedClient(session)
    }
    func authorizedClient(fetchRenewal: ((Data) async throws -> Data)? = nil,
                          save: ((CloudSession) throws -> Void)? = nil) async throws -> CloudClient {
        guard foreground, !Task.isCancelled, let original = session else { throw CancellationError() }
        if let renewalTask {
            let current = revision
            let result = try await renewalTask.task.value
            try Task.checkCancellation()
            guard foreground, revision == current, session?.token == result.token else { throw CancellationError() }
            return result
        }
        // Leave a 60-second read budget plus the accepted 60-second clock
        // allowance and a small margin before reusing an existing bearer.
        if original.pendingRenewal == nil, original.expiresAt.timeIntervalSinceNow > 130 {
            return try leasedClient(original)
        }
        guard let refresh = original.refreshToken, let expiry = original.refreshExpiresAt, expiry > Date() else {
            if original.expiresAt <= Date() { requireSignIn(); throw CloudHTTPError.unauthorized }
            return try leasedClient(original)
        }
        let current = revision
        let generation = connectionGeneration
        let task = Task { @MainActor () async throws -> CloudClient in
            try Task.checkCancellation()
            guard self.foreground, self.revision == current else { throw CancellationError() }
            @MainActor func persist(_ next: CloudSession) throws {
                guard let previous = self.session else { throw CancellationError() }
                if let save { try save(next) }
                else { try ConnectionStore.renew(next, replacing: previous, generation: generation) }
            }
            var pending = original
            if pending.pendingRenewal == nil {
                pending.pendingRenewal = UUID()
                pending.pendingRenewalStartedAt = Date()
                pending.pendingRenewalSends = 0
                try persist(pending)
                self.session = pending
            }
            guard let started = pending.pendingRenewalStartedAt else { throw SnapshotError.invalid }
            let elapsed = Date().timeIntervalSince(started)
            guard elapsed >= 0, elapsed < 60 else { throw SnapshotError.invalid }
            // Old purchase delivery uses the old bearer. Disable it until a
            // validated /me read reconfigures delivery for the new credential.
            self.purchases.configure(client: nil, accountToken: nil, available: false, onVerified: {})
            let body = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh,
                "idempotencyKey": pending.pendingRenewal!.uuidString.lowercased()], options: [.sortedKeys])
            let transport = try CloudClient(baseURL: original.baseURL.absoluteString, scope: self.requests,
                authorityCheck: { try ConnectionStore.assertCloud(original, generation: generation) })
            let deadline = ProcessInfo.processInfo.systemUptime + (60 - elapsed)
            for attempt in 0..<2 {
                try Task.checkCancellation()
                guard self.foreground, self.revision == current, self.session?.token == original.token else { throw CancellationError() }
                do {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0, (pending.pendingRenewalSends ?? 0) < 2 else { throw SnapshotError.invalid }
                    // Reserve each send durably, including a cancelled/unknown
                    // send. Restart must not reset the two-send limit.
                    pending.pendingRenewalSends = (pending.pendingRenewalSends ?? 0) + 1
                    try persist(pending)
                    self.session = pending
                    let data: Data
                    if let fetchRenewal { data = try await fetchRenewal(body) }
                    else { data = try await transport.request("v2/auth/refresh", method: "POST", timeout: min(20, remaining), encodedBody: body) }
                    let next = try CloudSession.login(data, baseURL: original.baseURL, previous: original)
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime < deadline, self.foreground,
                          self.revision == current, self.session?.token == original.token else { throw CancellationError() }
                    try persist(next)
                    self.session = next
                    return try self.leasedClient(next)
                } catch {
                    guard attempt == 0, let delay = CloudHTTPError.retryDelay(error),
                          ProcessInfo.processInfo.systemUptime + delay < deadline else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            throw SnapshotError.invalid
        }
        let renewalID = UUID()
        renewalTask = (renewalID, task)
        defer { if renewalTask?.id == renewalID { renewalTask = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        guard foreground, revision == current, session?.token == result.token else { throw CancellationError() }
        return result
    }
    private func requireSignIn() {
        let rejected = session
        var persisted = false
        if let rejected {
            do { try ConnectionStore.reject(rejected, generation: connectionGeneration); persisted = true }
            catch { /* The storage boundary fences restart if authority replacement failed. */ }
        }
        revision += 1
        CloudRefreshIntentStore.remove()
        requests.cancel()
        purchases.configure(client: nil, accountToken: nil, available: false, onVerified: {})
        pollingTask?.cancel(); liveTask?.cancel(); liveEnabled = false
        refreshIntent = nil; busy = false; reading = false; readingRevision = nil; me = nil; session = nil
        liveDeadline = nil; liveStartedAt = nil; liveSlotIDs = []; lastLiveRequest = nil
        collectors = []
        status = persisted ? "Sign in again — cloud session expired or rejected. Original observations retained."
            : "Sign in again — connection blocked. Persistent disconnection could not be confirmed; unlock the phone and reconnect."
    }
    private func handleUnauthorized(_ error: Error) -> Bool {
        guard case CloudHTTPError.unauthorized = error else { return false }
        requireSignIn(); return true
    }

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(protectedDataUnavailable), name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
    }
    @objc private func protectedDataUnavailable() { foreground = false }

    func connect(base: String, quotaStorageConsent: Bool, collectorProcessingConsent: Bool) async {
        guard !busy, !reading, foreground else { return }
        guard quotaStorageConsent, collectorProcessingConsent else {
            status = "Consent required for quota storage and local collector processing. No sign-in started."
            return
        }
        busy = true
        let current = revision
        do {
            let client = try CloudClient(baseURL: base, scope: requests)
            let data = try await client.request("v2/auth/challenge", method: "POST", body: [:])
            let response = try CloudChallenge.decode(data)
            guard current == revision, foreground, !Task.isCancelled else {
                if current == revision { busy = false }
                return
            }
            challenge = (response.challengeId, base, current)
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = []
            request.nonce = response.nonce
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        } catch {
            if current == revision {
                status = "Cloud sign-in unavailable. Check HTTPS/DNS, server Apple configuration and your signed Apple capability."
                busy = false
            }
        }
    }
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard self.controller === controller else { return }
        challenge = nil; self.controller = nil; busy = false
        status = "Apple authorization did not complete. No cloud account was connected."
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard self.controller === controller else { return }
        guard let challenge, let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken, let jwt = String(data: data, encoding: .utf8) else {
            self.challenge = nil; self.controller = nil
            busy = false; status = "Apple did not return an identity token."; return
        }
        self.challenge = nil; self.controller = nil
        Task {
            defer { if revision == challenge.revision { busy = false } }
            do {
                guard revision == challenge.revision, foreground, !Task.isCancelled else { return }
                let client = try CloudClient(baseURL: challenge.base, scope: requests)
                let data = try await client.request("v2/auth/apple", method: "POST", body: [
                    "challengeId": challenge.id, "identityToken": jwt,
                    "consent": ["quotaStorage": true, "collectorProcessing": true]])
                if let factor = try CloudMFAChallenge.decodeIfRequired(data, base: client.baseURL) {
                    guard revision == challenge.revision, foreground, !Task.isCancelled else { return }
                    pendingMFA = factor
                    return
                }
                let next = try CloudSession.login(data, baseURL: client.baseURL)
                guard revision == challenge.revision else {
                    try? await CloudClient.revoke(next)
                    return
                }
                guard foreground, !Task.isCancelled else {
                    try? await CloudClient.revoke(next)
                    throw CancellationError()
                }
                await installLogin(next)
            } catch { if revision == challenge.revision { status = "Server sign-in failed. No cloud session saved." } }
        }
    }
    func installLogin(_ next: CloudSession) async {
                let generation: UUID
                do { generation = try ConnectionStore.select(.cloud, credential: CloudSessionStore.encoded(next)) }
                catch {
                    resetMemory()
                    onSwitch?()
                    status = "Connection blocked. Persistent disconnection could not be confirmed; unlock the phone and reconnect."
                    try? await CloudClient.revoke(next)
                    return
                }
                let old = session
                resetMemory()
                connectionGeneration = generation
                session = next
                onSwitch?()
                if let old {
                    let selectedRevision = revision
                    Task {
                        do { try await CloudClient.revoke(old) }
                        catch {
                            guard revision == selectedRevision else { return }
                            status = "Previous cloud logout unconfirmed. Its login family may remain valid for up to 30 days."
                        }
                    }
                }
                await read(internalWork: true)
    }
    // Memory-only invalidation after a durable selection; never delete or
    // select another authority as a side effect of installing the new one.
    func resetMemory() {
        securityEpoch += 1
        pendingRecoveryCodes = []
        pendingMFA = nil
        pollingTask?.cancel()
        CloudRefreshIntentStore.remove()
        refreshIntent = nil
        requests.cancel()
        purchases.configure(client: nil, accountToken: nil, available: false, onVerified: {})
        liveTask?.cancel(); liveEnabled = false; liveDeadline = nil; liveStartedAt = nil; me = nil; collectors = []
        liveSlotIDs = []; lastLiveRequest = nil
        busy = false; reading = false; readingRevision = nil
        revision += 1; challenge = nil; controller = nil; session = nil; snapshot = nil; slots = []; budget = ""
        refreshSelection = CloudBatchSelection()
        connectionGeneration = SnapshotStore.generation
    }
    @discardableResult
    func clear() -> Bool {
        if let labelScope { accountLabels.remove(scope: labelScope) }
        var committed = false
        do { try ConnectionStore.select(.signedOut); committed = true }
        catch { /* Keep the process blocked if either persistent write failed. */ }
        resetMemory()
        onSwitch?()
        if !committed { status = "Connection blocked. Persistent disconnection could not be confirmed; unlock the phone and reconnect." }
        return committed
    }
    func disconnect(delete: Bool) async {
        let captured = session
        let owner = revision
        let old: CloudClient?
        if delete { old = try? await authorizedClient() }
        else { old = nil }
        // Do not clear a different account selected while renewal was suspended.
        // A settings mutation may advance the read revision without switching
        // authority. A cleared session/new Apple challenge is never equivalent.
        guard revision == owner || captured.map({ session?.sameAuthority(as: $0) == true }) == true else { return }
        let locallyDisconnected = clear()
        let current = revision
        if delete {
            busy = true
            status = locallyDisconnected ? "Local account cleared. Waiting for server erasure confirmation."
                : "Connection blocked. Persistent disconnection could not be confirmed; unlock the phone and reconnect."
        }
        defer { if delete, revision == current { busy = false } }
        do {
            if delete {
                guard let old else { throw CloudHTTPError.unauthorized }
                let detached = try CloudClient(baseURL: old.baseURL.absoluteString, token: old.token)
                _ = try await detached.request("v2/me", method: "DELETE", body: [:])
            } else {
                guard let captured else { throw CloudHTTPError.unauthorized }
                try await CloudClient.revoke(captured)
            }
            guard revision == current else { return }
            if !locallyDisconnected {
                status = "Server disconnection confirmed, but local persistence failed. Unlock the phone and disconnect again."
            } else if !ConnectionStore.cleanupComplete {
                status = "Disconnected. Inactive local data cleanup is incomplete; old credentials cannot be selected."
            } else { status = delete ? "Cloud account erased." : "Signed out." }
        } catch { if revision == current {
            status = locallyDisconnected
                ? "Local session cleared; server erasure/revocation could not be confirmed. Reconnect to retry erasure. A login family may remain valid for up to 30 days."
                : "Connection blocked. Local persistence and server disconnection could not be confirmed. Unlock the phone and disconnect again."
        } }
    }
    func read(internalWork: Bool = false, entitlementsOnly: Bool = false,
              fetchData: ((String) async throws -> Data)? = nil,
              intentCopyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching) async {
        guard session != nil, (!busy || internalWork), foreground, !Task.isCancelled else { return }
        if reading, readingRevision == revision {
            if entitlementsOnly { pendingEntitlementRead = true }
            return
        }
        let current = revision
        let generation = connectionGeneration
        reading = true
        readingRevision = current
        defer {
            if readingRevision == current {
                reading = false
                readingRevision = nil
                if current == revision, pendingEntitlementRead {
                    pendingEntitlementRead = false
                    Task { [weak self] in
                        guard let self, self.revision == current else { return }
                        await self.read(internalWork: true, entitlementsOnly: true, fetchData: fetchData)
                    }
                }
            }
        }
        do {
            let client = try await authorizedClient()
            let operation = CloudReadBudget()
            func fetch(_ path: String) async throws -> Data {
                guard current == revision, foreground else { throw CancellationError() }
                guard let session, session.expiresAt > Date() else { throw CloudHTTPError.unauthorized }
                let data: Data
                if let fetchData { data = try await fetchData(path) }
                else {
                    data = try await operation.fetch(path, client: client) {
                        guard current == revision, foreground else { throw CancellationError() }
                        guard session.expiresAt > Date() else { throw CloudHTTPError.unauthorized }
                    }
                }
                guard current == revision, foreground else { throw CancellationError() }
                guard session.expiresAt > Date() else { throw CloudHTTPError.unauthorized }
                return data
            }
            let verified = try CloudMe.decode(try await fetch("v2/me"))
            let next: CloudSnapshot?
            if entitlementsOnly { next = nil }
            else { next = try await CloudPagination.snapshot(fetch: fetch) }
            struct Collectors: Decodable { let collectors: [CloudCollector] }
            let paired: Collectors?
            if entitlementsOnly { paired = nil }
            else {
                do { paired = try JSONDecoder().decode(Collectors.self, from: try await fetch("v2/collectors")) }
                catch CloudHTTPError.unauthorized { throw CloudHTTPError.unauthorized }
                catch { try Task.checkCancellation(); paired = nil }
            }
            try operation.validate()
            guard current == revision, generation == connectionGeneration,
                  let activeSession = session, foreground, !Task.isCancelled else { return }
            if let next {
                let nextSlots = next.accounts.map { CloudAccount(id: $0.id, provider: $0.provider) }
                slots = nextSlots; snapshot = next
                if !loadedIntent {
                    do {
                        let stored = try CloudRefreshIntentStore.load(session: activeSession, revision: current,
                            copyMatching: intentCopyMatching)
                        if let stored {
                            guard CloudBatchSelection.valid(stored.ids, slots: nextSlots) else { throw SnapshotError.invalid }
                            refreshIntent = stored
                            _ = refreshSelection.select(stored.ids, slots: nextSlots)
                        }
                        loadedIntent = true
                    } catch {
                        if handleUnauthorized(error) { return }
                        // Keep the unresolved record and retry recovery on the next
                        // read. Verified observations remain independently useful.
                    }
                }
                if liveEnabled, !CloudBatchSelection.valid(liveSlotIDs, slots: nextSlots) {
                    liveEnabled = false; liveTask?.cancel()
                }
                collectors = paired?.collectors ?? []
            }
            self.me = verified
            purchases.configure(client: client, accountToken: verified.appAccountToken,
                available: verified.purchasesAvailable && activeSession.expiresAt > Date(),
                onUnauthorized: { [weak self] in
                    guard let self, self.revision == current, self.session?.token == client.token else { return }
                    self.requireSignIn()
                }) { [weak self] in
                guard let self, self.revision == current else { return }
                await self.read(internalWork: true, entitlementsOnly: true)
            }
            reconcileLive(verified: verified)
            budget = verified.budget
            if !verified.limits.live { liveEnabled = false; liveTask?.cancel() }
            if let next {
                let cached = CloudCache.save(next, generation: generation)
                onSnapshot?(next.smallSurfaceSnapshot)
                status = Self.cachedStatus
                if !loadedIntent {
                    status = "Cached server observations. Refresh blocked until saved request recovery succeeds; retry reading or explicitly clear/sign out."
                } else if !cached {
                    status = "Readings received, but offline cache could not be saved. Original observation times retained."
                } else if !ConnectionStore.cleanupComplete {
                    status = "Connected. Inactive local data cleanup is incomplete; old credentials cannot be selected."
                }
            }
        } catch {
            if current == revision {
                if handleUnauthorized(error) { return }
                status = session?.pendingRenewal == nil
                    ? "Cloud read unavailable or session expired. Original observations retained; sign in again if needed."
                    : "Login renewal unconfirmed. Log out and reconnect with Apple if reading cannot recover it. Original observations retained."
            }
        }
    }
    func mutate(path: String, method: String, body: [String: Any] = [:]) async {
        guard !busy, !reading, !liveEnabled, foreground, !Task.isCancelled else { return }
        busy = true
        var current = revision
        defer { if current == revision { busy = false } }
        do {
            let client = try await authorizedClient()
            guard current == revision, foreground, (session?.expiresAt ?? .distantPast) > Date() else { throw CancellationError() }
            _ = try await client.request(path, method: method, body: body)
            guard current == revision else { return }
            if path == "v2/live/stop" { liveDeadline = nil; liveStartedAt = nil; liveSlotIDs = []; lastLiveRequest = nil }
            revision += 1
            refreshIntent = nil
            pendingEntitlementRead = false
            current = revision
            if method == "DELETE", path.hasPrefix("v2/accounts/") {
                if let labelScope, let id = UUID(uuidString: String(path.dropFirst("v2/accounts/".count))) {
                    accountLabels.set("", scope: labelScope, slot: id)
                }
                do {
                    guard let session else { throw SnapshotError.unpaired }
                    connectionGeneration = try ConnectionStore.select(.cloud, credential: CloudSessionStore.encoded(session))
                } catch {
                    resetMemory(); onSwitch?()
                    status = "Connection blocked. Persistent disconnection could not be confirmed; unlock the phone and reconnect."
                    return
                }
                snapshot = nil
                slots.removeAll { path.hasSuffix($0.id.uuidString) }
                onSwitch?()
            }
            await read(internalWork: true)
        } catch { if current == revision {
            if handleUnauthorized(error) { return }
            status = (error as? CloudHTTPError)?.userMessage ?? "Request unavailable. Original observations retained."
        } }
    }
    func refresh(force: Bool, live: Bool = false) async {
        guard !busy, !reading, foreground, !Task.isCancelled, !liveEnabled || live else { return }
        guard !slots.isEmpty else { await read(); return }
        guard loadedIntent else {
            status = "Refresh blocked until saved request recovery succeeds; retry reading or explicitly clear/sign out."
            return
        }
        let ids = live ? liveSlotIDs : refreshSelection.ids
        guard CloudBatchSelection.valid(ids, slots: slots) else {
            status = "Select 1–50 distinct owned slots per refresh."; return
        }
        busy = true
        let current = revision
        defer { if current == revision { busy = false } }
        do {
            let client = try await authorizedClient()
            guard current == revision, foreground else { throw CancellationError() }
            if live { lastLiveRequest = Date() }
            var mode: CloudJob.Mode = live ? .live : force ? .force : .auto
            // Foreground auto-refresh must not replace an unconfirmed forced
            // command with a new key after a restart (or a manual retry).
            if !live, let intent = refreshIntent, intent.revision == current,
               intent.ids == ids, intent.mode != .live { mode = intent.mode }
            let resuming = refreshIntent?.revision == current && refreshIntent?.ids == ids && refreshIntent?.mode == mode
            if refreshIntent?.revision != current || refreshIntent?.ids != ids || refreshIntent?.mode != mode {
                refreshIntent = try CloudRefreshIntent(revision: current, ids: ids, mode: mode)
            } else {
                try refreshIntent?.continueOperation()
            }
            guard let activeSession = session, let intent = refreshIntent else { throw CloudHTTPError.unauthorized }
            // A durable command precedes the first send. Keychain failure must
            // not silently degrade to a possibly duplicated in-memory send.
            try CloudRefreshIntentStore.save(intent, session: activeSession)
            if resuming, refreshIntent?.job == nil, let intent = refreshIntent {
                guard activeSession.expiresAt > Date() else { throw CloudHTTPError.unauthorized }
                let data = try await client.request("v2/jobs/request/\(intent.idempotencyKey.uuidString)",
                    timeout: min(20, activeSession.expiresAt.timeIntervalSinceNow))
                guard current == revision, foreground, !Task.isCancelled else { return }
                refreshIntent?.job = try CloudJob.lookup(data, requested: ids, mode: mode)
            }
            while refreshIntent?.job == nil {
                guard current == revision, foreground,
                      liveDeadline.map({ !live || Date() < $0 }) ?? true else { throw CancellationError() }
                guard let session, session.expiresAt > Date() else { throw CloudHTTPError.unauthorized }
                guard let timeout = try refreshIntent?.beginAttempt(), let body = refreshIntent?.body else {
                    status = "Refresh cancelled because its selected slots changed. Original observations retained."
                    return
                }
                do {
                    let data = try await client.request("v2/refresh", method: "POST", timeout: min(timeout, session.expiresAt.timeIntervalSinceNow), encodedBody: body)
                    guard current == revision, foreground, !Task.isCancelled else { return }
                    refreshIntent?.job = try CloudJob.decode(data, requested: ids, mode: mode)
                } catch {
                    if let failure = error as? CloudHTTPError, failure.definitiveRejection {
                        refreshIntent = nil
                        throw failure
                    }
                    guard current == revision, foreground, !Task.isCancelled,
                          let delay = CloudHTTPError.retryDelay(error), let intent = refreshIntent,
                          intent.attempts < 2, ProcessInfo.processInfo.systemUptime + delay < intent.deadline,
                          Date().addingTimeInterval(delay) < session.expiresAt else { throw error }
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            guard let job = refreshIntent?.job else { return }
            guard current == revision, foreground, !Task.isCancelled else { return }
            if job.status == .pending {
                status = "Waiting for local collector — quota has not been updated."
                let remaining = max(0, (refreshIntent?.deadline ?? 0) - ProcessInfo.processInfo.systemUptime)
                let task = Task { await poll(client: client, current: current, job: job, requested: ids, seconds: remaining) }
                pollingTask = task
                await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
                if current == revision { pollingTask = nil }
            } else {
                refreshIntent = nil
                await read(internalWork: true)
                guard current == revision, foreground else { return }
                status = job.status == .cached ? "No selected slots were due. Showing original observations." :
                    job.status == .expired ? "Collector job expired. Original observations retained." :
                    "Collector processing completed; this does not guarantee fresh quota. Check observation time and collection warnings."
            }
        } catch { if current == revision {
            if handleUnauthorized(error) { return }
            if let failure = error as? CloudHTTPError {
                status = failure.userMessage
            } else {
                status = "Refresh outcome unconfirmed. Original observations retained; retry resolves the same request before any resend. No new key is issued for this unchanged batch."
            }
        } }
    }

    func startLive() {
        guard me?.limits.live == true, !busy, !reading else { return }
        guard liveDeadline.map({ Date() < $0 }) ?? true else { status = "Stop the previous Live session before starting another."; return }
        if let active = me?.liveSession {
            liveSlotIDs = active.accountIds
            liveDeadline = active.deadlineDate
        }
        if liveSlotIDs.isEmpty { liveSlotIDs = refreshSelection.ids }
        guard CloudBatchSelection.valid(liveSlotIDs, slots: slots) else {
            status = "Live requires 1–50 distinct owned slots. Stop an obsolete session before changing slots."; return
        }
        if liveStartedAt == nil { liveStartedAt = Date() }
        liveEnabled = true
        scheduleLive()
    }

    func stopLive() async {
        let current = revision
        liveEnabled = false; liveTask?.cancel(); pollingTask?.cancel()
        for _ in 0..<25 where busy || reading {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard current == revision else { return }
        await mutate(path: "v2/live/stop", method: "POST")
    }

    private func scheduleLive() {
        liveTask?.cancel()
        let current = revision
        liveTask = Task {
            while !Task.isCancelled, foreground, liveEnabled, current == revision {
                if let liveDeadline, Date() >= liveDeadline { liveEnabled = false; return }
                // Terminal jobs refresh quota pages; preflight only needs the
                // current tier and authoritative Live session/deadline.
                if !busy, !reading { await read(entitlementsOnly: true) }
                guard liveEnabled, foreground, current == revision, !Task.isCancelled else { return }
                if busy || reading {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                    catch { return }
                    continue
                }
                if let lastLiveRequest {
                    let wait = 60 - Date().timeIntervalSince(lastLiveRequest)
                    if wait > 0 {
                        do { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                        catch { return }
                    }
                }
                guard liveEnabled, foreground, current == revision, !Task.isCancelled else { return }
                if let liveDeadline, Date() >= liveDeadline { liveEnabled = false; return }
                // Failed first collection has no server deadline or charge.
                // Bound unconfirmed attempts locally rather than run indefinitely.
                if liveDeadline == nil, let liveStartedAt, Date().timeIntervalSince(liveStartedAt) >= 1800 {
                    liveEnabled = false; status = "Live deadline unconfirmed. Checks paused; stop before starting a new session."; return
                }
                let started = Date()
                await refresh(force: false, live: true)
                if liveDeadline == nil {
                    liveEnabled = false
                    status = "Live deadline unconfirmed. Automatic checks paused; explicitly resume to retry. The server alone charges fresh successes."
                    return
                }
                do { try await Task.sleep(nanoseconds: UInt64(max(1, 60 - Date().timeIntervalSince(started)) * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    private func reconcileLive(verified: CloudMe) {
        guard liveEnabled else { return }
        guard let active = verified.liveSession else {
            if lastLiveRequest == nil && liveDeadline == nil { return }
            liveEnabled = false; liveTask?.cancel(); return
        }
        guard Set(active.accountIds) == Set(liveSlotIDs) else {
            liveEnabled = false; liveTask?.cancel(); return
        }
        // Source observation time is not the server's first completion time.
        // Always use the authoritative deadline, including cross-device resumes.
        liveDeadline = active.deadlineDate
    }

    private func poll(client: CloudClient, current: Int, job: CloudJob, requested: [UUID], seconds: TimeInterval) async {
        // Cancellation on leaving foreground cancels sleeps and URLSession async requests.
        let operation = CloudReadBudget(seconds: min(60, seconds))
        let deadline = operation.deadline
        do {
            for _ in 0..<12 {
                let wait = min(5, deadline - ProcessInfo.processInfo.systemUptime)
                guard wait > 0 else { break }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard foreground, current == revision, let session else { return }
                guard session.expiresAt > Date() else { requireSignIn(); return }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { break }
                func fetch(_ path: String) async throws -> Data {
                    guard foreground, current == revision else { throw CancellationError() }
                    guard session.expiresAt > Date() else { throw CloudHTTPError.unauthorized }
                    return try await operation.fetch(path, client: client)
                }
                let result = try CloudJob.decode(try await fetch("v2/jobs/\(job.id.uuidString)"),
                    requested: requested, mode: job.mode, previous: job)
                try Task.checkCancellation()
                guard foreground, current == revision else { return }
                guard session.expiresAt > Date() else { requireSignIn(); return }
                if result.status != .pending {
                    refreshIntent = nil
                    await read(internalWork: true)
                    guard current == revision, foreground, !Task.isCancelled else { return }
                    status = result.status == .expired ? "Collector job expired. Original observations retained." :
                        "Collector processing completed; this does not guarantee fresh quota. Check observation time and collection warnings."
                    return
                }
                status = "This collector job is pending; showing cached observations. Waiting ends after 60 seconds."
            }
            status = "Collector wait timed out. Cached observations retained; retry later."
        } catch {
            if current == revision {
                if handleUnauthorized(error) { return }
                status = "Collector wait stopped or unavailable. Original observations retained."
            }
        }
    }
}

struct CloudReadingsView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: CloudModel
    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 16) {
            if model.status != CloudModel.cachedStatus {
                Text(DockL10n.text(model.status)).font(.caption)
            }
            if model.snapshot?.cachedSubset == true {
                Text(DockL10n.text("Offline cache: first 50 slots only, not the complete account list. Original observation times retained.")).font(.caption)
            }
            ForEach(model.snapshot?.accounts ?? []) { account in
                let label = model.accountLabel(account.id)
                ProviderCard(provider: account.reading, demo: model.snapshot?.demo == true,
                    accountLabel: label.isEmpty ? String(account.id.uuidString.prefix(8)) : label)
                if account.lastError != nil { Text(DockL10n.text("Last collection unavailable; original observation retained.")).font(.caption) }
            }
        }
    }
}

struct CloudBatchView: View {
    @Environment(\.locale) private var locale
    let slots: [CloudAccount]
    let ids: [UUID]
    let locked: Bool
    var label: (UUID) -> String = { _ in "" }
    let select: ([UUID]) -> Void
    var body: some View {
        let _ = locale
        Section(DockL10n.format("Refresh batch · %d/50", ids.count)) {
            Text(DockL10n.text("Force, foreground auto and new Live use these slots. First 50 are selected initially; registration remains tier-dependent. Stop Live before changing its batch; resumed Live keeps the server's slot set.")).font(.caption)
            ForEach(slots) { slot in
                Toggle(isOn: Binding(get: {
                    ids.contains(slot.id)
                }, set: { enabled in
                    var next = ids
                    if enabled { next.append(slot.id) } else { next.removeAll { $0 == slot.id } }
                    select(next)
                })) {
                    HStack {
                        ProviderIcon(id: slot.provider)
                        Text("\(slot.provider.displayName) · \(label(slot.id).isEmpty ? String(slot.id.uuidString.prefix(8)) : label(slot.id))")
                    }
                }.disabled(locked || (!ids.contains(slot.id) && ids.count >= 50))
            }
        }
    }
}

#if DEBUG
// Isolated UI sample: no Apple identity, session, entitlement or network client.
struct CloudBatchPreview: View {
    @Environment(\.locale) private var locale
    @State private var selection: [UUID] = []
    private let slots = [ProviderID.claude, .codex, .codex, .gemini, .grok].enumerated().map { index, provider in
        CloudAccount(id: UUID(uuidString: "0000000\(index)-0000-4000-8000-000000000000")!, provider: provider)
    }
    var body: some View {
        let _ = locale
        NavigationStack {
            Form {
                Text(DockL10n.text("DEMO · selection sample only, no account or server")).font(.headline)
                CloudBatchView(slots: slots, ids: selection, locked: false) { ids in
                    if ids.isEmpty || CloudBatchSelection.valid(ids, slots: slots) { selection = ids }
                }
            }.navigationTitle(DockL10n.text("Refresh selection"))
                .onAppear { selection = [slots[0].id, slots[2].id] }
        }
    }
}
#endif

struct CloudView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: CloudModel
    @State private var quotaStorageConsent = false
    @State private var collectorProcessingConsent = false
    @AppStorage("cloudTrustedBaseURL") private var base = "https://usage.mvtp.cloud"
    @State private var showAccounts = false
    @State private var confirmDelete = false
    @State private var collectorCode = ""
    @State private var selectedSlots = Set<UUID>()
    @State private var collectorConsent = false
    var body: some View {
        let _ = locale
        Form {
            Text(DockL10n.text(model.status)).font(.caption)
            if !model.pendingRecoveryCodes.isEmpty {
                RecoveryCodesView(codes: model.pendingRecoveryCodes) { model.pendingRecoveryCodes = [] }
            }
            if model.pendingMFA != nil { CloudMFAView(model: model) }
            if model.session == nil {
                TextField(DockL10n.text("Trusted HTTPS server"), text: $base).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(model.busy)
                Text(DockL10n.text("Only connect to a server you trust. The server stores sanitized quota, a pseudonymous Apple account, sessions and refresh counters — not provider credentials. A local collector processes quota for your slots. You can instead use Pair bridge without cloud."))
                Toggle(DockL10n.text("Store sanitized quota and account metadata"), isOn: $quotaStorageConsent).disabled(model.busy)
                Toggle(DockL10n.text("Allow local collector quota processing"), isOn: $collectorProcessingConsent).disabled(model.busy)
                Text(DockL10n.text("Both consents are required for cloud. Purchases require configured Apple products and server verification.")).font(.caption).foregroundStyle(.secondary)
                Button(DockL10n.text("Connect with Apple")) {
                    let trustedBase = base
                    let storage = quotaStorageConsent
                    let processing = collectorProcessingConsent
                    Task { await model.connect(base: trustedBase, quotaStorageConsent: storage, collectorProcessingConsent: processing) }
                }.disabled(!quotaStorageConsent || !collectorProcessingConsent || model.busy || model.pendingMFA != nil || !model.pendingRecoveryCodes.isEmpty)
            } else {
                Text(model.me?.budget ?? "")
                if model.snapshot?.cachedSubset == true {
                    Text(DockL10n.text("Offline cache: first 50 slots only, not the complete account list. Read the server for all slots.")).font(.caption)
                }
                Text(DockL10n.text("Local collector required. Provider credentials remain on your computer."))
                if let me = model.me {
                    Toggle(DockL10n.text("Local collector automatic updates"), isOn: Binding(get: { model.me?.backgroundCollection ?? true }, set: { enabled in
                        Task { await model.mutate(path: "v2/settings", method: "PUT", body: ["autoMinutes": me.autoMinutes, "backgroundCollection": enabled]) }
                    })).disabled(model.busy || model.liveEnabled)
                    Text(DockL10n.text("The local computer must stay online. Its due checks run about every 20 minutes; the server enforces your tier interval. This is independent of the phone's foreground setting, not guaranteed iOS background execution.")).font(.caption)
                    if me.tier == .pro {
                        Picker(DockL10n.text("Due-check interval"), selection: Binding(get: { model.me?.autoMinutes ?? 20 }, set: { minutes in
                            Task { await model.mutate(path: "v2/settings", method: "PUT", body: ["autoMinutes": minutes]) }
                        })) {
                            ForEach(me.limits.allowedAutoMinutes, id: \.self) { Text(DockL10n.format("%d minutes", $0)).tag($0) }
                        }.disabled(model.busy || model.liveEnabled)
                    }
                    if me.limits.live {
                        Text(DockL10n.text("Paid Live: explicit opt-in, target 60-second foreground checks. One allowance begins on first fresh success; the server's 30-minute wall deadline continues while hidden or locked. Resuming uses the same server session.")).font(.caption)
                        Button(DockL10n.text(model.liveEnabled ? "Live checks running" : "Start / resume Live")) { model.startLive() }
                            .disabled(model.busy || model.liveEnabled || model.slots.isEmpty)
                        Button(DockL10n.text("Stop Live session")) { Task { await model.stopLive() } }
                        if let deadline = model.liveDeadline { Text(DockL10n.format("Live ends: %@", DockL10n.date(deadline))).font(.caption) }
                    } else { Text(DockL10n.text("Live requires a server-verified paid entitlement.")).font(.caption) }
                }
                Button(DockL10n.text("Accounts")) { showAccounts = true }
                CloudBatchView(slots: model.slots, ids: model.refreshSelection.ids, locked: model.busy || model.selectionLocked, label: model.accountLabel) { ids in
                    model.selectRefreshSlots(ids)
                }
                Section(DockL10n.text("Local collector approval")) {
                    Text(DockL10n.text("Duplicate-provider slots require independent CLI account mappings; Gemini remains limited to one local account. Approval authorizes slot access, not validation of real provider identities. It grants quota jobs for these slots only, not your Apple session. Never copy or export the Apple session.")).font(.caption)
                    TextField(DockL10n.text("Eight uppercase hex pairing code"), text: $collectorCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .onChange(of: collectorCode) { _, _ in collectorConsent = false }
                    ForEach(model.slots) { slot in
                        Toggle("\(slot.provider.displayName) · \(slot.id.uuidString)", isOn: Binding(get: { selectedSlots.contains(slot.id) }, set: { enabled in
                            if enabled { selectedSlots.insert(slot.id) } else { selectedSlots.remove(slot.id) }
                            collectorConsent = false
                        }))
                    }
                    Toggle(DockL10n.text("I authorize this collector to process the selected slots"), isOn: $collectorConsent)
                    Button(DockL10n.text("Approve selected slots")) {
                        let code = collectorCode
                        let ids = selectedSlots
                        guard collectorConsent, CollectorApproval.valid(code: code, selected: ids, slots: model.slots) else { return }
                        collectorConsent = false
                        Task { await model.mutate(path: "v2/collector/approve", method: "POST", body: ["code": code, "accountIds": ids.map(\.uuidString).sorted()]) }
                    }.disabled(!collectorConsent || !CollectorApproval.valid(code: collectorCode, selected: selectedSlots, slots: model.slots) || model.busy || model.liveEnabled)
                    ForEach(model.collectors) { collector in
                        Text(DockL10n.format("Collector %@ · expires %@", collector.id.uuidString, DockL10n.date(collector.expiresAt))).font(.caption)
                        Text(collector.accountIds.map(\.uuidString).joined(separator: "\n")).font(.caption).textSelection(.enabled)
                        Button(DockL10n.text("Revoke collector"), role: .destructive) { Task { await model.mutate(path: "v2/collectors/\(collector.id.uuidString)", method: "DELETE") } }.disabled(model.busy || model.liveEnabled)
                    }
                    Text(DockL10n.text("Collector list requires a successful server read; an unavailable list is not proof of revocation.")).font(.caption)
                }
                Button(DockL10n.text("Force refresh (verified budget applies)")) { Task { await model.refresh(force: true) } }.disabled(model.busy || model.liveEnabled)
                Button(DockL10n.text("Read cached snapshot")) { Task { await model.read() } }
                Button(DockL10n.text("Log out"), role: .destructive) { Task { await model.disconnect(delete: false) } }
                Button(DockL10n.text("Delete cloud account and data"), role: .destructive) { confirmDelete = true }
            }
            Section {
                if model.session != nil {
                    NavigationLink(CloudWords.text("Security", "보안", locale)) { CloudSecurityView(model: model) }
                    NavigationLink(CloudWords.text("Customer support", "고객 지원", locale)) { CloudSupportView(model: model) }
                    NavigationLink(CloudWords.text("Operator support", "운영자 지원", locale)) { CloudAdminView(model: model) }
                }
                NavigationLink(DockL10n.text("Plans")) { PlansView(model: model) }
            }
        }.navigationTitle(DockL10n.text("Optional cloud"))
            .scrollContentBackground(.hidden)
            .background(DockTheme.background)
            .sheet(isPresented: $showAccounts) {
                CloudAccountsView(model: model).presentationDetents([.medium, .large])
            }
            .onChange(of: base) { _, _ in
                quotaStorageConsent = false; collectorProcessingConsent = false
            }
            .onChange(of: model.session?.token) { _, _ in
                selectedSlots = []; collectorConsent = false; collectorCode = ""
                quotaStorageConsent = false; collectorProcessingConsent = false
            }
            .onChange(of: model.slots.map(\.id)) { _, ids in
                selectedSlots.formIntersection(Set(ids)); collectorConsent = false
            }
            .confirmationDialog(DockL10n.text("Permanently erase cloud account, quota and all sessions?"), isPresented: $confirmDelete) {
                Button(DockL10n.text("Erase account"), role: .destructive) { Task { await model.disconnect(delete: true) } }
            }
    }
}
