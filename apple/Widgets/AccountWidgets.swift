import SwiftUI
import WidgetKit
import AppIntents

@available(iOS 17.0, watchOS 10.0, *)
struct SurfaceAccountEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Quota account"
    static var defaultQuery = SurfaceAccountQuery()
    let id: String
    let provider: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(provider) · \(String(id.prefix(8)).uppercased())", subtitle: "\(id)")
    }
    init(_ account: AccountSurfaceSnapshot.Account) {
        id = account.id.uuidString.lowercased(); provider = account.provider.displayName
    }
}

@available(iOS 17.0, watchOS 10.0, *)
struct SurfaceAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [SurfaceAccountEntity] {
        let wanted = Set(identifiers.compactMap(UUID.init(uuidString:)))
        return (SnapshotStore.loadAccounts()?.accounts ?? []).filter { wanted.contains($0.id) }.map(SurfaceAccountEntity.init)
    }
    func suggestedEntities() async throws -> [SurfaceAccountEntity] {
        (SnapshotStore.loadAccounts()?.accounts ?? []).map(SurfaceAccountEntity.init)
    }
}

@available(iOS 17.0, watchOS 10.0, *)
enum SurfaceWindow: String, AppEnum {
    case primary, secondary, tertiary, weekly, pro
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Quota window"
    static var caseDisplayRepresentations: [SurfaceWindow: DisplayRepresentation] = [
        .primary: "Primary", .secondary: "Secondary", .tertiary: "Tertiary", .weekly: "Weekly", .pro: "Pro"
    ]
}

@available(iOS 17.0, watchOS 10.0, *)
struct AccountWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Selected quota account"
    static var description = IntentDescription("Choose fixed account IDs and quota windows. Missing selections stay unavailable.")
    @Parameter(title: "Account") var account: SurfaceAccountEntity?
    @Parameter(title: "Window", default: .primary) var window: SurfaceWindow
    @Parameter(title: "Comparison account") var comparison: SurfaceAccountEntity?
    @Parameter(title: "Comparison window", default: .primary) var comparisonWindow: SurfaceWindow
}

@available(iOS 17.0, watchOS 10.0, *)
struct AccountQuotaEntry: TimelineEntry {
    let date: Date
    let configuration: AccountWidgetIntent
    let snapshot: AccountSurfaceSnapshot?
}

@available(iOS 17.0, watchOS 10.0, *)
struct AccountQuotaTimeline: AppIntentTimelineProvider {
    func recommendations() -> [AppIntentRecommendation<AccountWidgetIntent>] {
        (SnapshotStore.loadAccounts()?.accounts ?? []).map { account in
            let intent = AccountWidgetIntent()
            intent.account = SurfaceAccountEntity(account)
            return AppIntentRecommendation(intent: intent,
                description: Text(verbatim: "\(account.provider.displayName) · \(String(account.id.uuidString.prefix(8)))"))
        }
    }
    func placeholder(in context: Context) -> AccountQuotaEntry {
        AccountQuotaEntry(date: Date(), configuration: AccountWidgetIntent(), snapshot: nil)
    }
    func snapshot(for configuration: AccountWidgetIntent, in context: Context) async -> AccountQuotaEntry {
        AccountQuotaEntry(date: Date(), configuration: configuration, snapshot: SnapshotStore.loadAccounts())
    }
    func timeline(for configuration: AccountWidgetIntent, in context: Context) async -> Timeline<AccountQuotaEntry> {
        let entry = await snapshot(for: configuration, in: context)
        return Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
    }
}

@available(iOS 17.0, watchOS 10.0, *)
private struct AccountQuotaView: View {
    let entry: AccountQuotaEntry
    @Environment(\.widgetFamily) private var family
    private var surface: WidgetSurface {
        switch family {
        case .accessoryInline: return .inline
        case .accessoryCircular: return .circular
        case .accessoryRectangular: return .rectangular
        #if os(iOS)
        case .systemMedium: return .medium
        #endif
        default: return .small
        }
    }
    var body: some View {
        Group {
            #if os(iOS)
            if family == .systemMedium {
                VStack(alignment: .leading, spacing: 8) {
                    content(entry.configuration.account, window: entry.configuration.window)
                    Divider()
                    content(entry.configuration.comparison, window: entry.configuration.comparisonWindow)
                }
            } else {
                content(entry.configuration.account, window: entry.configuration.window)
            }
            #else
            content(entry.configuration.account, window: entry.configuration.window)
            #endif
        }
        .widgetURL(entry.configuration.account.flatMap { UUID(uuidString: $0.id) }.map(AccountSurfaceSnapshot.deepLink))
        .containerBackground(DockTheme.surface, for: .widget)
    }
    @ViewBuilder private func content(_ account: SurfaceAccountEntity?, window: SurfaceWindow) -> some View {
        let id = account.flatMap { UUID(uuidString: $0.id) }
        let view = AccountSurfaceContent(snapshot: entry.snapshot, accountID: id,
            windowID: window.rawValue, date: entry.date, surface: surface)
        #if os(iOS)
        if family == .systemMedium, let id {
            Link(destination: AccountSurfaceSnapshot.deepLink(id)) { view }.frame(maxWidth: .infinity, alignment: .leading)
        } else { view.frame(maxWidth: .infinity, alignment: .leading) }
        #else
        view
        #endif
    }
}

@available(iOS 17.0, watchOS 10.0, *)
struct AccountQuotaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "QuotaDock.selectedAccount", intent: AccountWidgetIntent.self,
                               provider: AccountQuotaTimeline()) { AccountQuotaView(entry: $0) }
            .configurationDisplayName("Selected account quota")
            .description("Cached quota for fixed account IDs. Medium compares two selections.")
            #if os(iOS)
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular, .accessoryInline])
            #else
            .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
            #endif
    }
}
