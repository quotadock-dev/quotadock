import SwiftUI
import UIKit

extension CloudModel {
    func readHistorySettings() async throws -> CloudHistorySettings {
        let data = try await securityRequest("v2/history")
        return try CloudHistorySettings.decode(data)
    }
    func changeHistory(enabled: Bool, exactToken: String) async throws -> CloudHistorySettings {
        let data = try await securityRequest("v2/history", method: "PUT", body: ["enabled": enabled], exactToken: exactToken)
        let result = try CloudHistorySettings.decode(data)
        guard result.enabled == enabled else { throw SnapshotError.invalid }
        return result
    }
    func readHistoryPage(account: CloudAccount, before: String? = nil) async throws -> CloudHistoryPage {
        func owns() -> Bool { slots.contains(where: { $0.id == account.id && $0.provider == account.provider }) }
        guard owns() else { throw CancellationError() }
        if let before { _ = try CloudHistoryPage.cursorDate(before) }
        let path = "v2/accounts/\(account.id.uuidString.lowercased())/history/page?limit=50"
            + (before.map { "&before=\($0)" } ?? "")
        let data = try await securityRequest(path)
        guard owns() else { throw CancellationError() }
        return try CloudHistoryPage.decode(data, accountID: account.id, provider: account.provider, before: before)
    }
}

struct CloudHistoryView: View {
    @ObservedObject var model: CloudModel
    var account: CloudAccount? = nil
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings: CloudHistorySettings?
    @State private var observations: [CloudHistoryObservation] = []
    @State private var nextCursor: String?
    @State private var loaded = false
    @State private var notice = ""
    @State private var working = false
    @State private var generation = UUID()
    @State private var work: Task<Void, Never>?
    @State private var showConfirmation = false
    @State private var confirmation: Bool?
    @State private var confirmationToken: String?
    private func words(_ en: String, _ ko: String) -> String { CloudWords.text(en, ko, locale) }
    private var available: Bool {
        model.session != nil && (account.map { selected in
            model.slots.contains { $0.id == selected.id && $0.provider == selected.provider }
        } ?? true)
    }

    var body: some View {
        Form {
            Section {
                Text(words("Optional history stores only new successful measurements after you enable it. Up to 7 elapsed days and the latest 1,000 samples per account, on every plan. No backfill or guaranteed collection schedule.", "선택적 이력은 활성화 후 새로 성공한 측정값만 저장합니다. 모든 요금제에서 계정당 최대 7일·최근 1,000건입니다. 과거 값 채우기나 수집 주기를 보장하지 않습니다."))
                Text(words("Reading history never starts collection or spends refresh allowance. Windows stay independent; unknown is not zero and a reset never refills a saved reading.", "이력 조회는 수집을 시작하거나 새로고침 한도를 사용하지 않습니다. 각 구간은 독립적이며 미확인은 0이 아닙니다. 초기화 시각이 지나도 저장된 값을 채우지 않습니다."))
                if !available {
                    Text(words("Sign in and select a listed account to read its history. No saved history is shown here while disconnected.", "로그인하고 목록의 계정을 선택하면 해당 이력을 조회할 수 있습니다. 연결되지 않은 동안 저장된 이력을 표시하지 않습니다."))
                } else {
                    Button(words("Read history status", "이력 저장 상태 조회")) { readStatus() }.disabled(working)
                    if let settings {
                        Text(settings.enabled ? words("History storage enabled", "이력 저장 사용 중") : words("History storage disabled", "이력 저장 꺼짐"))
                        Button(settings.enabled ? words("Disable and delete history", "이력 저장 해제 및 삭제") : words("Enable history storage", "이력 저장 활성화"),
                               role: settings.enabled ? .destructive : nil) {
                            confirmationToken = model.session?.token
                            confirmation = !settings.enabled
                            showConfirmation = true
                        }.disabled(working)
                    } else { Text(words("Storage status not confirmed", "저장 상태 확인 안 됨")) }
                    if let account {
                        Text(model.accountTitle(account.id, provider: account.provider)).font(.headline)
                        Text(verbatim: account.id.uuidString).font(.caption).textSelection(.enabled)
                        Button(words("Read latest history", "최근 이력 조회")) { readPage(account, before: nil) }.disabled(working)
                        if loaded && observations.isEmpty {
                            Text(words("No stored measurements in this response. Disabled history, retention and a sleeping collector can leave an empty result; this is not zero allowance.", "이 응답에 저장된 측정값이 없습니다. 저장 해제·보관 기간·꺼진 수집기 때문에 비어 있을 수 있으며, 남은 할당량이 0이라는 뜻이 아닙니다."))
                        }
                    } else {
                        Text(words("Open an account to read its individual history.", "개별 이력은 계정 화면에서 조회하세요."))
                    }
                    NavigationLink(words("Security / verify sensitive changes", "보안 / 민감한 변경 인증")) { CloudSecurityView(model: model) }
                    Text(words("With two-factor authentication enabled, sensitive changes require both Security verification and a recent Apple sign-in. Return here after verification. Confirmation never silently renews or transfers it.", "2단계 인증 사용 시 민감한 변경에는 보안 인증과 최근 Apple 로그인이 모두 필요합니다. 보안에서 인증한 후 돌아오세요. 변경 확인 중 인증을 자동 갱신하거나 다른 세션으로 옮기지 않습니다."))
                        .font(.caption)
                }
                if working { ProgressView(words("Waiting for server", "서버 응답 대기 중")) }
                if !notice.isEmpty { Text(notice) }
            }
            CloudHistoryDetails(observations: observations)
            if let account, let nextCursor, observations.count < 1000 {
                Button(words("Read older measurements", "이전 측정값 조회")) { readPage(account, before: nextCursor) }.disabled(working)
            }
        }
        .navigationTitle(words("Quota history", "할당량 이력"))
        .scrollContentBackground(.hidden)
        .background(DockTheme.background)
        .privacySensitive()
        .confirmationDialog(confirmation == true
            ? words("Store new measurements for all your accounts?", "모든 계정의 새 측정값을 저장할까요?")
            : words("Disable storage and permanently delete all your account history?", "저장을 해제하고 모든 계정의 이력을 영구 삭제할까요?"),
            isPresented: $showConfirmation) {
                Button(confirmation == true ? words("Enable history", "이력 활성화") : words("Disable and delete", "해제 및 삭제"),
                       role: confirmation == true ? nil : .destructive) { change() }
                Button(words("Cancel", "취소"), role: .cancel) { confirmation = nil; confirmationToken = nil }
        }
        .onDisappear { wipe() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { wipe() } }
        .onChange(of: model.foreground) { _, active in if !active { wipe() } }
        .onChange(of: model.revision) { _, _ in wipe() }
        .onChange(of: model.session?.token) { _, _ in showConfirmation = false; confirmation = nil; confirmationToken = nil }
        .onChange(of: model.slots.map(\.id)) { _, _ in if !available { wipe() } }
        .onChange(of: notice) { _, value in
            if scenePhase == .active && model.foreground && !value.isEmpty {
                UIAccessibility.post(notification: .announcement, argument: value)
            }
        }
    }
    private func wipe() {
        generation = UUID(); work?.cancel(); work = nil; working = false
        settings = nil; observations = []; nextCursor = nil; loaded = false
        notice = ""; showConfirmation = false; confirmation = nil; confirmationToken = nil
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard available, !working, scenePhase == .active, model.foreground else { return }
        let current = generation
        working = true; notice = ""
        work = Task { @MainActor in
            defer { if current == generation { working = false; work = nil } }
            do { try await action() }
            catch {
                guard current == generation, scenePhase == .active, model.foreground else { return }
                // A PUT may have committed before its response was lost. Never
                // restore a guessed toggle or retry that mutation automatically.
                settings = nil; observations = []; nextCursor = nil; loaded = false
                notice = error as? CloudHTTPError == .notFound
                    ? words("History is unavailable on this server or the account was removed. No history or consent was inferred.", "이 서버에서 이력을 제공하지 않거나 계정이 삭제되었습니다. 이력이나 동의 상태를 추정하지 않았습니다.")
                    : words("The result could not be confirmed. Read status before retrying; no automatic retry was sent. Sensitive changes may require Security verification and a new Apple sign-in.", "결과를 확인하지 못했습니다. 재시도 전에 상태를 조회하세요. 자동 재시도하지 않았습니다. 민감한 변경에는 보안 인증과 새 Apple 로그인이 필요할 수 있습니다.")
            }
        }
    }
    private func readStatus() {
        let current = generation
        run {
            let result = try await model.readHistorySettings()
            guard current == generation else { throw CancellationError() }
            settings = result; observations = []; nextCursor = nil; loaded = false
        }
    }
    private func readPage(_ account: CloudAccount, before: String?) {
        let current = generation
        run {
            let page = try await model.readHistoryPage(account: account, before: before)
            guard current == generation else { throw CancellationError() }
            let rows = before == nil || !page.settings.enabled ? page.observations : observations + page.observations
            guard rows.count <= 1000, Set(rows.map(\.id)).count == rows.count else { throw SnapshotError.invalid }
            settings = page.settings; observations = rows; nextCursor = page.nextCursor; loaded = true
        }
    }
    private func change() {
        guard let enabled = confirmation, let token = confirmationToken, token == model.session?.token else { return }
        confirmation = nil; confirmationToken = nil
        let current = generation
        run {
            let result = try await model.changeHistory(enabled: enabled, exactToken: token)
            guard current == generation else { throw CancellationError() }
            settings = result; observations = []; nextCursor = nil; loaded = false
            notice = enabled ? words("History enabled. Only future accepted measurements will be stored.", "이력을 활성화했습니다. 이후 새로 수락한 측정값만 저장합니다.")
                : words("Server confirmed history disabled and deleted.", "서버에서 이력 저장 해제 및 삭제를 확인했습니다.")
        }
    }
}
