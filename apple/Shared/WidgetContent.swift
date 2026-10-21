import SwiftUI

// UUID selection never falls back to a different account or window.
struct AccountSurfaceContent: View {
    let snapshot: AccountSurfaceSnapshot?
    let accountID: UUID?
    let windowID: String
    let date: Date
    let surface: WidgetSurface
    private var account: AccountSurfaceSnapshot.Account? { snapshot?.account(accountID) }
    private var window: QuotaWindow? { snapshot?.window(account: accountID, windowID: windowID) }
    private var freshness: String {
        guard let reading = account?.reading, let observed = reading.observedAt else { return DockL10n.text("Not observed") }
        return DockL10n.format("%@ · %@", DockL10n.text(reading.isStale(at: date) ? "Stale" : "Observed"), DockL10n.date(observed))
    }
    private var compactFreshness: String {
        guard let reading = account?.reading, let observed = reading.observedAt else { return DockL10n.text("Not observed") }
        let timestamp = observed.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(DockL10n.locale))
        return DockL10n.format("%@ · %@", DockL10n.text(reading.isStale(at: date) ? "Stale" : "Observed"), timestamp)
    }
    private var status: String {
        DockL10n.text(account?.observedAt == nil ? "Not observed" : account?.reading.isStale(at: date) == true ? "Stale" : "Cached")
    }
    private var identifier: String { account.map { String($0.id.uuidString.prefix(8)) } ?? "—" }
    private var value: String { window.flatMap(QuotaPresentation.percent) ?? DockL10n.text("Unknown") }
    private var accessibilitySummary: String {
        let provider = account?.provider.displayName ?? DockL10n.text("Account unavailable")
        let selected = accountID.map { "account-" + $0.uuidString.lowercased() } ?? DockL10n.text("Choose account")
        let period = window.map(QuotaPresentation.window) ?? DockL10n.text("Window unavailable")
        return "\(provider). \(selected). \(period). \(freshness)"
    }

    var body: some View {
        Group {
            if surface == .inline {
                inlineContent
            } else if surface == .circular {
                circularContent
            } else {
                expandedContent
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(accessibilitySummary)
    }

    private var inlineContent: some View {
        Group {
            if let account {
                Text("\(account.provider.displayName) \(value) · \(status) · \(String(identifier.prefix(4)))")
            } else {
                Text("\(DockL10n.text("Account unavailable")) · \(DockL10n.text("Unknown"))")
            }
        }
        .font(.caption).lineLimit(1).minimumScaleFactor(0.7)
    }

    private var circularContent: some View {
        VStack(spacing: 1) {
            if let account { ProviderIcon(id: account.provider, size: 12) }
            Text(identifier).font(.system(size: 8)).lineLimit(1)
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
            Text(status).font(.system(size: 9))
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: surface == .small ? 6 : 3) {
            HStack(spacing: 5) {
                if let account { ProviderIcon(id: account.provider, size: 14) }
                Text(account?.provider.displayName ?? DockL10n.text("Account unavailable")).bold()
                Spacer(minLength: 0)
                Text(identifier).monospaced().foregroundStyle(.secondary)
            }.font(.caption2).lineLimit(1).minimumScaleFactor(0.8)
            if surface == .large {
                Text(account?.plan ?? DockL10n.text("Plan unknown")).font(.caption2).foregroundStyle(.secondary)
            }
            if surface == .small {
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.map(QuotaPresentation.window) ?? DockL10n.text("Window unavailable"))
                        .font(.caption2).fixedSize(horizontal: false, vertical: true)
                    Text(value).font(.title2.weight(.semibold)).monospacedDigit().fixedSize()
                }
            } else {
                HStack(spacing: 3) {
                    Text(window.map(QuotaPresentation.window) ?? DockL10n.text("Window unavailable"))
                        .lineLimit(surface == .rectangular ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(value).font(.caption.weight(.semibold)).monospacedDigit().fixedSize()
                }.font(surface == .rectangular ? .caption2 : .caption)
            }
            if let remaining = window?.clampedRemaining {
                QuotaTrack(remaining: remaining)
            }
            if surface == .large, let reset = window?.resetsAt {
                Text(reset <= date ? DockL10n.text("Reset passed · awaiting observation") :
                    DockL10n.format("Reset: %@", DockL10n.date(reset))).font(.system(size: 9))
            }
            Text(compactFreshness).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if surface == .large {
                Text(DockL10n.text("Cached readings · not live")).font(.system(size: 9))
            }
        }
    }
}

// Explicit layout keeps the same presentation usable outside WidgetKit.
enum WidgetSurface { case small, medium, large, rectangular, circular, inline }

struct ProviderWidgetContent: View {
    @Environment(\.locale) private var locale
    let snapshot: Snapshot?
    let providerID: ProviderID
    let date: Date
    let surface: WidgetSurface

    private var provider: Provider? { snapshot?.providers.first { $0.id == providerID } }
    private var window: QuotaWindow? { provider?.displayWindows.first }
    private var value: String { window.flatMap(QuotaPresentation.percent) ?? "?" }
    private var demo: Bool { snapshot?.demo == true || provider?.source == .demo }
    private var freshness: String {
        guard let provider, let observed = provider.observedAt else { return DockL10n.text("Not observed") }
        return DockL10n.format("%@ · %@", DockL10n.text(provider.isStale(at: date) ? "Stale" : "Observed"), DockL10n.date(observed))
    }

    var body: some View {
        let _ = locale
        Group {
            switch surface {
            case .inline:
                Text(DockL10n.format("%@%@ %@ · %@", demo ? DockL10n.text("DEMO") + " · " : "", providerID.displayName,
                    value == "?" ? DockL10n.text("Unknown") : DockL10n.format("%@ left", value),
                    DockL10n.text(provider?.observedAt == nil ? "Not observed" : provider?.isStale(at: date) == true ? "Stale" : "Cached")))
            case .circular:
                VStack(spacing: 1) {
                    if demo { Text(DockL10n.text("DEMO")).font(.system(size: 9)) }
                    else { ProviderIcon(id: providerID, size: 12) }
                    Text(value).font(.headline).monospacedDigit()
                    Text(DockL10n.text(value == "?" ? "Unknown" : provider?.isStale(at: date) == true ? "Stale" : "left")).font(.system(size: 9))
                }
            case .rectangular:
                VStack(alignment: .leading, spacing: 3) {
                    header(compact: true)
                    HStack {
                        Text(window.map(QuotaPresentation.window) ?? DockL10n.text("Remaining")).lineLimit(1)
                        Spacer(minLength: 3)
                        Text(value == "?" ? DockL10n.text("Unknown") : DockL10n.format("%@ left", value)).monospacedDigit().fixedSize()
                    }.font(.caption)
                    Text(freshness).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.8)
                }
            default:
                VStack(alignment: .leading, spacing: 4) {
                    header(compact: false)
                    Text(provider?.plan ?? DockL10n.text("Plan unknown")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let provider {
                        ForEach(Array(provider.displayWindows.prefix(surface == .medium ? 2 : 1))) { window in
                            WidgetQuotaBar(window: window)
                        }
                        if provider.windows.isEmpty { Text(DockL10n.text("Remaining unknown")).font(.caption) }
                    } else { Text(DockL10n.text("No cached quota")).font(.caption) }
                    Spacer(minLength: 0)
                    Text(freshness).font(.caption2).foregroundStyle(.secondary).lineLimit(surface == .medium ? 1 : 2)
                    Text(DockL10n.text(provider == nil ? "No stored observation" : surface == .medium ? "Cached · first account · first 2 windows" : "Cached · first account / window"))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(surface == .medium ? 1 : 2).minimumScaleFactor(0.85)
                    if providerID == .codex && surface == .medium {
                        Text(DockL10n.text("Not total ChatGPT usage")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(DockL10n.format("First cached account; compact widgets show the first window. %@. Open QuotaDock for all accounts. Codex is not total ChatGPT usage.", freshness))
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: 5) {
            ProviderIcon(id: providerID, size: compact ? 14 : 18)
            Text(providerID.displayName).font(compact ? .caption : .headline).lineLimit(1)
            Spacer(minLength: 0)
            if demo { Text(DockL10n.text("DEMO")).font(.caption2).fixedSize() }
        }
    }
}

struct WidgetQuotaBar: View {
    @Environment(\.locale) private var locale
    let window: QuotaWindow
    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(QuotaPresentation.window(window)).lineLimit(1)
                Spacer(minLength: 0)
                Text(QuotaPresentation.percent(window).map { DockL10n.format("%@ left", $0) } ?? DockL10n.text("Unknown"))
                    .monospacedDigit().fixedSize()
            }.font(.caption)
            if let remaining = window.clampedRemaining {
                QuotaTrack(remaining: remaining)
            }
        }
    }
}

struct OverviewWidgetContent: View {
    @Environment(\.locale) private var locale
    let snapshot: Snapshot?
    let date: Date
    let surface: WidgetSurface

    var body: some View {
        let _ = locale
        VStack(alignment: .leading, spacing: surface == .large ? 12 : 5) {
            HStack {
                Text(DockL10n.text("QuotaDock · remaining")).font(.caption).bold()
                Spacer(minLength: 2)
                if snapshot?.demo == true { Text(DockL10n.text("DEMO")).font(.caption2) }
            }
            ForEach([ProviderID.claude, .codex, .gemini, .grok], id: \.rawValue) { id in
                let provider = snapshot?.providers.first { $0.id == id }
                let window = provider?.displayWindows.first
                HStack(spacing: 7) {
                    ProviderIcon(id: id, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(id.displayName).bold().fixedSize()
                            Text(DockL10n.text(provider?.observedAt == nil ? "Not observed" : provider?.isStale(at: date) == true ? "Stale" : "Cached"))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }.font(.caption2)
                        if let remaining = window?.clampedRemaining {
                            QuotaTrack(remaining: remaining)
                        }
                        if surface == .large {
                            Text(provider?.observedAt.map { DockL10n.format("Observed %@", DockL10n.date($0)) } ?? DockL10n.text("No observation"))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(window.flatMap(QuotaPresentation.percent) ?? DockL10n.text("Unknown"))
                        .font(.caption2).monospacedDigit().fixedSize()
                }.accessibilityElement(children: .combine)
            }
            Text(DockL10n.text("Cached · first account / window per provider")).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            if surface == .large {
                Text(DockL10n.text("Codex is not total ChatGPT usage. Open QuotaDock for all accounts and windows.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
