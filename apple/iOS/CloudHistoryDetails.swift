import SwiftUI

// Presentation only: the isolated preview can render it without credentials,
// CloudModel, a network client, purchases, widgets or a Watch session.
struct CloudHistoryDetails: View {
    @Environment(\.locale) private var locale
    let observations: [CloudHistoryObservation]
    var body: some View {
        ForEach(observations) { point in
            Section(DockL10n.date(point.observedDate)) {
                Text(locale.identifier.hasPrefix("ko") ? "과거 원본 측정값" : "Historical source measurement").font(.caption)
                ProviderCard(provider: point.reading, demo: false)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowBackground(Color.clear)
                Text(verbatim: point.observedAt).font(.caption).textSelection(.enabled)
            }
        }
    }
}
