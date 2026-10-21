import SwiftUI

struct AccountWatchContent: View {
    let snapshot: AccountSurfaceSnapshot?
    let savedAt: Date?
    let reloadCache: () -> Void
    let trustCompanion: () -> Void
    @State private var confirmTrust = false
    @State private var showConnectionSettings = false
    @AppStorage("watch.accountSurface.selectedUUID") private var selected = ""
    @AppStorage("watch.accountSurface.window") private var window = "primary"
    private var id: UUID? { UUID(uuidString: selected) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(DockL10n.text("Allowmark")).font(.headline)
                Picker(DockL10n.text("Account"), selection: $selected) {
                    Text(DockL10n.text("Choose account")).tag("")
                    // Preserve the stored missing selection rather than retargeting it.
                    if !selected.isEmpty, snapshot?.account(id) == nil {
                        Text(DockL10n.text("Account unavailable")).tag(selected)
                    }
                    ForEach(snapshot?.accounts ?? []) { account in
                        Text("\(account.provider.displayName) · \(String(account.id.uuidString.prefix(8)))")
                            .accessibilityLabel("\(account.provider.displayName) · \(account.identifier)")
                            .tag(account.id.uuidString.lowercased())
                    }
                }
                #if os(watchOS)
                .pickerStyle(.navigationLink)
                .frame(minHeight: 44)
                #endif
                Picker(DockL10n.text("Window"), selection: $window) {
                    ForEach(["primary", "secondary", "tertiary", "weekly", "pro"], id: \.self) {
                        Text(DockL10n.text($0.capitalized)).tag($0)
                    }
                }
                #if os(watchOS)
                .pickerStyle(.navigationLink)
                .frame(minHeight: 44)
                #endif
                AccountSurfaceContent(snapshot: snapshot, accountID: id, windowID: window,
                                      date: Date(), surface: .small)
                    .padding(10)
                    .background(DockTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                Button {
                    showConnectionSettings.toggle()
                } label: {
                    HStack {
                        Text(DockL10n.text("Connection settings"))
                        Spacer(minLength: 4)
                        Image(systemName: showConnectionSettings ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                    }.frame(minHeight: 44)
                }
                .font(.caption)
                .accessibilityAddTraits(showConnectionSettings ? [.isSelected] : [])
                if showConnectionSettings {
                    VStack(alignment: .leading, spacing: 10) {
                        if let snapshot {
                            Text(DockL10n.format("Snapshot prepared on iPhone: %@", DockL10n.date(snapshot.generatedAt))).font(.caption2)
                        }
                        if let savedAt {
                            Text(DockL10n.format("Saved on Watch: %@", DockL10n.date(savedAt))).font(.caption2)
                        }
                        Text(DockL10n.text("Works offline with saved data. Watch cannot fetch usage or sign in. Refresh on iPhone for new readings; transfer may be delayed and is not guaranteed."))
                            .font(.caption2).foregroundStyle(.secondary)
                        Button(DockL10n.text("Reload local cache"), action: reloadCache)
                        Button(DockL10n.text("Trust paired iPhone")) { confirmTrust = true }
                            .confirmationDialog(DockL10n.text("Replace cached account authority with this paired iPhone?"), isPresented: $confirmTrust) {
                                Button(DockL10n.text("Trust paired iPhone"), role: .destructive, action: trustCompanion)
                            }
                    }.font(.caption)
                }
            }
        }.background(DockTheme.graphite).tint(DockTheme.mint).preferredColorScheme(.dark)
    }
}

// Shared with the DEBUG iPhone host: no connectivity or credentials in this view.
struct WatchContent: View {
    @Environment(\.locale) private var locale
    @State private var confirmTrust = false
    @State private var showConnectionSettings = false
    let snapshot: Snapshot?
    let savedAt: Date?
    let demo: Bool
    let toggleDemo: () -> Void
    let reloadCache: () -> Void
    var trustCompanion: (() -> Void)? = nil

    var body: some View {
        let _ = locale
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(DockL10n.text("Allowmark")).font(.headline)
                if demo || snapshot?.demo == true {
                    Text(DockL10n.text("DEMO · sample data, not live usage")).foregroundStyle(DockTheme.mint)
                }
                Text(DockL10n.text("Cached readings · not live")).font(.caption)
                if let snapshot {
                    if snapshot.providers.isEmpty {
                        Text(DockL10n.text("No provider readings in this snapshot. Refresh on iPhone."))
                    }
                    ForEach(snapshot.providers) { ProviderCard(provider: $0, demo: snapshot.demo) }
                } else {
                    Text(DockL10n.text("No readable local cache"))
                    Text(DockL10n.text("Pair with iPhone, refresh there, then open both apps. A cache may also be unavailable before the first unlock after restart."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(DockL10n.text("First account per provider only")).font(.caption2).foregroundStyle(.secondary)
                Button(DockL10n.text(demo ? "Leave demo" : "Explore demo"), action: toggleDemo)
                Button {
                    showConnectionSettings.toggle()
                } label: {
                    HStack {
                        Text(DockL10n.text("Connection settings"))
                        Spacer(minLength: 4)
                        Image(systemName: showConnectionSettings ? "chevron.up" : "chevron.down").accessibilityHidden(true)
                    }.frame(minHeight: 44)
                }
                .font(.caption)
                .accessibilityAddTraits(showConnectionSettings ? [.isSelected] : [])
                if showConnectionSettings {
                    VStack(alignment: .leading, spacing: 10) {
                        if let snapshot, !demo && !snapshot.demo {
                            Text(DockL10n.format("Snapshot prepared on iPhone: %@", DockL10n.date(snapshot.generatedAt)))
                                .font(.caption2).foregroundStyle(.secondary)
                            if let savedAt {
                                Text(DockL10n.format("Saved on Watch: %@", DockL10n.date(savedAt)))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(DockL10n.text("Observed times belong to each provider. Stale readings are over 15 minutes old; missing observation times mean freshness is unknown."))
                            .font(.caption2).foregroundStyle(.secondary)
                        Text(DockL10n.text("Works offline with saved data. Watch cannot fetch usage or sign in. Refresh on iPhone for new readings; transfer may be delayed and is not guaranteed."))
                            .font(.caption2).foregroundStyle(.secondary)
                        Button(DockL10n.text("Reload local cache"), action: reloadCache).disabled(demo)
                        if let trustCompanion {
                            Button(DockL10n.text("Trust paired iPhone")) { confirmTrust = true }
                                .confirmationDialog(DockL10n.text("Replace cached account authority with this paired iPhone?"), isPresented: $confirmTrust) {
                                    Button(DockL10n.text("Trust paired iPhone"), role: .destructive, action: trustCompanion)
                                }
                        }
                        Text(DockL10n.text("Reload only reads this Watch’s cache; it does not request an iPhone refresh."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
        }.background(DockTheme.graphite).tint(DockTheme.mint).preferredColorScheme(.dark)
    }
}
