#if DEBUG && os(iOS)
import SwiftUI

// Host-only gallery: no cache writes, pairing, credentials or refresh requests.
struct WidgetSurfacePreview: View {
    private let snapshot = Snapshot.preview

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Widget surfaces").font(.largeTitle.bold())
                Text("Sample cached data · actual shared widget content. Host frames approximate WidgetKit sizes; verify on device.")
                    .font(.caption).foregroundStyle(.secondary)
                if ProcessInfo.processInfo.arguments.contains("--widgets-overview-preview") {
                    Text("Overview · medium").font(.headline)
                    OverviewWidgetContent(snapshot: snapshot, date: snapshot.generatedAt, surface: .medium)
                        .padding(12).frame(width: 330, height: 160).background(DockTheme.background)
                    Text("Overview · large / stale").font(.headline)
                    OverviewWidgetContent(snapshot: snapshot, date: snapshot.generatedAt.addingTimeInterval(3600), surface: .large)
                        .padding(16).frame(width: 330, height: 340).background(DockTheme.background)
                } else if ProcessInfo.processInfo.arguments.contains("--widgets-accessories-preview") {
                    provider("Rectangular · stale", id: .codex, surface: .rectangular, width: 160, height: 64, stale: true)
                    HStack {
                        provider("Known", id: .claude, surface: .circular, width: 64, height: 64)
                        provider("Unknown", id: .gemini, surface: .circular, width: 64, height: 64)
                    }
                    provider("Inline", id: .codex, surface: .inline, width: 330, height: 30)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        provider("Known · small", id: .claude, surface: .small, width: 160, height: 160)
                        provider("Unknown · small", id: .gemini, surface: .small, width: 160, height: 160)
                    }
                    provider("Stale · medium", id: .claude, surface: .medium, width: 330, height: 160, stale: true)
                    Text("No cache").font(.headline)
                    ProviderWidgetContent(snapshot: nil, providerID: .grok, date: snapshot.generatedAt, surface: .small)
                        .padding(12).frame(width: 160, height: 160).background(DockTheme.background, in: RoundedRectangle(cornerRadius: 20))
                }
            }.padding()
        }
    }

    private func provider(_ title: String, id: ProviderID, surface: WidgetSurface,
                          width: CGFloat, height: CGFloat, stale: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ProviderWidgetContent(snapshot: snapshot, providerID: id,
                                  date: snapshot.generatedAt.addingTimeInterval(stale ? 3600 : 0), surface: surface)
                .padding(surface == .small || surface == .medium ? 12 : 2)
                .frame(width: width, height: height)
                .background(DockTheme.background, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
#endif
