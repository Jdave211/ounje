import SwiftUI

struct DiscoverRiveLoader: View {
    var size: CGFloat = 18
    var tint: Color = OunjePalette.accent

    var body: some View {
        ProgressView()
            .tint(tint)
            .scaleEffect(0.8)
            .frame(width: size, height: size)
            .allowsHitTesting(false)
    }
}
