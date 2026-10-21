import SwiftUI

struct ProviderIcon: View {
    let id: ProviderID
    var size: CGFloat = 22
    var body: some View {
        Image(id.rawValue).renderingMode(.template).resizable()
            .scaledToFit().frame(width: size, height: size)
            .foregroundStyle(.primary).accessibilityHidden(true)
    }
}
