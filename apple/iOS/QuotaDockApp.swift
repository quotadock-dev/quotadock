import SwiftUI
import WidgetKit

@MainActor
final class DockModel: ObservableObject {
    @Published var snapshot = SnapshotStore.load()
    @Published var status = "Pair your HTTPS bridge or explore demo data."
    @Published var busy = false
    @Published var demo = false
    let cloud = CloudModel()
    var pairingRevision = 0

    init() {
        cloud.onSwitch = { [weak self] in self?.clearReadings() }
        cloud.onSnapshot = { [weak self] next in
            guard let self, !self.demo, let generation = self.cloud.connectionGeneration else { return }
            do { try SnapshotStore.save(next, generation: generation) }
            catch {
                self.status = "Readings received, but offline cache could not be saved. Original observation times retained."
                return
            }
            self.snapshot = next
            WatchSync.shared.send()
            WidgetCenter.shared.reloadAllTimelines()
        }
        if (try? ConnectionStore.current()) == nil, PairingStore.legacyExists || CloudSessionStore.legacyExists {
            status = "Reconnect this device. Old connection records are inactive; choose your bridge or cloud account again."
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            demo = true
            snapshot = .preview
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--unknown-preview") {
            demo = true
            snapshot = Snapshot(schemaVersion: 1, generatedAt: Date(), demo: true,
                                providers: Snapshot.preview.providers.filter { $0.id == .grok })
        }
        if ProcessInfo.processInfo.arguments.contains("--connection-error-preview") {
            demo = true; snapshot = .preview
            status = "Bridge pairing rejected. Pair again; original observations retained."
        }
        if ProcessInfo.processInfo.arguments.contains("--cloud-expired-preview") {
            demo = true; snapshot = .preview
            cloud.status = "DEMO · Sign in again — cloud session expired or rejected. Original observations retained."
        }
        if ProcessInfo.processInfo.arguments.contains("--cloud-erasing-preview") {
            demo = true; snapshot = .preview
            cloud.busy = true
            cloud.status = "DEMO · Local account cleared. Waiting for server erasure confirmation."
        }
        #endif
    }

    func clearReadings() {
        pairingRevision += 1
        snapshot = nil
        demo = false
        WatchSync.shared.send()
        WidgetCenter.shared.reloadAllTimelines()
    }

    func refresh(automatic: Bool = false) async {
        guard !busy, !demo else { return }
        if cloud.session != nil {
            let revision = cloud.revision
            await cloud.read()
            if cloud.session == nil, !demo { status = cloud.status; return }
            guard revision == cloud.revision, !demo else { return }
            await cloud.refresh(force: !automatic)
            if cloud.session == nil, !demo { status = cloud.status }
            return
        }
        busy = true
        let revision = pairingRevision
        defer { busy = false }
        do {
            let generation = try ConnectionStore.current().generation
            let pairing = try PairingStore.load()
            let next = try await BridgeClient().fetch(pairing, authorityCheck: {
                try ConnectionStore.assertBridge(pairing, generation: generation)
            })
            guard revision == pairingRevision, !demo else { return }
            try SnapshotStore.save(next, generation: generation)
            snapshot = next
            status = ConnectionStore.cleanupComplete ? "Updated · bridge may serve a cached reading."
                : "Connected. Inactive local data cleanup is incomplete; old credentials cannot be selected."
            WatchSync.shared.send()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            guard revision == pairingRevision, !demo else { return }
            switch error as? BridgeTransportError {
            case .unauthorized: status = "Bridge pairing rejected. Pair again; original observations retained."
            case .forbidden: status = "Bridge access refused. Check the bridge's access policy; original observations retained."
            default: status = "Refresh unavailable. Showing cached data, if any. Check pairing and connection."
            }
        }
    }
}

@main
struct QuotaDockApp: App {
    @StateObject private var model = DockModel()
    @StateObject private var settings = InterfaceSettings()
    @State private var needsSetup = !SetupStore.load().completed
    @State private var initialRoute = SetupRoute.later
    @State private var requestedAccountID: UUID?
    @Environment(\.scenePhase) private var scenePhase
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--reset-setup-test") {
            // Simulator UI tests reset only local setup, never credentials or quota cache.
            UserDefaults.standard.removeObject(forKey: SetupStore.key)
            UserDefaults.standard.removeObject(forKey: RefreshSettings.foregroundKey)
            _needsSetup = State(initialValue: true)
        }
        #endif
    }
    private var setupPreview: SetupStep? {
        #if DEBUG
        return SetupStep.allCases.first { ProcessInfo.processInfo.arguments.contains("--onboarding-\($0.rawValue)-preview") }
        #else
        return nil
        #endif
    }
    private var previewBypassesSetup: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--demo") && setupPreview == nil &&
            !ProcessInfo.processInfo.arguments.contains("--reset-setup-test")
        #else
        return false
        #endif
    }
    private var showingSetup: Bool { setupPreview != nil || (needsSetup && !previewBypassesSetup) }
    var body: some Scene {
        WindowGroup {
            Group {
                if showingSetup {
                    FirstRunView(settings: settings, previewStep: setupPreview) { route in
                        initialRoute = route
                        needsSetup = false
                    }
                } else {
                    DockView(model: model, settings: settings, initialRoute: initialRoute,
                             requestedAccountID: $requestedAccountID)
                }
            }
                .environment(\.locale, settings.locale)
                .tint(DockTheme.mint)
                .onOpenURL { url in
                    if let id = AccountSurfaceSnapshot.accountID(from: url) { requestedAccountID = id }
                }
                .task(id: showingSetup) {
                    WatchSync.shared.start()
                    model.cloud.foreground = scenePhase == .active && !showingSetup
                    guard !showingSetup, initialRoute == .later else { return }
                    if settings.foregroundAutoRefresh { await model.refresh(automatic: true) }
                }
                .onChange(of: scenePhase) { _, phase in
                    model.cloud.foreground = phase == .active && !showingSetup
                    if phase == .active && !showingSetup && settings.foregroundAutoRefresh {
                        Task { await model.refresh(automatic: true) }
                    }
                }
        }
    }
}

struct DockView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var settings: InterfaceSettings
    var initialRoute = SetupRoute.later
    @Binding var requestedAccountID: UUID?
    @State private var showPairing = false
    @State private var showSettings = false
    @State private var showAccounts = false
    @State private var showSetup = false
    @State private var reviewAfterSettings = false
    @State private var pendingRoute: SetupRoute?
    @State private var openedInitialRoute = false
    @State private var showCloudPreview = false
    @State private var showBatchPreview = false
    @State private var showSurfacePreview = false
    private var surfacePreview: String? {
        #if DEBUG
        return ["widgets", "widgets-overview", "widgets-accessories", "watch", "watch-stale", "accessibility",
                "purchases", "purchases-unavailable", "purchases-pending", "purchases-error"].first {
            ProcessInfo.processInfo.arguments.contains("--\($0)-preview")
        }
        #else
        return nil
        #endif
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.demo || model.snapshot?.demo == true {
                        Text(setupText("DEMO · sample data, not your account"))
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                    if model.cloud.session == nil && !model.demo &&
                        (model.snapshot == nil || !["Pair your HTTPS bridge or explore demo data.",
                            "Updated · bridge may serve a cached reading."].contains(model.status)) {
                        Text(DockL10n.text(DockL10n.text(model.status, table: "Setup")))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if model.cloud.session != nil && !model.demo {
                        CloudReadingsView(model: model.cloud)
                    } else if let snapshot = model.snapshot {
                        ForEach(snapshot.providers) { ProviderCard(provider: $0, demo: snapshot.demo) }
                    } else {
                        ContentUnavailableView(setupText("No readings yet"), systemImage: "chart.bar", description: Text(setupText("Pair a bridge to see remaining allowances.")))
                    }
                    DisclosureGroup {
                        Text(setupText("Bars show remaining allowance, never a sum. Reset times are informational. Widgets update when the OS allows; Watch uses the last iPhone transfer."))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Text(DockL10n.text("About these readings")).font(.subheadline)
                    }
                    Button(setupText(model.demo ? "Leave demo" : "Explore demo")) {
                        model.demo.toggle()
                        model.snapshot = model.demo ? .preview : SnapshotStore.load()
                        if !model.demo && settings.foregroundAutoRefresh { Task { await model.refresh(automatic: true) } }
                    }
                }
                .padding(20)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }.background(DockTheme.background)
                .navigationTitle(DockL10n.text("Allowmark"))
                .navigationBarTitleDisplayMode(.large)
                .refreshable { await model.refresh() }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(DockL10n.text("Accounts"), systemImage: "person.crop.circle") { showAccounts = true }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(setupText("Refresh"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                            .disabled(model.busy || model.demo)
                        Menu {
                            Button(setupText("Pair"), systemImage: "link") { showPairing = true }
                            NavigationLink(setupText("Optional cloud account")) { CloudView(model: model.cloud) }
                        } label: {
                            Label(DockL10n.text("Connections"), systemImage: "link")
                        }
                        Button(setupText("Settings"), systemImage: "gearshape") { showSettings = true }
                    }
                }
                .sheet(isPresented: $showPairing) { PairingView(model: model) }
                .sheet(isPresented: $showAccounts, onDismiss: { requestedAccountID = nil }) {
                    CloudAccountsView(model: model.cloud, requestedAccountID: requestedAccountID)
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showSettings, onDismiss: {
                    if reviewAfterSettings { reviewAfterSettings = false; showSetup = true }
                }) {
                    SettingsView(settings: settings, cloud: model.cloud) { reviewAfterSettings = true; showSettings = false }
                }
                .fullScreenCover(isPresented: $showSetup, onDismiss: {
                    if let route = pendingRoute { pendingRoute = nil; open(route) }
                }) {
                    FirstRunView(settings: settings, revisit: true, finish: { route in
                        pendingRoute = route; showSetup = false
                    }, cancel: { showSetup = false })
                }
                .sheet(isPresented: $showCloudPreview) { NavigationStack { CloudView(model: model.cloud) } }
                .sheet(isPresented: $showBatchPreview) {
                    #if DEBUG
                    CloudBatchPreview()
                    #endif
                }
                .fullScreenCover(isPresented: $showSurfacePreview) {
                    #if DEBUG
                    switch surfacePreview ?? "widgets" {
                    case "accessibility": QuotaAccessibilityPreview()
                    case "watch", "watch-stale": WatchSurfacePreview()
                    case "purchases", "purchases-unavailable", "purchases-pending", "purchases-error":
                        SubscriptionsPreview(state: surfacePreview ?? "purchases")
                    default: WidgetSurfacePreview()
                    }
                    #endif
                }
                .onAppear {
                    #if DEBUG
                    showSettings = ProcessInfo.processInfo.arguments.contains("--settings-preview")
                    showCloudPreview = ProcessInfo.processInfo.arguments.contains("--cloud-preview") ||
                        ProcessInfo.processInfo.arguments.contains("--cloud-expired-preview") ||
                        ProcessInfo.processInfo.arguments.contains("--cloud-erasing-preview")
                    showBatchPreview = ProcessInfo.processInfo.arguments.contains("--batch-preview")
                    showSurfacePreview = surfacePreview != nil
                    #endif
                    if !openedInitialRoute {
                        openedInitialRoute = true
                        if requestedAccountID != nil { showAccounts = true }
                        else { open(initialRoute) }
                    }
                }
                .onChange(of: requestedAccountID) { _, id in
                    if id != nil { showAccounts = true }
                }
        }
    }

    private func open(_ route: SetupRoute) {
        switch route {
        case .demo: model.demo = true; model.snapshot = .preview
        case .bridge: showPairing = true
        case .cloud: showCloudPreview = true
        case .later: break
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: InterfaceSettings
    @ObservedObject var cloud: CloudModel
    let reviewSetup: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(setupText("Language")) { InterfaceLanguagePicker(settings: settings) }
                Section {
                    NavigationLink(DockL10n.text("Plans")) { PlansView(model: cloud) }
                }
                Section {
                    Button(setupText("Review setup"), action: reviewSetup)
                } footer: {
                    Text(setupText("Review connection choices and widget guidance without deleting your account or saved readings."))
                }
                Section {
                    Toggle(setupText("Refresh when I open the app"), isOn: Binding(
                        get: { settings.foregroundAutoRefresh }, set: { settings.chooseForegroundRefresh($0) }))
                } footer: {
                    Text(setupText("When off, use the refresh button or pull to refresh. Connection failures retain the last observation and its time."))
                }
                Section {
                    DisclosureGroup(setupText("Widgets and Watch")) {
                        Text(setupText("Widgets read only the last saved observations, without connecting to the server or AI accounts. The OS decides when they update."))
                        Text(setupText("Watch shows the last observations transferred from iPhone."))
                    }
                    DisclosureGroup(setupText("Cloud auto collection")) {
                        Text(setupText("Your local collector must be online. The server checks whether 2 hours (Free), 1 hour (Plus) or your selected 20, 30, 60 or 120 minutes (Pro) have passed. Turn off auto collection in the cloud screen."))
                        Text(setupText("A collection interval does not guarantee iOS background execution or widget refreshes."))
                    }
                    DisclosureGroup("Codex") {
                        Text(setupText("Free plan support varies by environment and rollout. Unavailable measurements mean Unknown, not exhausted allowance or confirmed ineligibility."))
                    }
                }
            }
                .scrollContentBackground(.hidden)
                .background(DockTheme.background)
                .navigationTitle(setupText("Settings"))
                .toolbar { Button(setupText("Done")) { dismiss() } }
        }
    }
}

struct PairingView: View {
    @ObservedObject var model: DockModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(setupText("HTTPS bridge base URL")) {
                    TextField("https://bridge.example.com", text: $url)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    SecureField(setupText("Pairing token"), text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Text(setupText("Use a trusted HTTPS bridge without cloud. Token stays in this device’s Keychain. Widgets read only sanitized cache. Never enter provider credentials. Saving switches away from cloud and clears readings."))
                if let error { Text(DockL10n.text(setupText(error))).foregroundStyle(.orange) }
                Button(setupText("Save pairing")) {
                    do {
                        try PairingStore.save(Pairing(baseURL: url.trimmingCharacters(in: .whitespacesAndNewlines), token: token))
                        let old = model.cloud.session
                        model.cloud.resetMemory()
                        model.clearReadings()
                        let cloudRevision = model.cloud.revision
                        let pairingRevision = model.pairingRevision
                        if let old {
                            Task {
                                do { try await CloudClient.revoke(old) }
                                catch {
                                    guard model.cloud.revision == cloudRevision,
                                          model.pairingRevision == pairingRevision else { return }
                                    model.status = "Pair bridge saved; previous cloud logout unconfirmed. Its login family may remain valid for up to 30 days."
                                }
                            }
                        }
                        token = ""
                        dismiss()
                        Task { await model.refresh() }
                    } catch {
                        if SnapshotStore.blocked { model.cloud.resetMemory(); model.clearReadings() }
                        self.error = "Could not save. Use a valid HTTPS URL and token; check signing entitlements."
                    }
                }
                Button(setupText("Forget pairing"), role: .destructive) {
                    do {
                        let selected = try? ConnectionStore.current()
                        if selected?.mode == .cloud, let credential = selected?.credential {
                            model.cloud.connectionGeneration = try ConnectionStore.select(.cloud, credential: credential)
                        } else { try ConnectionStore.select(.signedOut) }
                        model.clearReadings()
                        model.status = ConnectionStore.cleanupComplete
                            ? "Pairing removed. Offline Watch/widgets may retain rendered content until next transfer."
                            : "Disconnected. Inactive local data cleanup is incomplete; old credentials cannot be selected."
                        dismiss()
                    } catch {
                        model.cloud.resetMemory(); model.clearReadings()
                        self.error = "Connection blocked. Persistent disconnection could not be confirmed; unlock the phone and reconnect."
                    }
                }
            }.navigationTitle(setupText("Pair bridge"))
                .toolbar { Button(setupText("Cancel")) { token = ""; dismiss() } }
        }
    }
}

#Preview { DockView(model: { let model = DockModel(); model.demo = true; model.snapshot = .preview; return model }(), settings: InterfaceSettings(), requestedAccountID: .constant(nil)) }
