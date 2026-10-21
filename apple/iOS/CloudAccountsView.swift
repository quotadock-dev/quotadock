import SwiftUI
import UIKit

// Slot UUIDs own linkage. Names/emails are private labels, never proof of identity.
struct CloudAccountsView: View {
    @ObservedObject var model: CloudModel
    var requestedAccountID: UUID? = nil
    var lowQuotaThreshold: Int? = nil
    @State private var path: [UUID] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale
        NavigationStack(path: $path) {
            List {
                if model.session != nil {
                    Section(DockL10n.text("Accounts")) {
                        ForEach(model.slots) { slot in
                            NavigationLink(value: slot.id) {
                                HStack(spacing: 14) {
                                    ProviderIcon(id: slot.provider)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(model.accountTitle(slot.id, provider: slot.provider))
                                            .font(.headline)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .privacySensitive()
                                        Text(slot.provider.displayName)
                                            .font(.system(size: 13)).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                        }
                        Menu {
                            ForEach([ProviderID.claude, .codex, .gemini, .grok], id: \.self) { provider in
                                Button(provider.displayName) {
                                    Task { await model.mutate(path: "v2/accounts", method: "POST", body: ["provider": provider.rawValue]) }
                                }
                            }
                        } label: {
                            Label(DockL10n.text("Add account"), systemImage: "plus")
                        }
                        .disabled(model.busy || model.selectionLocked || model.me == nil ||
                            model.me?.limits.accounts.map { model.slots.count >= $0 } == true)
                    }
                    if model.snapshot?.cachedSubset == true {
                        Text(DockL10n.text("Offline cache: first 50 slots only, not the complete account list. Read the server for all slots."))
                            .font(.caption)
                    }
                    Text(DockL10n.text(model.status)).font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    NavigationLink(DockL10n.text(model.session == nil ? "Connect with Apple" : "Connection settings")) {
                        CloudView(model: model, lowQuotaThreshold: lowQuotaThreshold)
                    }
                    NavigationLink(DockL10n.text("Plans")) { PlansView(model: model) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(DockTheme.background)
            .navigationTitle(DockL10n.text("Accounts"))
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: UUID.self) { id in
                CloudAccountDetailsView(model: model, accountID: id, lowQuotaThreshold: lowQuotaThreshold)
            }
            .toolbar { Button(DockL10n.text("Done")) { dismiss() } }
            .refreshable { await model.read() }
            .task {
                if let requestedAccountID { path = [requestedAccountID] }
                if model.session != nil { await model.read() }
            }
            .onChange(of: requestedAccountID) { _, id in
                if let id { path = [id] }
            }
        }
    }
}

private struct CloudAccountDetailsView: View {
    @ObservedObject var model: CloudModel
    @Environment(\.locale) private var locale
    let accountID: UUID
    var lowQuotaThreshold: Int? = nil
    @State private var code = ""
    @State private var consentAuthority: String?
    @State private var confirmRemove = false
    @State private var removalAuthority: String?

    var body: some View {
        let _ = locale
        Form {
            if let slot = model.slots.first(where: { $0.id == accountID }), model.session != nil {
                Section {
                    HStack(spacing: 12) {
                        ProviderIcon(id: slot.provider)
                        Text(model.accountTitle(slot.id, provider: slot.provider))
                            .font(.title3.bold()).privacySensitive()
                    }
                    CloudAccountLabelField(draft: model.accountLabel(slot.id)) {
                        model.setAccountLabel($0, id: slot.id)
                    }.id("\(model.labelScope ?? "")/\(slot.id)")
                } footer: {
                    Text(DockL10n.text("Name or email stays on this iPhone. It does not verify your AI account."))
                }
                Section {
                    if let account = model.snapshot?.accounts.first(where: { $0.id == slot.id && $0.provider == slot.provider }) {
                        ProviderCard(provider: account.reading, demo: model.snapshot?.demo == true, lowQuotaThreshold: lowQuotaThreshold)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowBackground(Color.clear)
                        if account.lastError != nil {
                            Text(DockL10n.text("Last collection unavailable; original observation retained.")).font(.caption)
                        }
                    } else {
                        Text(DockL10n.text("Unknown — awaiting local collector"))
                    }
                }
                Section {
                    NavigationLink(CloudWords.text("Quota history", "할당량 이력", locale)) {
                        CloudHistoryView(model: model, account: slot)
                    }
                }
                Section {
                    TextField(DockL10n.text("Eight uppercase hex pairing code"), text: $code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled().privacySensitive()
                        .disabled(model.busy || model.selectionLocked)
                        .onChange(of: code) { _, _ in consentAuthority = nil }
                    Toggle(DockL10n.text("Authorize collection for this account"), isOn: Binding(
                        get: { consentAuthority != nil && consentAuthority == model.labelScope },
                        set: { consentAuthority = $0 ? model.labelScope : nil }))
                        .disabled(model.busy || model.selectionLocked)
                    Button(DockL10n.text("Approve this account")) {
                        let submitted = code
                        guard let authority = consentAuthority, authority == model.labelScope,
                              CollectorApproval.valid(code: submitted, selected: [accountID], slots: model.slots) else { return }
                        consentAuthority = nil
                        Task {
                            guard model.labelScope == authority else { return }
                            await model.mutate(path: "v2/collector/approve", method: "POST",
                                body: ["code": submitted, "accountIds": [accountID.uuidString]])
                        }
                    }
                    .disabled(consentAuthority == nil || consentAuthority != model.labelScope ||
                        !CollectorApproval.valid(code: code, selected: [accountID], slots: model.slots) ||
                        model.busy || model.selectionLocked)
                } header: {
                    Text(DockL10n.text("Link this account"))
                } footer: {
                    Text(DockL10n.text("Enter the code from your computer. Approval allows collection, not provider sign-in."))
                }
                Text(DockL10n.text(model.status)).font(.caption).foregroundStyle(.secondary)
                DisclosureGroup(DockL10n.text("Account ID")) {
                    Text(slot.id.uuidString).font(.caption).textSelection(.enabled)
                    Button(DockL10n.text("Copy nonsecret slot UUID")) { UIPasteboard.general.string = slot.id.uuidString }
                    if slot.provider == .gemini {
                        Text(DockL10n.text("Gemini collection supports one local account."))
                    }
                }
                Section {
                    NavigationLink(DockL10n.text("Collector access")) { CloudView(model: model, lowQuotaThreshold: lowQuotaThreshold) }
                    Button(DockL10n.text("Remove account"), role: .destructive) {
                        removalAuthority = model.labelScope; confirmRemove = true
                    }
                        .disabled(model.busy || model.selectionLocked)
                }
            } else {
                Section {
                    Text(DockL10n.text("Account unavailable"))
                    Text(DockL10n.text("Account not listed. Refresh the account list or sign in again."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(DockL10n.text("Refresh")) { Task { await model.read() } }
                        .disabled(model.session == nil || model.busy)
                    NavigationLink(DockL10n.text(model.session == nil ? "Connect with Apple" : "Connection settings")) {
                        CloudView(model: model, lowQuotaThreshold: lowQuotaThreshold)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DockTheme.background)
        .navigationTitle(DockL10n.text("Account"))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.labelScope) { _, _ in
            code = ""; consentAuthority = nil; confirmRemove = false; removalAuthority = nil
        }
        .confirmationDialog(DockL10n.text("Remove this account and its saved readings?"), isPresented: $confirmRemove) {
            Button(DockL10n.text("Remove account"), role: .destructive) {
                guard let authority = removalAuthority else { return }
                Task {
                    guard model.labelScope == authority, model.slots.contains(where: { $0.id == accountID }) else { return }
                    await model.mutate(path: "v2/accounts/\(accountID.uuidString)", method: "DELETE")
                }
            }
        }
    }
}

private struct CloudAccountLabelField: View {
    @Environment(\.locale) private var locale
    @State var draft: String
    let save: (String) -> Void
    var body: some View {
        let _ = locale
        TextField(DockL10n.text("Account name or email"), text: $draft)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .privacySensitive()
            .onChange(of: draft) { _, value in
                let bounded = String(value.prefix(CloudAccountLabels.maximumLength))
                if bounded != value { draft = bounded }
                save(bounded)
            }
    }
}
