#if DEBUG
import SwiftUI

// Isolated fixtures: no DockModel, account, network, or persistent stores.
struct QuotaAccessibilityPreview: View {
    private let observed = Date(timeIntervalSince1970: 1_800_000_000)

    private var providers: [Provider] {
        [
            Provider(id: .claude, name: "Claude", plan: "Max · extended model allowance",
                     state: .available, source: .demo, message: nil, observedAt: Date(), windows: [
                QuotaWindow(id: "zero", label: "Claude extended thinking model · weekly allowance with a very long model label",
                            remainingPercent: 0, resetsAt: observed.addingTimeInterval(86400)),
                QuotaWindow(id: "fraction", label: "Session · fractional remaining allowance",
                            remainingPercent: 0.75, resetsAt: nil),
                QuotaWindow(id: "tiny", label: "Small positive allowance", remainingPercent: 0.001, resetsAt: nil),
                QuotaWindow(id: "unknown", label: "Additional model · allowance not measured",
                            remainingPercent: nil, resetsAt: nil)
            ]),
            Provider(id: .codex, name: "Codex", plan: "ChatGPT Plus", state: .available,
                     source: .demo, message: nil, observedAt: Date().addingTimeInterval(-3600), windows: [
                QuotaWindow(id: "stale", label: "Weekly · last observed allowance", remainingPercent: 43.25, resetsAt: nil)
            ]),
            // The numeric payload must be masked by Provider.displayWindows.
            Provider(id: .gemini, name: "Gemini", plan: nil, state: .error,
                     source: .demo, message: nil, observedAt: nil, windows: [
                QuotaWindow(id: "error", label: "Pro model · failed reading (remaining unknown)",
                            remainingPercent: 88, resetsAt: nil)
            ]),
            Provider(id: .grok, name: "Grok", plan: nil, state: .unavailable,
                     source: .demo, message: nil, observedAt: nil, windows: [])
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("DEMO · accessibility samples, not your account")
                        .font(.headline).foregroundStyle(DockTheme.mint)
                    ForEach(providers) { ProviderCard(provider: $0, demo: true) }
                }.padding()
            }
            .background(DockTheme.background)
            .navigationTitle("Quota accessibility")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(DockTheme.mint)
        .dynamicTypeSize(.accessibility3)
    }
}

#Preview("Quota accessibility · large text") {
    QuotaAccessibilityPreview()
}
#endif
