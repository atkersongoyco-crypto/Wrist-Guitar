import SwiftUI

extension View {
    func sessionGlass(in shape: some Shape) -> some View {
        modifier(ArtworkControlGlass(shape: shape))
    }
}

private struct ArtworkControlGlass<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(scheme == .dark ? Color(white: 0.19) : Color(white: 0.96), in: shape)
        } else if #available(iOS 26, watchOS 26, macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}
