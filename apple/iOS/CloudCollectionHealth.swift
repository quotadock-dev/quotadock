import Foundation
import SwiftUI
import UIKit

// Metadata only. A server report is not a new provider observation, and a
// successful queue poll is not evidence that a computer is currently online.
struct CloudCollectionHealth {
    struct Account: Decodable, Identifiable {
        let accountId: UUID
        var id: UUID { accountId }
        let provider: ProviderID
        let observedAt: Date?
        let lastReportAt: Date?
        let lastError: String?
    }
    struct Collector: Decodable, Identifiable {
        let id: UUID
        let accountIds: [UUID]
        let expiresAt: Date
        // Older servers may omit tracking. Missing is unknown, never "offline".
        let lastPolledAt: Date?
    }
    let accounts: [Account]
    let collectors: [Collector]

    static func read(fetch: (String) async throws -> Data) async throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Snapshot.date(from: decoder.singleValueContainer().decode(String.self))
        }
        let accounts = try await CloudPagination.collect(path: "v2/collection-health/page", id: { (row: Account) in row.id }, fetch: fetch) { data in
            struct Retention: Decodable { let reportRetentionDays: Int }
            guard try decoder.decode(Retention.self, from: data).reportRetentionDays == 90 else { throw SnapshotError.invalid }
            return try decoder.decode(CloudPagination.Page<Account>.self, from: data)
        }
        struct Contacts: Decodable { let collectors: [Collector] }
        let collectors = try decoder.decode(Contacts.self, from: await fetch("v2/collectors")).collectors
        guard collectors.count <= 5000, Set(collectors.map(\.id)).count == collectors.count,
              collectors.allSatisfy({ $0.accountIds.count <= 50 && Set($0.accountIds).count == $0.accountIds.count }) else {
            throw SnapshotError.invalid
        }
        return Self(accounts: accounts, collectors: collectors)
    }
}

extension CloudModel {
    func readCollectionHealth() async throws -> CloudCollectionHealth {
        guard foreground, session != nil else { throw CancellationError() }
        let owner = revision
        let epoch = securityEpoch
        let transport = try await authorizedClient()
        let budget = CloudReadBudget()
        func validate() throws {
            try budget.validate()
            guard owner == revision, epoch == securityEpoch, foreground,
                  let session, session.token == transport.token, session.expiresAt > Date() else { throw CancellationError() }
        }
        return try await CloudCollectionHealth.read { path in
            try validate()
            let data = try await budget.fetch(path, client: transport, beforeRequest: validate)
            try validate()
            return data
        }
    }
}

struct CloudCollectionHealthView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: CloudModel
    @State private var health: CloudCollectionHealth?
    @State private var readAt: Date?
    @State private var notice = ""
    @State private var working = false
    @State private var generation = UUID()
    private func words(_ en: String, _ ko: String) -> String { CloudWords.text(en, ko, locale) }

    var body: some View {
        Form {
            Section {
                Text(words("Read-only collection metadata. Reading this screen does not start provider collection or spend a refresh allowance.", "읽기 전용 수집 정보입니다. 이 화면 조회는 제공자 수집을 시작하거나 새로고침 한도를 사용하지 않습니다."))
                if model.session == nil {
                    Text(words("Sign in to read collection health.", "수집 상태를 조회하려면 로그인하세요."))
                } else {
                    Button(words("Read collection health", "수집 상태 조회")) { load() }.disabled(working)
                }
                if working { ProgressView(words("Reading metadata", "정보 조회 중")) }
                if !notice.isEmpty { Text(notice) }
                if let readAt {
                    Text(words("Metadata read on this phone: ", "이 휴대폰에서 정보 조회: ") + DockL10n.date(readAt)).font(.caption)
                }
            }
            if let health { CloudCollectionHealthDetails(health: health) }
        }
        .navigationTitle(words("Collection health", "수집 상태"))
        .privacySensitive()
        .onDisappear { wipe() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { wipe() } }
        .onChange(of: model.foreground) { _, active in if !active { wipe() } }
        .onChange(of: model.revision) { _, _ in wipe() }
        .onChange(of: notice) { _, value in
            if scenePhase == .active && model.foreground && !value.isEmpty {
                UIAccessibility.post(notification: .announcement, argument: value)
            }
        }
    }
    private func wipe() {
        generation = UUID(); health = nil; readAt = nil; notice = ""
    }
    private func load() {
        guard !working else { return }
        let current = generation
        working = true; notice = ""
        Task { @MainActor in
            defer { working = false }
            do {
                let result = try await model.readCollectionHealth()
                guard current == generation, scenePhase == .active, model.foreground else { return }
                health = result; readAt = Date()
            } catch {
                guard current == generation, scenePhase == .active, model.foreground else { return }
                if case CloudHTTPError.notFound = error {
                    notice = words("This server does not offer collection health yet. No contact or report times were inferred.", "이 서버는 아직 수집 상태 조회를 제공하지 않습니다. 연락 또는 결과 수신 시각을 추정하지 않았습니다.")
                } else {
                    notice = words("A complete health read could not be confirmed. Any previous metadata and its read time are retained; retry explicitly.", "전체 수집 상태 조회를 확인하지 못했습니다. 이전 정보와 조회 시각은 유지됩니다. 직접 다시 조회하세요.")
                }
            }
        }
    }
}

// Presentation is separate from authority/transport. An inert host can render
// synthetic metadata without seeding a session or enabling server operations.
struct CloudCollectionHealthDetails: View {
    @Environment(\.locale) private var locale
    let health: CloudCollectionHealth
    private func words(_ en: String, _ ko: String) -> String { CloudWords.text(en, ko, locale) }
    var body: some View {
        Section(words("Account observations and reports", "계정 관측 및 결과 수신")) {
            Text(words("Observation time comes from successful measured quota. Report time is when the server accepted a completed job, even if it had no fresh quota. Reports cover retained jobs created within 90 days, not quota history. No record does not mean never attempted.", "관측 시각은 성공한 실제 할당량 측정 시각입니다. 결과 수신 시각은 새 할당량이 없어도 서버가 작업 완료를 수락한 시각입니다. 최근 90일 내 생성되어 보존된 작업 정보이며 할당량 이력이 아닙니다. 기록 없음은 시도한 적 없음을 뜻하지 않습니다."))
            if health.accounts.isEmpty { Text(words("No accounts in this server response.", "이 서버 응답에 계정이 없습니다.")) }
            ForEach(health.accounts) { account in
                VStack(alignment: .leading, spacing: 8) {
                    Text(account.provider.displayName).font(.headline)
                    Text(verbatim: account.id.uuidString).font(.caption).textSelection(.enabled)
                    timestamp("Last successful source observation", "마지막 성공 관측", account.observedAt)
                    timestamp("Last report received", "마지막 결과 수신", account.lastReportAt)
                    if account.lastError != nil {
                        Text(words("Collection warning: no fresh measured quota. The original reading is retained.", "수집 경고: 새로운 실제 할당량이 없습니다. 원래 관측값을 유지합니다.")).font(.callout)
                    }
                }
            }
        }
        Section(words("Collector queue contacts", "수집기 대기열 연락")) {
            Text(words("Grant expiry is permission, not online status. Last poll means the server accepted a collector queue check, including an empty queue. It does not prove the computer is online now or that provider collection succeeded. Older grants may have no recorded poll.", "권한 만료일은 온라인 상태가 아닙니다. 마지막 폴링은 빈 대기열을 포함해 서버가 수집기 작업 확인을 수락한 시각입니다. 현재 컴퓨터가 온라인이거나 제공자 수집에 성공했다는 뜻은 아닙니다. 기존 권한에는 폴링 기록이 없을 수 있습니다."))
            if health.collectors.isEmpty { Text(words("No unexpired collector grants in this server response.", "이 서버 응답에 유효기간이 남은 수집기 권한이 없습니다.")) }
            ForEach(health.collectors) { collector in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: collector.id.uuidString).font(.caption).textSelection(.enabled)
                    timestamp("Last accepted queue poll", "마지막 대기열 폴링 수신", collector.lastPolledAt)
                    timestamp("Grant expires", "권한 만료", collector.expiresAt)
                    Text(words("Scoped account UUIDs", "허용된 계정 UUID") + ":\n" + collector.accountIds.map(\.uuidString).joined(separator: "\n")).font(.caption).textSelection(.enabled)
                }
            }
        }
    }
    private func timestamp(_ en: String, _ ko: String, _ date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(words(en, ko)).font(.caption).foregroundStyle(.secondary)
            Text(date.map { DockL10n.date($0) } ?? words("No recorded time", "기록된 시각 없음"))
        }.accessibilityElement(children: .combine)
    }
}
