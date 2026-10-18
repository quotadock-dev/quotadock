import SwiftUI

@main
struct QuotaDockWatchApp: App {
    var body: some Scene { WindowGroup { NavigationStack { WatchDashboard() } } }
}

struct WatchDashboard: View {
    @State private var snapshot = SnapshotStore.load()
    @State private var accounts = SnapshotStore.loadAccounts()
    @State private var accountAuthority = SnapshotStore.accountInbox?.hasAuthority == true
    @State private var savedAt = SnapshotStore.savedAt
    @State private var locale = DockL10n.locale
    @State private var demo = false
    var body: some View {
        Group {
            if accountAuthority && (accounts != nil || SnapshotStore.accountInbox?.loadLegacy() == nil) {
                AccountWatchContent(snapshot: accounts, savedAt: savedAt, reloadCache: reload,
                                    trustCompanion: { WatchSync.shared.trustCurrentCompanion() })
            } else {
                WatchContent(snapshot: snapshot, savedAt: savedAt, demo: demo, toggleDemo: {
                    demo.toggle()
                    if demo { snapshot = .preview } else { reload() }
                }, reloadCache: { if !demo { reload() } },
                trustCompanion: { WatchSync.shared.trustCurrentCompanion() })
            }
        }
            .environment(\.locale, locale)
            .task { WatchSync.shared.start() }
            .onReceive(NotificationCenter.default.publisher(for: .snapshotUpdated).receive(on: RunLoop.main)) { _ in
                locale = DockL10n.locale
                if !demo || SnapshotStore.accountInbox?.hasAuthority == true { demo = false; reload() }
            }
    }

    private func reload() {
        snapshot = SnapshotStore.load()
        accounts = SnapshotStore.loadAccounts()
        accountAuthority = SnapshotStore.accountInbox?.hasAuthority == true
        savedAt = SnapshotStore.savedAt
    }
}
