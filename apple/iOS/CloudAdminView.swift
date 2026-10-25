import Foundation
import SwiftUI
import UIKit

// Operator authority is provisioned by administrators, never inferred from MFA.
private struct AdminTicket: Decodable, Identifiable {
    let id: UUID
    let subject, category, status, createdAt, updatedAt: String
    let ownerId: UUID
    let assigneeId: UUID?
}
private struct AdminMessage: Decodable, Identifiable {
    let id: Int64
    let message, createdAt: String
    let staff: Bool
    let `internal`: Bool
}
private struct AdminOperator: Decodable, Identifiable {
    var id: UUID { userId }
    let userId: UUID
    let role: String
    let version: Int?
    let enabled: Bool?
}
private struct AdminMetrics: Decodable {
    let users: Int
    let accountProviders: Providers
    let jobs: Jobs
    let support: Support
    let collectors: Collectors
    struct Providers: Decodable { let claude, codex, gemini, grok: Int }
    struct Jobs: Decodable { let pending, completed, expired, cached: Int }
    struct Support: Decodable { let open, waiting, resolved: Int }
    struct Collectors: Decodable { let active, expired: Int }
}

struct CloudAdminView: View {
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: CloudModel
    @State private var code = ""
    @State private var token: String?
    @State private var expiry: Date?
    @State private var generation = UUID()
    @State private var operation: Task<Void, Never>?
    @State private var expiryTask: Task<Void, Never>?
    @State private var confirmDiscard = false
    @State private var working = false
    @State private var notice = ""
    @State private var filter = "all"
    @State private var paging = CloudSupportPager()
    @State private var selected: AdminTicket?
    @State private var messages: [AdminMessage] = []
    @State private var operators: [AdminOperator] = []
    @State private var metrics: AdminMetrics?
    @State private var message = ""
    @State private var internalNote = false
    @State private var status = "open"
    @State private var assignee: UUID?
    @State private var operatorUUID = ""
    @State private var operatorTarget: UUID?
    @State private var operatorRecord: OperatorRecord?
    @State private var operatorRole = "agent"
    @State private var operatorEnabled = true
    @State private var operatorNotice = ""
    @State private var operatorConfirmation = false
    private struct OperatorRecord: Decodable {
        let userId: UUID
        let role: String
        let enabled: Bool
        let version: Int
    }
    // Keep the complete immutable command for uncertain retries, not just its key.
    @State private var pending: Command?
    private struct Command {
        let ticket: UUID
        let message: String
        let internalNote: Bool
        let key: UUID
        var body: [String: Any] {
            ["message": message, "internal": internalNote, "idempotencyKey": key.uuidString]
        }
    }
    private func words(_ en: String, _ ko: String) -> String { CloudWords.text(en, ko, locale) }
    private var hasDraft: Bool { !message.isEmpty || pending != nil }
    private var elevated: Bool {
        model.foreground && scenePhase == .active && token != nil && token == model.session?.token
            && (expiry ?? .distantPast) > Date() && (model.session?.expiresAt ?? .distantPast) > Date()
    }

    var body: some View {
        Form {
            Section(words("Operator verification", "운영자 인증")) {
                Text(words("Roles are assigned administratively. MFA does not grant a role. Agents see assigned tickets only; managers and admins see the queue. Server permissions apply to every request.", "역할은 관리자가 부여합니다. MFA는 역할을 부여하지 않습니다. 상담원은 배정된 문의만, 매니저와 관리자는 대기열을 봅니다. 모든 요청에 서버 권한이 적용됩니다."))
                SecureField(words("Authenticator code", "인증 앱 코드"), text: $code)
                    .keyboardType(.numberPad).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Button(words("Verify explicitly", "직접 인증")) { stepUp() }
                    .disabled(code.count != 6 || !code.allSatisfy({ $0.isASCII && $0.isNumber }) || model.session == nil)
                if let expiry {
                    LabeledContent(words("Elevation expires", "추가 인증 만료")) { Text(expiry, style: .date); Text(expiry, style: .time) }
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date < expiry ? words("No automatic renewal", "자동 갱신 없음") : words("Expired — verify again", "만료됨 — 다시 인증하세요"))
                    }
                }
                if !notice.isEmpty { Text(notice) }
                if working { ProgressView(words("Loading", "불러오는 중")) }
                if hasDraft {
                    Text(words("Finish or discard the draft before changing page, filter or ticket.", "페이지·필터·문의를 바꾸기 전에 초안을 전송하거나 버리세요."))
                    Button(words("Discard draft / retry information…", "초안 / 재시도 정보 버리기…"), role: .destructive) { confirmDiscard = true }
                }
            }
            Section(words("Ticket queue", "문의 대기열")) {
                Text(words("Creation order, 50 per page. Older replaces the list; Latest starts again. Assignments can change after a read. Leaving or backgrounding clears pages and drafts.", "생성 시각 순으로 페이지당 최대 50건입니다. 이전 페이지는 목록을 교체하고 최신 조회는 처음부터 시작합니다. 조회 후 배정이 바뀔 수 있습니다. 화면을 나가거나 백그라운드로 전환하면 페이지와 초안이 지워집니다."))
                    .font(.caption)
                Picker(words("Status filter", "상태 필터"), selection: $filter) {
                    Text(words("All", "전체")).tag("all")
                    statusOptions
                }
                Button(words("Load latest tickets", "최신 문의 불러오기")) { run { try await list() } }
                    .accessibilityIdentifier("admin.latest")
                if elevated && paging.loaded && paging.tickets.isEmpty { Text(words("No visible tickets on this page for this filter.", "이 필터의 현재 페이지에서 볼 수 있는 문의가 없습니다.")) }
                ForEach(elevated ? paging.tickets : []) { ticket in
                    Button { run { try await detail(ticket.id) } } label: {
                        VStack(alignment: .leading) {
                            Text(verbatim: ticket.subject)
                            Text(verbatim: "\(ticket.category) · \(ticket.status) · \(ticket.updatedAt)").font(.caption)
                        }
                    }
                }
                if elevated && paging.failed {
                    Button(words("Retry this page", "이 페이지 다시 조회")) { run { try await list(retry: true) } }
                } else if elevated && paging.nextCursor != nil {
                    Button(words("Older tickets", "이전 문의")) { run { try await list(older: true) } }
                        .accessibilityIdentifier("admin.older")
                } else if elevated && paging.loaded {
                    Text(words("End of tickets for this filter. Load latest to check changes.", "이 필터의 마지막 문의입니다. 변경 사항은 최신 조회로 확인하세요."))
                }
            }.disabled(!elevated || hasDraft)
            if elevated, let selected {
                Section(words("Ticket details", "문의 상세")) {
                    Text(verbatim: selected.subject).font(.headline)
                    Text(verbatim: selected.id.uuidString)
                    Text(words("Owner", "작성자") + ": " + selected.ownerId.uuidString)
                    Text(words("Created", "생성") + ": " + selected.createdAt)
                    ForEach(messages.filter { !$0.internal }) { item in messageRow(item) }
                }
                Section(words("Internal notes — not visible to customer", "내부 메모 — 고객에게 표시되지 않음")) {
                    ForEach(messages.filter { $0.internal }) { item in messageRow(item) }
                }
                Section(words("Reply or note", "답장 또는 메모")) {
                    Text(words("Plain text only. Never include credentials or verification codes. Nothing is attached or copied automatically.", "일반 텍스트만 사용하세요. 자격 증명이나 인증 코드를 포함하지 마세요. 자동 첨부나 복사는 없습니다."))
                    Toggle(words("Send as internal note (not customer-visible)", "내부 메모로 전송 (고객에게 숨김)"), isOn: $internalNote)
                    TextField(words("Message", "메시지"), text: $message, axis: .vertical).lineLimit(3...12).privacySensitive()
                    Button(internalNote ? words("Send internal note", "내부 메모 전송") : words("Send customer reply", "고객 답장 전송")) { send() }
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if pending != nil { Text(words("Unconfirmed send retained. An unchanged retry reuses its complete body and request key. Editing sends a new command.", "미확인 전송이 보관되어 있습니다. 변경 없이 재시도하면 전체 본문과 요청 키를 재사용합니다. 편집하면 새 요청을 보냅니다.")) }
                }.disabled(!elevated)
                Section(words("Status and assignment", "상태 및 배정")) {
                    Picker(words("Status", "상태"), selection: $status) { statusOptions }
                    Button(words("Load active operators", "활성 운영자 불러오기")) { run {
                        struct Result: Decodable { let operators: [AdminOperator] }
                        operators = try JSONDecoder().decode(Result.self, from: await request("v2/admin/operators")).operators.filter { $0.enabled != false }
                    } }
                    Picker(words("Assignee", "담당자"), selection: $assignee) {
                        Text(words("Unassigned", "미배정")).tag(nil as UUID?)
                        if let current = selected.assigneeId, !operators.contains(where: { $0.userId == current }) {
                            Text(verbatim: current.uuidString).tag(Optional(current))
                        }
                        ForEach(operators) { item in
                            Text(verbatim: "\(item.userId.uuidString) · \(item.role)").tag(Optional(item.userId))
                        }
                    }
                    Button(words("Save status and assignment", "상태 및 배정 저장")) { run {
                        struct Result: Decodable { let ticket: AdminTicket }
                        let body: [String: Any] = ["status": status, "assigneeId": assignee.map { $0.uuidString as Any } ?? NSNull()]
                        clearQueue()
                        let result = try JSONDecoder().decode(Result.self, from: await request("v2/admin/tickets/\(selected.id.uuidString)", method: "PUT", body: body))
                        guard result.ticket.id == selected.id else { throw SnapshotError.invalid }
                        notice = words("Status/assignment saved. Load latest tickets to recheck visibility.", "상태/배정을 저장했습니다. 최신 문의를 불러와 접근 권한을 다시 확인하세요.")
                    } }
                }.disabled(!elevated || hasDraft)
            }
            if elevated { operatorManagement }
            Section(words("Operational counts", "운영 집계")) {
                Button(words("Load metrics", "집계 불러오기")) { run {
                    metrics = try JSONDecoder().decode(AdminMetrics.self, from: await request("v2/admin/metrics"))
                } }.disabled(!elevated)
                Text(words("Snapshot counts, not revenue or active-user measurements. Unloaded values are not zero.", "스냅샷 집계이며 매출이나 활성 사용자 지표가 아닙니다. 불러오지 않은 값은 0이 아닙니다."))
                if elevated, let m = metrics {
                    LabeledContent(words("Users", "사용자"), value: "\(m.users)")
                    Text(verbatim: "Claude: \(m.accountProviders.claude) · Codex: \(m.accountProviders.codex) · Gemini: \(m.accountProviders.gemini) · Grok: \(m.accountProviders.grok)")
                    Text(words("Jobs: pending / completed / expired / cached", "작업: 대기 / 완료 / 만료 / 캐시") + "\n\(m.jobs.pending) / \(m.jobs.completed) / \(m.jobs.expired) / \(m.jobs.cached)")
                    Text(words("Support: open / waiting / resolved", "문의: 열림 / 대기 / 해결") + "\n\(m.support.open) / \(m.support.waiting) / \(m.support.resolved)")
                    Text(words("Collectors: active / expired", "수집기: 활성 / 만료") + "\n\(m.collectors.active) / \(m.collectors.expired)")
                }
            }
        }
        .navigationTitle(words("Operator support", "운영자 지원"))
        .disabled(working)
        .privacySensitive()
        .confirmationDialog(words("Discard local draft and retry information? A request already sent may still complete on the server.", "로컬 초안과 재시도 정보를 버릴까요? 이미 보낸 요청은 서버에서 완료될 수 있습니다."), isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button(words("Discard", "버리기"), role: .destructive) { message = ""; internalNote = false; pending = nil }
        }
        .onDisappear { wipe() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { wipe() } }
        .onChange(of: model.foreground) { _, active in if !active { wipe() } }
        .onChange(of: model.session?.token) { _, _ in wipe() }
        .onChange(of: model.revision) { _, _ in wipe() }
        .onChange(of: filter) { _, _ in
            generation = UUID(); operation?.cancel(); operation = nil; working = false
            clearQueue(); notice = words("Filter changed. Load latest tickets.", "필터가 바뀌었습니다. 최신 문의를 불러오세요.")
        }
        .onChange(of: notice) { _, value in
            if scenePhase == .active && model.foreground && !value.isEmpty {
                UIAccessibility.post(notification: .announcement, argument: value)
            }
        }
        .onChange(of: operatorNotice) { _, value in
            if scenePhase == .active && model.foreground && !value.isEmpty {
                UIAccessibility.post(notification: .announcement, argument: value)
            }
        }
    }

    private var statusOptions: some View {
        Group {
            Text(words("Open", "열림")).tag("open")
            Text(words("Waiting", "대기")).tag("waiting")
            Text(words("Resolved", "해결")).tag("resolved")
        }
    }
    private var operatorManagement: some View {
        Section(words("Administrator role management", "관리자 역할 관리")) {
            Text(words("Current admin authority, Apple login within five minutes, and exact-token TOTP verification are required. Self-target changes and removal of the last admin are forbidden. Server permissions apply.", "현재 관리자 권한, 5분 이내 Apple 로그인 및 동일 토큰 TOTP 인증이 필요합니다. 자기 자신 변경 및 마지막 관리자 제거는 금지됩니다. 서버 권한이 적용됩니다."))
            TextField(words("Target user UUID", "대상 사용자 UUID"), text: $operatorUUID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: operatorUUID) { _, _ in clearOperatorLookup() }
            Button(words("Look up operator", "운영자 조회")) { lookupOperator() }
                .disabled(UUID(uuidString: operatorUUID) == nil)
            if let target = operatorTarget {
                LabeledContent(words("Loaded target", "조회한 대상"), value: target.uuidString)
                if let record = operatorRecord {
                    LabeledContent(words("Loaded role", "조회한 역할"), value: record.role)
                    LabeledContent(words("Loaded enabled", "조회한 활성 상태"), value: record.enabled ? words("Yes", "예") : words("No", "아니요"))
                    LabeledContent(words("Server version", "서버 버전"), value: String(record.version))
                } else {
                    Text(words("No operator record (404). This does not establish whether the user exists. Creation uses expected version 0.", "운영자 기록이 없습니다 (404). 사용자 존재 여부를 뜻하지 않습니다. 생성 시 예상 버전은 0입니다."))
                }
                Picker(words("New role", "새 역할"), selection: $operatorRole) {
                    Text(words("Agent", "상담원")).tag("agent")
                    Text(words("Manager", "매니저")).tag("manager")
                    Text(words("Admin", "관리자")).tag("admin")
                }
                Toggle(words("Enabled", "활성"), isOn: $operatorEnabled)
                Text(words("Any actual change revokes the target's sessions, collectors, pairings and pending enrollment. Disabling also unassigns their tickets. No automatic mutation retry; reload after any uncertain result or version conflict.", "실제 변경은 대상의 세션, 수집기, 페어링 및 진행 중 등록을 모두 폐기합니다. 비활성화하면 문의 배정도 해제됩니다. 변경은 자동 재시도하지 않습니다. 결과가 불확실하거나 버전 충돌 시 다시 조회하세요."))
                Button(words("Review role change…", "역할 변경 검토…"), role: .destructive) { operatorConfirmation = true }
            }
            if !operatorNotice.isEmpty { Text(operatorNotice) }
        }
        .disabled(!elevated)
        .confirmationDialog(words("Confirm operator change", "운영자 변경 확인"), isPresented: $operatorConfirmation, titleVisibility: .visible) {
            Button(words("Apply and revoke target access", "적용 및 대상 접근 폐기"), role: .destructive) { saveOperator() }
            Button(words("Cancel", "취소"), role: .cancel) {}
        } message: {
            Text("\(operatorTarget?.uuidString ?? "")\n\(operatorRole) · \(operatorEnabled ? words("Enabled", "활성") : words("Disabled", "비활성"))\n" + words("Actual changes revoke sessions, collectors, pairings and pending enrollment. Disabling unassigns tickets.", "실제 변경 시 세션, 수집기, 페어링 및 진행 중 등록이 폐기됩니다. 비활성화 시 문의 배정이 해제됩니다."))
        }
    }
    private func clearOperatorLookup() {
        operatorTarget = nil; operatorRecord = nil; operatorRole = "agent"; operatorEnabled = true
        operatorConfirmation = false; operatorNotice = ""
    }
    private func installOperator(_ record: OperatorRecord, target: UUID) throws {
        guard record.userId == target, record.version > 0,
              ["agent", "manager", "admin"].contains(record.role) else { throw SnapshotError.invalid }
        operatorTarget = record.userId; operatorRecord = record
        operatorRole = record.role; operatorEnabled = record.enabled
    }
    private func lookupOperator() {
        guard let target = UUID(uuidString: operatorUUID) else { return }
        clearOperatorLookup()
        run {
            let current = generation
            do {
                let data = try await request("v2/admin/operators/\(target.uuidString)", maximumResponseBytes: 4096)
                try installOperator(JSONDecoder().decode(OperatorRecord.self, from: data), target: target)
            } catch CloudHTTPError.notFound {
                guard current == generation, elevated else { return }
                operatorTarget = target
            }
        }
    }
    private func saveOperator() {
        guard let target = operatorTarget, elevated, !working else { return }
        let body: [String: Any] = ["role": operatorRole, "enabled": operatorEnabled, "expectedVersion": operatorRecord?.version ?? 0]
        run {
            let current = generation
            // Invalidate the editable snapshot before sending: even uncertain outcomes require a lookup.
            clearOperatorLookup()
            do {
                let data = try await request("v2/admin/operators/\(target.uuidString)", method: "PUT", body: body, maximumResponseBytes: 4096)
                try installOperator(JSONDecoder().decode(OperatorRecord.self, from: data), target: target)
                operatorNotice = words("Server result loaded, including its unchanged version for a no-op.", "서버 결과를 불러왔습니다. 변경이 없으면 기존 버전이 유지됩니다.")
            } catch {
                guard current == generation, elevated else { return }
                if case CloudHTTPError.rejected(status: 409, code: _) = error {
                    operatorNotice = words("409: stale version. Look up the target again before making another change. The version was not incremented locally.", "409: 오래된 버전입니다. 다시 변경하기 전에 대상을 조회하세요. 버전을 로컬에서 증가시키지 않았습니다.")
                } else {
                    operatorNotice = words("Change not confirmed. Permission or fresh Apple/TOTP verification may be required. Look up the target before trying again; no automatic retry.", "변경이 확인되지 않았습니다. 권한 또는 새로운 Apple/TOTP 인증이 필요할 수 있습니다. 재시도 전 대상을 조회하세요. 자동 재시도는 없습니다.")
                }
            }
        }
    }
    private func messageRow(_ item: AdminMessage) -> some View {
        VStack(alignment: .leading) {
            Text(item.staff ? words("Staff", "직원") : words("Customer", "고객")).font(.caption)
            Text(verbatim: item.message).textSelection(.enabled)
            Text(verbatim: item.createdAt).font(.caption)
        }
    }
    private func wipe() {
        operation?.cancel(); operation = nil; expiryTask?.cancel(); expiryTask = nil; working = false
        generation = UUID(); code = ""; token = nil; expiry = nil; confirmDiscard = false
        clearQueue(); operators = []; metrics = nil
        message = ""; internalNote = false; pending = nil; assignee = nil; status = "open"; notice = ""
        operatorUUID = ""; clearOperatorLookup()
    }
    private func clearQueue() {
        paging.reset(); selected = nil; messages = []; message = ""; internalNote = false
        pending = nil; assignee = nil; status = "open"
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !working, model.foreground, scenePhase == .active, let exact = model.session?.token else { return }
        working = true; notice = ""
        let current = generation
        let owner = model.revision
        operation = Task { @MainActor in
            defer { if current == generation { working = false; operation = nil } }
            guard current == generation, owner == model.revision, model.session?.token == exact, model.foreground, !Task.isCancelled else { return }
            do { try await action() }
            catch {
                guard current == generation, owner == model.revision, model.session?.token == exact, model.foreground, !Task.isCancelled else { return }
                notice = paging.failed
                    ? words("Page unavailable. Retry this page or load latest. No automatic retry was sent.", "페이지를 불러오지 못했습니다. 이 페이지를 다시 조회하거나 최신 문의를 불러오세요. 자동 재시도하지 않았습니다.")
                    : words("Request failed, permission denied, or verification expired. Paging requires the matching server API. No automatic retry or renewal. For uncertain sends retry unchanged; reload before repeating a status change.", "요청 실패, 권한 부족 또는 인증 만료입니다. 페이지 조회를 지원하는 서버가 필요합니다. 자동 재시도나 갱신은 없습니다. 미확인 전송은 변경 없이 재시도하고 상태 변경은 다시 조회한 후 진행하세요.")
            }
        }
    }
    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, maximumResponseBytes: Int = 256 * 1024) async throws -> Data {
        guard elevated, let token else { throw CancellationError() }
        let current = generation
        do {
            let data = try await model.securityRequest(path, method: method, body: body, exactToken: token, maximumResponseBytes: maximumResponseBytes)
            guard current == generation, elevated, !Task.isCancelled else { throw CancellationError() }
            return data
        } catch {
            guard current == generation, model.session?.token == token, model.foreground, !Task.isCancelled else { throw CancellationError() }
            switch error as? CloudHTTPError {
            case .unauthorized:
                wipe()
                notice = words("Session rejected. Return to cloud settings to sign in again.", "세션이 거부되었습니다. 클라우드 설정에서 다시 로그인하세요.")
            case .rejected(status: 403, code: _):
                // A manager-only action can be denied to an otherwise valid agent.
                // Clear protected snapshots without pretending MFA grants that role.
                clearQueue(); operators = []; metrics = nil; clearOperatorLookup()
            case .notFound:
                if path.hasPrefix("v2/admin/tickets") { clearQueue() }
            default: break
            }
            throw error
        }
    }
    private func stepUp() {
        let input = code
        wipe()
        run {
            guard let exact = model.session?.token, scenePhase == .active else { throw CancellationError() }
            let current = generation
            token = nil; expiry = nil
            struct Grant: Decodable { let expiresAt: String }
            let data = try await model.securityRequest("v2/security/step-up", method: "POST", body: ["code": input], exactToken: exact)
            let end = try CloudMFAChallenge.date(JSONDecoder().decode(Grant.self, from: data).expiresAt)
            guard current == generation, model.session?.token == exact, scenePhase == .active, end > Date() else { throw CancellationError() }
            let deadline = min(end, model.session?.expiresAt ?? end)
            token = exact; expiry = deadline
            expiryTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)) }
                catch { return }
                guard token == exact, expiry == deadline else { return }
                wipe()
                notice = words("Verification expired. Verify again and load latest tickets.", "인증이 만료되었습니다. 다시 인증하고 최신 문의를 불러오세요.")
            }
        }
    }
    private func list(older: Bool = false, retry: Bool = false) async throws {
        selected = nil; messages = []; message = ""; internalNote = false; pending = nil
        let read = try paging.begin(older: older, retry: retry, staff: true, status: filter == "all" ? nil : filter)
        do {
            let data = try await request(read.path)
            try paging.finish(data, read: read)
            notice = words("Ticket page loaded.", "문의 페이지를 불러왔습니다.")
        } catch { paging.fail(read); throw error }
    }
    private func install(_ ticket: AdminTicket) {
        selected = ticket; status = ticket.status; assignee = ticket.assigneeId
    }
    private func detail(_ id: UUID) async throws {
        struct Result: Decodable { let ticket: AdminTicket; let messages: [AdminMessage] }
        selected = nil; messages = []; message = ""; internalNote = false; pending = nil
        let result = try JSONDecoder().decode(Result.self, from: await request("v2/admin/tickets/\(id.uuidString)", maximumResponseBytes: 2 * 1024 * 1024))
        guard result.ticket.id == id, result.messages.count <= 100 else { throw SnapshotError.invalid }
        install(result.ticket); messages = result.messages
    }
    private func send() {
        guard !working, let selected else { return }
        let command: Command
        if let old = pending, old.ticket == selected.id, old.message == message, old.internalNote == internalNote { command = old }
        else { command = Command(ticket: selected.id, message: message, internalNote: internalNote, key: UUID()) }
        pending = command
        run {
            struct Result: Decodable { let ok: Bool }
            let result = try JSONDecoder().decode(Result.self, from: await request("v2/admin/tickets/\(command.ticket.uuidString)/messages", method: "POST", body: command.body))
            guard result.ok else { throw SnapshotError.invalid }
            pending = nil; message = ""; internalNote = false
            try await detail(command.ticket)
        }
    }
}
