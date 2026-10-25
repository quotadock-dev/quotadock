import Foundation
import SwiftUI
import UIKit

enum CloudWords {
    static func text(_ en: String, _ ko: String, _ locale: Locale) -> String {
        locale.identifier.hasPrefix("ko") ? ko : en
    }
}

struct CloudMFAChallenge {
    let challenge: String
    let expiresAt: Date
    let base: URL
    static func date(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: text)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: text) else { throw SnapshotError.invalid }
        return date
    }
    static func decodeIfRequired(_ data: Data, base: URL) throws -> Self? {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SnapshotError.invalid }
        guard root["mfaRequired"] != nil else { return nil }
        guard root["mfaRequired"] as? Bool == true, let token = root["challenge"] as? String,
              token.utf8.count == 43, token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let timestamp = root["expiresAt"] as? String else { throw SnapshotError.invalid }
        let expiry = try date(timestamp)
        guard expiry > Date() else { throw SnapshotError.invalid }
        return Self(challenge: token, expiresAt: expiry, base: base)
    }
}

struct CloudEnrollment: Decodable {
    let enrollmentToken: String
    let otpauthUri: String
    let expiresAt: String
    let restricted: Bool
    func validate() throws {
        guard restricted, !enrollmentToken.isEmpty, enrollmentToken.count <= 4096,
              otpauthUri.hasPrefix("otpauth://totp/"), otpauthUri.count <= 4096,
              try CloudMFAChallenge.date(expiresAt) > Date() else { throw SnapshotError.invalid }
    }
}

extension CloudModel {
    // A step-up never acquires a renewed bearer: its grant belongs to this exact token.
    func securityRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         exactToken: String? = nil, maximumResponseBytes: Int = 256 * 1024) async throws -> Data {
        let owner = revision
        let epoch = securityEpoch
        guard foreground, !Task.isCancelled else { throw CancellationError() }
        let transport: CloudClient
        if let exactToken {
            guard session?.token == exactToken, let active = client else { throw CancellationError() }
            transport = active
        } else { transport = try await authorizedClient() }
        guard owner == revision, epoch == securityEpoch, foreground else { throw CancellationError() }
        let data = try await transport.request(path, method: method, body: body, maximumResponseBytes: maximumResponseBytes)
        guard owner == revision, epoch == securityEpoch, foreground, session?.token == transport.token, !Task.isCancelled else { throw CancellationError() }
        return data
    }
}

// All factors, restricted credentials and recovery codes live only in view memory.
struct CloudMFAView: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: CloudModel
    @State private var code = ""
    @State private var recovery = false
    @State private var enrollment: CloudEnrollment?
    @State private var working = false
    @State private var failed = false
    private func words(_ en: String, _ ko: String) -> String { CloudWords.text(en, ko, locale) }
    var body: some View {
        Section(words("Apple sign-in verification", "Apple 로그인 확인")) {
                if let enrollment {
                    Text(words("Add this to your authenticator, then enter its new code.", "인증 앱에 추가한 다음 새 코드를 입력하세요."))
                    Text(verbatim: enrollment.otpauthUri).textSelection(.enabled).privacySensitive()
                } else {
                    Toggle(words("Use a recovery code", "복구 코드 사용"), isOn: $recovery)
                        .onChange(of: recovery) { _, _ in code = "" }
                }
                SecureField(words("Verification code", "인증 코드"), text: $code)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Button(words("Verify", "확인")) { verify() }.disabled(working || code.isEmpty)
                Button(words("Cancel sign-in", "로그인 취소"), role: .cancel) { model.pendingMFA = nil; wipe() }
            if failed { Text(words("Verification failed or expired. Retry or sign in with Apple again.", "인증 실패 또는 만료. 다시 시도하거나 Apple로 다시 로그인하세요.")) }
        }.disabled(working)
            .onDisappear { model.pendingMFA = nil; wipe() }
            .onChange(of: model.foreground) { _, active in if !active { wipe() } }
    }
    private func wipe() { code = ""; enrollment = nil }
    private func verify() {
        // Recovery consumes the login challenge and issues its own timed grant.
        // Confirmation validates that grant below, not the old login deadline.
        guard let challenge = model.pendingMFA, enrollment != nil || challenge.expiresAt > Date() else { failed = true; return }
        let input = code; code = ""; working = true; failed = false
        let owner = model.revision
        let restricted = enrollment
        Task { @MainActor in
            defer { working = false }
            do {
                let transport = try CloudClient(baseURL: challenge.base.absoluteString, scope: model.requests)
                let path = restricted != nil ? "v2/security/totp/confirm" : recovery ? "v2/auth/mfa/recover" : "v2/auth/mfa/verify"
                let body: [String: Any] = restricted.map { ["enrollmentToken": $0.enrollmentToken, "code": input] }
                    ?? ["challenge": challenge.challenge, recovery ? "recoveryCode" : "code": input]
                if let restricted { try restricted.validate() }
                let data = try await transport.request(path, method: "POST", body: body)
                guard owner == model.revision, model.foreground, model.pendingMFA?.challenge == challenge.challenge, !Task.isCancelled else {
                    if let session = try? CloudSession.login(data, baseURL: challenge.base) { try? await CloudClient.revoke(session) }
                    return
                }
                if restricted != nil {
                    let result = try JSONDecoder().decode(CloudRecoveryResult.self, from: data)
                    try result.validate(requireReauthentication: true)
                    // Confirmation revoked every server authority, including any previous local account.
                    _ = model.clear()
                    model.pendingRecoveryCodes = result.recoveryCodes; enrollment = nil
                } else if recovery {
                    let next = try JSONDecoder().decode(CloudEnrollment.self, from: data)
                    try next.validate(); enrollment = next
                } else {
                    let session = try CloudSession.login(data, baseURL: challenge.base)
                    await model.installLogin(session)
                }
            } catch { if owner == model.revision { failed = true } }
        }
    }
}

struct CloudRecoveryResult: Decodable {
    let recoveryCodes: [String]
    let reauthenticate: Bool?
    func validate(requireReauthentication: Bool) throws {
        guard recoveryCodes.count == 10, Set(recoveryCodes).count == 10,
              recoveryCodes.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
              !requireReauthentication || reauthenticate == true else { throw SnapshotError.invalid }
    }
}

struct RecoveryCodesView: View {
    @Environment(\.locale) private var locale
    let codes: [String]
    let done: () -> Void
    @State private var retained = false
    var body: some View {
        Text(CloudWords.text("Save these recovery codes yourself. They are shown only now. No automatic clipboard copy. Sign in with Apple again after confirmation.", "복구 코드를 직접 안전하게 보관하세요. 지금만 표시되며 자동 복사되지 않습니다. 확인 후 Apple로 다시 로그인하세요.", locale))
        Text(verbatim: codes.joined(separator: "\n")).font(.system(.body, design: .monospaced)).textSelection(.enabled).privacySensitive()
        Toggle(CloudWords.text("I have securely retained my recovery codes", "복구 코드를 안전하게 보관했습니다", locale), isOn: $retained)
        Button(CloudWords.text("Done", "완료", locale), action: done).disabled(!retained)
            .onChange(of: codes) { _, _ in retained = false }
    }
}

struct CloudSecurityView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: CloudModel
    @State private var enabled: Bool?
    @State private var replacement = false
    @State private var enrollment: CloudEnrollment?
    @State private var code = ""
    @State private var stepToken: String?
    @State private var stepExpiry: Date?
    @State private var codes: [String] = []
    @State private var working = false
    @State private var notice = ""
    @State private var confirmDisable = false
    private func words(_ en: String, _ ko: String) -> String { CloudWords.text(en, ko, locale) }
    var body: some View {
        Form {
            Text(words("Allowmark uses Apple sign-in, not passwords. Enabling or disabling two-factor authentication revokes all sessions, collectors and pairs. Sign in again afterwards.", "Allowmark는 암호 대신 Apple 로그인을 사용합니다. 2단계 인증 설정 또는 해제 시 모든 세션, 수집기 및 연결이 취소되며 다시 로그인해야 합니다."))
            Text(words("If enabled, the server stores an encrypted authenticator secret, recovery-code hashes and security events. Codes are shown once; retain them securely yourself.", "사용하면 서버에 암호화된 인증 앱 비밀값, 복구 코드 해시와 보안 기록이 저장됩니다. 코드는 한 번만 표시되므로 직접 안전하게 보관하세요."))
            Link(words("Recover your Apple Account", "Apple 계정 복구"), destination: URL(string: "https://support.apple.com/en-us/102656")!)
            if !notice.isEmpty { Text(notice) }
            if !codes.isEmpty { RecoveryCodesView(codes: codes) { codes = [] } }
            else if model.session != nil {
                Text(enabled == nil ? words("Not loaded", "불러오지 않음") : enabled == true ? words("Two-factor authentication enabled", "2단계 인증 사용 중") : words("Two-factor authentication disabled", "2단계 인증 꺼짐"))
                if replacement { Text(words("Authenticator replacement required", "인증 앱 교체 필요")) }
                Button(words("Read security status", "보안 상태 조회")) { run { try await load() } }
                if let enrollment {
                    Text(words("Add to your authenticator. Never share this secret.", "인증 앱에 추가하세요. 이 비밀 정보를 공유하지 마세요."))
                    Text(verbatim: enrollment.otpauthUri).textSelection(.enabled).privacySensitive()
                }
                SecureField(words("Authenticator code", "인증 앱 코드"), text: $code).keyboardType(.numberPad).privacySensitive()
                if enrollment != nil {
                    Button(words("Confirm authenticator and revoke sessions", "인증 앱 확인 및 세션 취소")) { confirmEnrollment() }
                    Button(words("Cancel enrollment", "등록 취소")) { enrollment = nil; code = "" }
                } else {
                    if enabled == false || replacement {
                        Button(words("Set up authenticator", "인증 앱 설정")) { run {
                            let data = try await model.securityRequest("v2/security/totp/enroll", method: "POST", body: [:])
                            let next = try JSONDecoder().decode(CloudEnrollment.self, from: data)
                            try next.validate(); enrollment = next
                        } }
                    }
                    if enabled == true {
                        Button(words("Verify for sensitive changes", "민감한 변경을 위한 인증")) { stepUp() }
                        Button(words("Regenerate recovery codes", "복구 코드 재발급")) { regenerate() }.disabled(!stepped)
                        Button(words("Disable two-factor authentication", "2단계 인증 해제"), role: .destructive) { confirmDisable = true }.disabled(!stepped)
                    }
                }
            }
        }.navigationTitle(words("Security", "보안")).disabled(working)
            .task { run { try await load() } }
            .confirmationDialog(words("Revoke all sessions, collectors and pairs?", "모든 세션, 수집기 및 연결을 취소할까요?"), isPresented: $confirmDisable) {
                Button(words("Disable and sign out", "해제 후 로그아웃"), role: .destructive) { disable() }
            }
            .onDisappear { model.securityEpoch += 1; wipe() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { wipe() } }
            .onChange(of: model.session?.token) { _, _ in stepToken = nil; stepExpiry = nil; code = ""; enrollment = nil }
            .onChange(of: notice) { _, value in
                if scenePhase == .active && model.foreground && !value.isEmpty {
                    UIAccessibility.post(notification: .announcement, argument: value)
                }
            }
    }
    private var stepped: Bool { stepToken != nil && stepToken == model.session?.token && (stepExpiry ?? .distantPast) > Date() }
    private func wipe() { code = ""; enrollment = nil; codes = []; stepToken = nil; stepExpiry = nil }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true
        let owner = model.revision
        Task { @MainActor in
            defer { working = false }
            do { try await action() }
            catch { if owner == model.revision { notice = words("Request failed or expired. Read status before retrying. No automatic retry was sent.", "요청 실패 또는 만료. 재시도 전에 상태를 조회하세요. 자동 재시도하지 않았습니다.") } }
        }
    }
    private func load() async throws {
        struct Status: Decodable { let enabled: Bool; let replacementRequired: Bool }
        let result = try JSONDecoder().decode(Status.self, from: try await model.securityRequest("v2/security"))
        enabled = result.enabled; replacement = result.replacementRequired
    }
    private func stepUp() {
        let input = code; code = ""
        run {
            guard let token = model.session?.token else { throw CancellationError() }
            struct Grant: Decodable { let expiresAt: String }
            let data = try await model.securityRequest("v2/security/step-up", method: "POST", body: ["code": input], exactToken: token)
            let grant = try JSONDecoder().decode(Grant.self, from: data)
            stepExpiry = try CloudMFAChallenge.date(grant.expiresAt); stepToken = token
        }
    }
    private func regenerate() { run {
        guard stepped, let token = stepToken else { throw CancellationError() }
        let data = try await model.securityRequest("v2/security/recovery-codes/regenerate", method: "POST", body: [:], exactToken: token)
        let result = try JSONDecoder().decode(CloudRecoveryResult.self, from: data)
        try result.validate(requireReauthentication: false); codes = result.recoveryCodes
    } }
    private func disable() { run {
        guard stepped, let token = stepToken else { throw CancellationError() }
        _ = try await model.securityRequest("v2/security/totp", method: "DELETE", body: [:], exactToken: token)
        _ = model.clear(); wipe()
        notice = words("Sign in with Apple again.", "Apple로 다시 로그인하세요.")
    } }
    private func confirmEnrollment() {
        let input = code; code = ""
        run {
            guard let active = enrollment, let session = model.session else { throw CancellationError() }
            try active.validate()
            let owner = model.revision
            let epoch = model.securityEpoch
            let transport = try CloudClient(baseURL: session.baseURL.absoluteString, scope: model.requests)
            let data = try await transport.request("v2/security/totp/confirm", method: "POST", body: ["enrollmentToken": active.enrollmentToken, "code": input])
            guard owner == model.revision, epoch == model.securityEpoch, model.foreground, !Task.isCancelled else { throw CancellationError() }
            let result = try JSONDecoder().decode(CloudRecoveryResult.self, from: data)
            try result.validate(requireReauthentication: true)
            _ = model.clear(); codes = result.recoveryCodes; enrollment = nil
            notice = words("Sign in with Apple again after saving your codes.", "코드를 보관한 후 Apple로 다시 로그인하세요.")
        }
    }
}

struct CloudSupportMessage: Decodable, Identifiable {
    let id: Int64
    let message: String
    let staff: Bool
    let `internal`: Bool
    let createdAt: String
}

struct CloudSupportView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: CloudModel
    @State private var paging = CloudSupportPager()
    @State private var generation = UUID()
    @State private var operation: Task<Void, Never>?
    @State private var operationToken: String?
    @State private var confirmDiscard = false
    @State private var selected: CloudSupportTicket?
    @State private var messages: [CloudSupportMessage] = []
    @State private var subject = ""
    @State private var category = "general"
    @State private var message = ""
    @State private var working = false
    @State private var notice = ""
    // Unknown sends retain the same command/key. Editing creates a distinct explicit command.
    @State private var pending: (fingerprint: String, key: UUID)?
    private func words(_ en: String, _ ko: String) -> String { CloudWords.text(en, ko, locale) }
    private var hasDraft: Bool { !message.isEmpty || !subject.isEmpty || pending != nil }
    private var available: Bool {
        model.foreground && scenePhase == .active && model.session != nil && (model.session?.expiresAt ?? .distantPast) > Date()
    }
    var body: some View {
        Form {
            Text(words("Plain text only. Do not send credentials, verification codes, recovery codes or private diagnostics. Nothing is attached automatically.", "일반 텍스트만 전송됩니다. 자격 증명, 인증·복구 코드 또는 개인 진단 정보를 보내지 마세요. 자동 첨부는 없습니다."))
            Text(words("Sending stores your ticket subject, category and messages on the server for authorized support staff. Assignments and staff-only internal notes are also stored. Internal notes are not shown to customers.", "보내면 문의 제목, 분류와 메시지가 서버에 저장되어 권한 있는 지원 담당자가 확인합니다. 담당자 배정과 직원 전용 내부 메모도 저장되며 내부 메모는 고객에게 표시되지 않습니다."))
            Text(notice)
            if !available { Text(words("Session unavailable or expired. Return to cloud settings to refresh/sign in, then load tickets again.", "세션을 사용할 수 없거나 만료되었습니다. 클라우드 설정에서 새로고침/로그인 후 문의를 다시 불러오세요.")) }
            else {
                Button(words("Refresh tickets", "문의 새로고침")) { run { try await list() } }
                    .accessibilityIdentifier("support.latest")
                    .disabled(hasDraft)
                Text(words("Creation order, 50 per page. Older replaces this list; Refresh returns to latest. Pages can change between reads. Leaving, backgrounding or session changes clear pages and drafts. Finish or discard a draft before browsing.", "생성 시각 순으로 페이지당 최대 50건입니다. 이전 페이지로 목록을 교체하며 새로고침하면 최신으로 돌아갑니다. 조회 사이에 내용이 달라질 수 있습니다. 화면을 나가거나 백그라운드·세션 변경 시 페이지와 초안이 지워집니다. 탐색 전에 초안을 전송하거나 버리세요."))
                    .font(.caption)
                if working { ProgressView(words("Loading", "불러오는 중")) }
                if paging.loaded && paging.tickets.isEmpty { Text(words("No visible tickets on this page.", "이 페이지에서 볼 수 있는 문의가 없습니다.")) }
                ForEach(operationToken == model.session?.token ? paging.tickets : []) { ticket in
                    Button { run { try await detail(ticket.id) } } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: ticket.subject)
                            Text(verbatim: "\(ticket.category) · \(ticket.status) · \(ticket.updatedAt)").font(.caption)
                        }
                    }.disabled(hasDraft)
                }
                if paging.failed {
                    Button(words("Retry this page", "이 페이지 다시 조회")) { run { try await list(retry: true) } }.disabled(hasDraft)
                } else if paging.nextCursor != nil {
                    Button(words("Older tickets", "이전 문의")) { run { try await list(older: true) } }
                        .accessibilityIdentifier("support.older")
                        .disabled(hasDraft)
                } else if paging.loaded {
                    Text(words("End of tickets. Refresh to check for changes.", "마지막 문의입니다. 변경 사항은 새로고침하세요."))
                }
                if operationToken == model.session?.token, let selected {
                    Section {
                        Text(verbatim: selected.subject).font(.headline)
                        ForEach(messages.filter { !$0.internal }) { item in
                            VStack(alignment: .leading) {
                                Text(item.staff ? words("Support", "지원 담당자") : words("You", "나")).font(.caption)
                                Text(verbatim: item.message).textSelection(.enabled)
                                Text(verbatim: item.createdAt).font(.caption)
                            }
                        }
                        Button(words("Back / new ticket", "목록 / 새 문의")) { self.selected = nil; messages = []; message = "" }.disabled(hasDraft)
                        Button(selected.status == "resolved" ? words("Reopen ticket", "문의 다시 열기") : words("Resolve ticket", "문의 해결 처리")) {
                            run {
                                paging.reset(); self.selected = nil; messages = []
                                _ = try await request("v2/support/tickets/\(selected.id.uuidString)/status", method: "PUT", body: ["status": selected.status == "resolved" ? "open" : "resolved"])
                                try await detail(selected.id)
                            }
                        }.disabled(hasDraft)
                    }
                } else {
                    TextField(words("Subject", "제목"), text: $subject)
                    TextField(words("Category", "분류"), text: $category).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField(words("Message (no secrets)", "메시지 (비밀 정보 제외)"), text: $message, axis: .vertical).lineLimit(3...12)
                Button(selected == nil ? words("Create ticket", "문의 등록") : words("Send reply", "답장 보내기")) { send() }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (selected == nil && (subject.isEmpty || category.isEmpty)))
                if hasDraft {
                    Button(words("Discard draft / retry information…", "초안 / 재시도 정보 버리기…"), role: .destructive) { confirmDiscard = true }
                }
            }
        }.navigationTitle(words("Customer support", "고객 지원")).disabled(working)
            .task { run { try await list() } }
            .task(id: model.session?.token) {
                guard let session = model.session else { return }
                do { try await Task.sleep(nanoseconds: UInt64(max(0, session.expiresAt.timeIntervalSinceNow) * 1_000_000_000)) }
                catch { return }
                guard model.session?.token == session.token else { return }
                wipe()
            }
            .confirmationDialog(words("Discard local draft and retry information? A request already sent may still complete on the server.", "로컬 초안과 재시도 정보를 버릴까요? 이미 보낸 요청은 서버에서 완료될 수 있습니다."), isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button(words("Discard", "버리기"), role: .destructive) { message = ""; subject = ""; pending = nil }
            }
            .privacySensitive()
            .onDisappear { wipe() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { wipe() } }
            .onChange(of: model.foreground) { _, active in if !active { wipe() } }
            .onChange(of: model.session?.token) { _, _ in wipe() }
            .onChange(of: model.revision) { _, _ in wipe() }
            .onChange(of: notice) { _, value in
                if scenePhase == .active && model.foreground && !value.isEmpty {
                    UIAccessibility.post(notification: .announcement, argument: value)
                }
            }
    }
    private func wipe() {
        generation = UUID(); operation?.cancel(); operation = nil; operationToken = nil; working = false; confirmDiscard = false
        paging.reset(); selected = nil; messages = []; message = ""; subject = ""; category = "general"; pending = nil; notice = ""
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working, available, let exact = model.session?.token else { return }
        working = true; notice = ""; operationToken = exact
        let owner = model.revision
        let current = generation
        operation = Task { @MainActor in
            defer { if current == generation { working = false; operation = nil } }
            guard current == generation, owner == model.revision, model.session?.token == exact, available, !Task.isCancelled else { return }
            do { try await action() }
            catch {
                guard current == generation, owner == model.revision, model.session?.token == exact, available, !Task.isCancelled else { return }
                switch error as? CloudHTTPError {
                case .unauthorized:
                    wipe()
                    notice = words("Session rejected. Return to cloud settings to refresh/sign in, then load tickets again.", "세션이 거부되었습니다. 클라우드 설정에서 새로고침/로그인 후 문의를 다시 불러오세요.")
                    return
                case .notFound, .rejected(status: 403, code: _):
                    paging.reset(); selected = nil; messages = []; pending = nil; message = ""; subject = ""
                default: break
                }
                notice = paging.failed
                    ? words("Page unavailable. Retry this page or refresh latest. No automatic retry was sent.", "페이지를 불러오지 못했습니다. 이 페이지를 다시 조회하거나 최신 문의로 새로고침하세요. 자동 재시도하지 않았습니다.")
                    : words("Read unavailable or send unconfirmed. Retry reads explicitly; retry an unchanged message to reuse its request key. Paging requires the matching server API.", "조회 불가 또는 전송 미확인입니다. 조회는 직접 재시도하고 같은 메시지는 동일 요청 키로 재시도하세요. 페이지 조회를 지원하는 서버가 필요합니다.")
            }
        }
    }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, maximumResponseBytes: Int = 256 * 1024) async throws -> Data {
        let current = generation
        guard let token = operationToken, token == model.session?.token, available else { throw CancellationError() }
        let data = try await model.securityRequest(path, method: method, body: body, exactToken: token, maximumResponseBytes: maximumResponseBytes)
        guard current == generation, scenePhase == .active, !Task.isCancelled else { throw CancellationError() }
        return data
    }
    private func list(older: Bool = false, retry: Bool = false) async throws {
        selected = nil; messages = []; message = ""; pending = nil
        let read = try paging.begin(older: older, retry: retry)
        do {
            let data = try await request(read.path)
            try paging.finish(data, read: read)
            notice = words("Ticket page loaded.", "문의 페이지를 불러왔습니다.")
        }
        catch { paging.fail(read); throw error }
    }
    private func detail(_ id: UUID) async throws {
        struct Detail: Decodable { let ticket: CloudSupportTicket; let messages: [CloudSupportMessage] }
        selected = nil; messages = []; message = ""; subject = ""; pending = nil
        // 100 messages × 4,000 Unicode characters can exceed the quota transport's 256 KiB default.
        let result = try JSONDecoder().decode(Detail.self, from: await request("v2/support/tickets/\(id.uuidString)", maximumResponseBytes: 2 * 1024 * 1024))
        guard result.ticket.id == id, result.messages.count <= 100 else { throw SnapshotError.invalid }
        selected = result.ticket; messages = result.messages
    }
    private func send() {
        let ticket = selected
        let text = message
        let title = subject
        let kind = category
        let fingerprint = [ticket?.id.uuidString ?? "new", title, kind, text].joined(separator: "\u{0}")
        let key = pending?.fingerprint == fingerprint ? pending!.key : UUID()
        pending = (fingerprint, key)
        run {
            if let ticket {
                _ = try await request("v2/support/tickets/\(ticket.id.uuidString)/messages", method: "POST", body: ["message": text, "idempotencyKey": key.uuidString])
                message = ""; pending = nil
                try await detail(ticket.id)
            } else {
                struct Created: Decodable { let ticket: CloudSupportTicket }
                let data = try await request("v2/support/tickets", method: "POST", body: ["subject": title, "category": kind, "message": text, "idempotencyKey": key.uuidString])
                let result = try JSONDecoder().decode(Created.self, from: data)
                selected = result.ticket; message = ""; pending = nil
                try await detail(result.ticket.id)
            }
        }
    }
}
