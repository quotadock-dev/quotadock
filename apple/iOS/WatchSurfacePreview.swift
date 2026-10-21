#if DEBUG
import SwiftUI

// Host routing is wired by the iOS app; uses the same content as the Watch.
struct WatchSurfacePreview: View {
    @State private var demo = false
    @State private var snapshot: Snapshot?

    var body: some View {
        VStack(spacing: 12) {
            Text("DEMO · shared Watch content in an iPhone host, not a physical Watch")
                .font(.caption).padding()
        WatchContent(snapshot: snapshot, savedAt: nil, demo: demo, toggleDemo: {
            demo.toggle()
            snapshot = demo ? .preview : nil
        }, reloadCache: { snapshot = nil })
        .frame(maxWidth: 220, maxHeight: 360)
        }.onAppear {
            if ProcessInfo.processInfo.arguments.contains("--watch-stale-preview") {
                let preview = Snapshot.preview
                snapshot = Snapshot(schemaVersion: 1, generatedAt: preview.generatedAt.addingTimeInterval(-3600), demo: true,
                    providers: preview.providers.map { provider in
                        Provider(id: provider.id, name: provider.name, plan: provider.plan,
                            state: provider.state, source: .demo, message: nil,
                            observedAt: provider.observedAt?.addingTimeInterval(-3600), windows: provider.windows)
                    })
                demo = true
            }
        }
    }
}
#endif
