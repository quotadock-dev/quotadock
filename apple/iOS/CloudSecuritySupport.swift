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

struct CloudSupportTicket: Decodable, Identifiable {
    let id: UUID
    let subject: String
    let category: String
    let status: String
    let createdAt: String
    let updatedAt: String
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
    @State private var tickets: [CloudSupportTicket] = []
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
    var body: some View {
        Form {
            Text(words("Plain text only. Do not send credentials, verification codes, recovery codes or private diagnostics. Nothing is attached automatically.", "일반 텍스트만 전송됩니다. 자격 증명, 인증·복구 코드 또는 개인 진단 정보를 보내지 마세요. 자동 첨부는 없습니다."))
            Text(words("Sending stores your ticket subject, category and messages on the server for authorized support staff. Assignments and staff-only internal notes are also stored. Internal notes are not shown to customers.", "보내면 문의 제목, 분류와 메시지가 서버에 저장되어 권한 있는 지원 담당자가 확인합니다. 담당자 배정과 직원 전용 내부 메모도 저장되며 내부 메모는 고객에게 표시되지 않습니다."))
            Text(notice)
            if model.session == nil { Text(words("Sign in to contact support.", "지원 문의를 위해 로그인하세요.")) }
            else {
                Button(words("Refresh tickets", "문의 새로고침")) { run { try await list() } }
                ForEach(tickets) { ticket in
                    Button { run { try await detail(ticket.id) } } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: ticket.subject)
                            Text(verbatim: "\(ticket.category) · \(ticket.status) · \(ticket.updatedAt)").font(.caption)
                        }
                    }
                }
                if let selected {
                    Section {
                        Text(verbatim: selected.subject).font(.headline)
                        ForEach(messages.filter { !$0.internal }) { item in
                            VStack(alignment: .leading) {
                                Text(item.staff ? words("Support", "지원 담당자") : words("You", "나")).font(.caption)
                                Text(verbatim: item.message).textSelection(.enabled)
                                Text(verbatim: item.createdAt).font(.caption)
                            }
                        }
                        Button(words("Back / new ticket", "목록 / 새 문의")) { self.selected = nil; messages = []; message = "" }
                        Button(selected.status == "resolved" ? words("Reopen ticket", "문의 다시 열기") : words("Resolve ticket", "문의 해결 처리")) {
                            run {
                                _ = try await model.securityRequest("v2/support/tickets/\(selected.id.uuidString)/status", method: "PUT", body: ["status": selected.status == "resolved" ? "open" : "resolved"])
                                try await detail(selected.id)
                            }
                        }
                    }
                } else {
                    TextField(words("Subject", "제목"), text: $subject)
                    TextField(words("Category", "분류"), text: $category).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                TextField(words("Message (no secrets)", "메시지 (비밀 정보 제외)"), text: $message, axis: .vertical).lineLimit(3...12)
                Button(selected == nil ? words("Create ticket", "문의 등록") : words("Send reply", "답장 보내기")) { send() }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (selected == nil && (subject.isEmpty || category.isEmpty)))
            }
        }.navigationTitle(words("Customer support", "고객 지원")).disabled(working)
            .task { run { try await list() } }
            .onChange(of: model.session?.token) { _, _ in tickets = []; selected = nil; messages = []; message = ""; subject = ""; pending = nil }
            .onChange(of: notice) { _, value in
                if scenePhase == .active && model.foreground && !value.isEmpty {
                    UIAccessibility.post(notification: .announcement, argument: value)
                }
            }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working else { return }; working = true
        let owner = model.revision
        Task { @MainActor in
            defer { working = false }
            do { try await action() }
            catch { if owner == model.revision { notice = words("Request unconfirmed. Retry the unchanged message to reuse its request key.", "요청 결과를 확인하지 못했습니다. 같은 메시지를 재시도하면 동일 요청 키를 사용합니다.") } }
        }
    }
    private func list() async throws {
        struct List: Decodable { let tickets: [CloudSupportTicket] }
        let result = try JSONDecoder().decode(List.self, from: try await model.securityRequest("v2/support/tickets"))
        guard result.tickets.count <= 50 else { throw SnapshotError.invalid }
        tickets = result.tickets
    }
    private func detail(_ id: UUID) async throws {
        struct Detail: Decodable { let ticket: CloudSupportTicket; let messages: [CloudSupportMessage] }
        // 100 messages × 4,000 Unicode characters can exceed the quota transport's 256 KiB default.
        let result = try JSONDecoder().decode(Detail.self, from: try await model.securityRequest("v2/support/tickets/\(id.uuidString)", maximumResponseBytes: 2 * 1024 * 1024))
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
                _ = try await model.securityRequest("v2/support/tickets/\(ticket.id.uuidString)/messages", method: "POST", body: ["message": text, "idempotencyKey": key.uuidString])
                message = ""; pending = nil
                try await detail(ticket.id)
            } else {
                struct Created: Decodable { let ticket: CloudSupportTicket }
                let data = try await model.securityRequest("v2/support/tickets", method: "POST", body: ["subject": title, "category": kind, "message": text, "idempotencyKey": key.uuidString])
                let result = try JSONDecoder().decode(Created.self, from: data)
                selected = result.ticket; message = ""; pending = nil
                try await detail(result.ticket.id)
            }
        }
    }
}
