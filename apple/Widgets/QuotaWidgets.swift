import SwiftUI
import WidgetKit

struct QuotaEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?
    var cached = false
}

struct QuotaTimeline: TimelineProvider {
    func placeholder(in context: Context) -> QuotaEntry { QuotaEntry(date: Date(), snapshot: .preview) }
    func getSnapshot(in context: Context, completion: @escaping (QuotaEntry) -> Void) {
        completion(QuotaEntry(date: Date(), snapshot: context.isPreview ? .preview : SnapshotStore.load(), cached: !context.isPreview))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuotaEntry>) -> Void) {
        let entry = QuotaEntry(date: Date(), snapshot: SnapshotStore.load(), cached: true)
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60))))
    }
}

private extension WidgetFamily {
    var surface: WidgetSurface {
        switch self {
        case .accessoryCircular: return .circular
        case .accessoryInline: return .inline
        case .accessoryRectangular: return .rectangular
        #if os(iOS)
        case .systemMedium: return .medium
        case .systemLarge: return .large
        #endif
        default: return .small
        }
    }
}

struct QuotaWidgetView: View {
    let entry: QuotaEntry
    let providerID: ProviderID
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ProviderWidgetContent(snapshot: entry.snapshot, providerID: providerID,
                              date: entry.date, surface: family.surface)
            .containerBackground(DockTheme.background, for: .widget)
    }
}

struct ProviderWidget: Widget {
    let providerID: ProviderID

    init() { self.init(providerID: .claude) }
    init(providerID: ProviderID) { self.providerID = providerID }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuotaDock.\(providerID.rawValue)", provider: QuotaTimeline()) { entry in
            QuotaWidgetView(entry: entry, providerID: providerID)
        }
        .configurationDisplayName(DockL10n.format("%@ remaining", providerID.displayName))
        .description(DockL10n.text("Cached first account per provider. Open QuotaDock for all accounts and windows."))
        #if os(iOS)
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
        #else
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
        #endif
    }
}

#if os(iOS)
private struct OverviewWidgetView: View {
    let entry: QuotaEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        OverviewWidgetContent(snapshot: entry.snapshot, date: entry.date, surface: family.surface)
            .containerBackground(DockTheme.background, for: .widget)
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuotaDock.overview", provider: QuotaTimeline()) { entry in
            OverviewWidgetView(entry: entry)
        }
        .configurationDisplayName(DockL10n.text("All AI allowances"))
        .description(DockL10n.text("First quota window per provider. Codex is not total ChatGPT usage. Open the app for all windows and reset times."))
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}
#endif

@main
struct QuotaWidgets: WidgetBundle {
    var body: some Widget {
        AccountQuotaWidget()
        #if os(iOS)
        OverviewWidget()
        #endif
        ProviderWidget(providerID: .claude)
        ProviderWidget(providerID: .codex)
        ProviderWidget(providerID: .gemini)
        ProviderWidget(providerID: .grok)
    }
}
