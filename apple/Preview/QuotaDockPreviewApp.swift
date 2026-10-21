import SwiftUI

// A distinct app/container, not a capability downgrade of QuotaDock's signed app.
// This target never constructs a connection, client, purchase or Watch session.
@main
struct QuotaDockPreviewApp: App {
    @StateObject private var settings = InterfaceSettings()
    @State private var needsSetup = !SetupStore.load().completed

    var body: some Scene {
        WindowGroup {
            Group {
                if ProcessInfo.processInfo.arguments.contains("--history-preview") {
                    PreviewHistory()
                } else if needsSetup {
                    FirstRunView(settings: settings) { _ in needsSetup = false }
                } else {
                    PreviewDashboard(settings: settings)
                }
            }
            .environment(\.locale, settings.locale)
            .tint(DockTheme.mint)
        }
    }
}

private struct PreviewHistory: View {
    private let largest = ProcessInfo.processInfo.arguments.contains("--history-largest-preview")
    var body: some View {
        NavigationStack {
            Form {
                PreviewNotice(identifier: "history-preview-notice")
                HistoryPreviewContext()
                if let page = try? CloudHistoryPage.decode(Data("""
                {"accountId":"00000001-0000-4000-8000-000000000000","provider":"codex","enabled":true,"retentionDays":7,"maximumSamplesPerAccount":1000,"observations":[{"plan":"ChatGPT Plus","state":"available","source":"codexbar","observedAt":"2026-10-21T05:00:00.123999Z","windows":[{"id":"primary","label":"Session","remainingPercent":0,"resetsAt":"2026-10-21T04:00:00Z"},{"id":"secondary","label":"Weekly","remainingPercent":null,"resetsAt":null},{"id":"tertiary","label":"Credits","remainingPercent":42.75,"resetsAt":null}]}],"nextCursor":null}
                """.utf8), accountID: UUID(uuidString: "00000001-0000-4000-8000-000000000000")!, provider: .codex) {
                    CloudHistoryDetails(observations: page.observations)
                } else { Text("Invalid synthetic history fixture") }
            }
            .navigationTitle("History UI preview")
        }
        .dynamicTypeSize(largest ? .accessibility5 : .large)
        .preferredColorScheme(largest ? .dark : .light)
    }
}

private struct HistoryPreviewContext: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var type
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let typeName = type == .accessibility5 ? "accessibility5" : type == .large ? "large" : "unexpected: \(String(describing: type))"
        Text("locale=\(locale.identifier); type=\(typeName); scheme=\(scheme == .dark ? "dark" : "light")")
            .font(.caption).accessibilityIdentifier("history-preview-context")
    }
}

struct PreviewNotice: View {
    @Environment(\.locale) private var locale
    let identifier: String

    var body: some View {
        let _ = locale
        Text(setupText("UI PREVIEW · sample data only"))
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}

private enum SampleScenario: String, CaseIterable {
    case sample = "Sample readings", unknown = "Unknown readings"
    case stale = "Stale readings", exhausted = "Exhausted readings"

    func snapshot(from original: Snapshot) -> Snapshot {
        let providers = original.providers.map { provider in
            Provider(id: provider.id, name: provider.name,
                     plan: self == .unknown ? nil : provider.plan,
                     state: self == .unknown ? .unavailable : provider.state,
                     source: .demo, message: nil,
                     observedAt: self == .unknown ? nil : provider.observedAt.map {
                         self == .stale ? $0.addingTimeInterval(-3600) : $0
                     }, windows: provider.windows.map { window in
                QuotaWindow(id: window.id, label: window.label,
                            remainingPercent: self == .unknown ? nil :
                                self == .exhausted && provider.state == .available ? 0 : window.remainingPercent,
                            resetsAt: self == .unknown ? nil : window.resetsAt)
            })
        }
        return Snapshot(schemaVersion: 1, generatedAt: original.generatedAt, demo: true, providers: providers)
    }
}

private struct PreviewDashboard: View {
    @ObservedObject var settings: InterfaceSettings
    // Preserve the original sample observation time across language/scenario changes.
    @State private var original = Snapshot.preview
    @State private var scenario = SampleScenario.sample
    @State private var showSettings = false
    @State private var reviewAfterSettings = false
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PreviewNotice(identifier: "preview-notice-dashboard")
                    Picker(setupText("Sample state"), selection: $scenario) {
                        ForEach(SampleScenario.allCases, id: \.self) { state in
                            Text(setupText(state.rawValue)).tag(state)
                        }
                    }
                    .id(settings.locale.identifier)
                    .accessibilityIdentifier("preview-scenario")
                    ForEach(scenario.snapshot(from: original).providers) { provider in
                        ProviderCard(provider: provider, demo: true)
                    }
                    Text(setupText("Free plan support varies by environment and rollout. Unavailable measurements mean Unknown, not exhausted allowance or confirmed ineligibility."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(setupText("This preview uses sample data only. Apple login, connections, purchases, widgets and Watch are not included."))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background(DockTheme.background)
            .navigationTitle(DockL10n.text("Allowmark"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                Button(setupText("Settings"), systemImage: "gearshape") { showSettings = true }
                    .accessibilityIdentifier("preview-settings")
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            if reviewAfterSettings { reviewAfterSettings = false; showSetup = true }
        }) {
            NavigationStack {
                Form {
                    PreviewNotice(identifier: "preview-notice-settings")
                    InterfaceLanguagePicker(settings: settings)
                    NavigationLink(DockL10n.text("Plans")) {
                        Form {
                            PreviewNotice(identifier: "preview-notice-plans")
                            SubscriptionPanel(available: false, busy: false,
                                status: "Sample products and prices only. No payment is connected.",
                                options: [], currentTier: "free", load: {}, purchase: { _ in }, restore: {})
                        }.navigationTitle(DockL10n.text("Plans"))
                    }
                    Toggle(setupText("Refresh when I open the app"), isOn: Binding(
                        get: { settings.foregroundAutoRefresh },
                        set: { settings.chooseForegroundRefresh($0) }
                    ))
                    Text(setupText("Preview preferences are saved only in this separate app. No usage is collected or refreshed."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(setupText("Review setup")) {
                        reviewAfterSettings = true; showSettings = false
                    }.accessibilityIdentifier("preview-review-setup")
                }
                .navigationTitle(setupText("Settings"))
                .toolbar { Button(setupText("Done")) { showSettings = false } }
            }
        }
        .sheet(isPresented: $showSetup) {
            FirstRunView(settings: settings, revisit: true, finish: { _ in showSetup = false },
                         cancel: { showSetup = false })
        }
    }
}
