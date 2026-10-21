import SwiftUI

struct SubscriptionOption: Identifiable {
    let id: String
    let name: String
    let price: String
    let tier: String
    var annual: Bool = false
}

// Presentation only: prices and purchase eligibility are supplied by StoreKit.
// The isolated preview can use this view without creating a purchase client.
struct SubscriptionPanel: View {
    @Environment(\.locale) private var locale
    @State private var annual = false
    let available: Bool
    let busy: Bool
    let status: String
    let options: [SubscriptionOption]
    var currentTier: String? = nil
    let load: () -> Void
    let purchase: (String) -> Void
    let restore: () -> Void

    var body: some View {
        let _ = locale
        if available {
            Text(DockL10n.text(status)).font(.callout)
                .accessibilityLabel(DockL10n.format("Subscription status: %@", DockL10n.text(status)))
        }
        if !options.isEmpty {
            Picker(DockL10n.text("Billing period"), selection: $annual) {
                Text(DockL10n.text("Monthly")).tag(false)
                Text(DockL10n.text("Annual")).tag(true)
            }.pickerStyle(.segmented)
        }
        ForEach(["free", "plus", "pro"], id: \.self) { tier in
            Section {
                let current = currentTier == tier
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(tier == "free" ? DockL10n.text("Free") : "\(DockL10n.text("Allowmark")) \(tier.capitalized)").font(.title3.bold())
                        Spacer()
                        if current {
                            Text(DockL10n.text("Current plan"))
                                .font(.caption.weight(.semibold)).foregroundStyle(DockTheme.mint)
                        }
                    }
                    Text(DockL10n.text(tier == "free" ? "3 accounts" : tier == "plus" ? "10 accounts" : "25 accounts"))
                        .font(.headline)
                    Text(DockL10n.text(tier == "free" ? "1 collector computer" : tier == "plus" ? "3 collector computers" : "5 collector computers"))
                        .font(.subheadline).foregroundStyle(.secondary)
                    if tier == "free" {
                        Text(DockL10n.text("Free")).font(.title2.bold())
                    } else if options.filter({ $0.tier == tier && $0.annual == annual }).isEmpty {
                        Text(DockL10n.text("Price unavailable")).foregroundStyle(.secondary)
                    } else {
                        ForEach(options.filter { $0.tier == tier && $0.annual == annual }) { option in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(DockL10n.format(option.annual ? "%@ / year" : "%@ / month", option.price))
                                    .font(.title2.weight(.semibold))
                                Text(DockL10n.text(option.annual ?
                                    "Charged at purchase. Automatically renews annually." :
                                    "Charged at purchase. Automatically renews monthly."))
                                    .font(.subheadline)
                                if available {
                                    Button { purchase(option.id) } label: {
                                        Text(DockL10n.text(current ? "Review with Apple" : "Subscribe"))
                                            .frame(maxWidth: .infinity, minHeight: 32)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(busy)
                                    .accessibilityIdentifier("subscribe-\(tier)-\(option.annual ? "annual" : "monthly")")
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DockTheme.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).stroke(DockTheme.border, lineWidth: 1) }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowBackground(Color.clear)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("plan-\(tier)")
            }
        }
        Section {
            Text(DockL10n.text("Fresh readings require an online local collector. AI provider subscriptions are separate."))
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        if available && options.isEmpty {
            Button(DockL10n.text("Reload products"), action: load).disabled(busy)
        }
        if busy { ProgressView(DockL10n.text("Processing…")) }
        Section {
            DisclosureGroup(DockL10n.text("Purchase details and terms")) {
                if !available {
                    Text(DockL10n.text(status)).font(.callout)
                        .accessibilityLabel(DockL10n.format("Subscription status: %@", DockL10n.text(status)))
                }
                Text(DockL10n.text("Subscriptions are charged to your Apple account and automatically renew. Cancel in Apple subscription settings before the next renewal. Deleting your cloud account does not cancel your Apple subscription."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(DockL10n.text("Reload products"), action: load).disabled(!available || busy)
                Link(DockL10n.text("Manage Apple subscriptions"), destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                Link(DockL10n.text("Privacy and data"), destination: URL(string: "https://usage.mvtp.cloud/#privacy")!)
                Link(DockL10n.text("Standard terms (Apple EULA)"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
            }
            Button(DockL10n.text("Restore purchases"), action: restore).disabled(!available || busy)
        }
    }
}
