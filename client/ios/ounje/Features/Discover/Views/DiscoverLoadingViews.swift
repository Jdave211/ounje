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

enum PullStretchRefreshPhase: Equatable {
    case hint
    case pulling
    case release
    case refreshing
    case complete
}

struct PullStretchRefreshOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct PullStretchRefreshIndicator: View {
    let phase: PullStretchRefreshPhase
    var pullDistance: CGFloat = 0
    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pullProgress: CGFloat {
        min(max(pullDistance / 62, 0), 1)
    }

    private var title: String {
        switch phase {
        case .hint:
            return "Pull to refresh"
        case .pulling:
            return "Keep pulling"
        case .release:
            return "Release to refresh"
        case .refreshing:
            return "Refreshing"
        case .complete:
            return "Fresh recipes ready"
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            if phase == .refreshing {
                DiscoverRiveLoader(size: 18)
            } else if phase == .complete {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .bold))
                    .rotationEffect(.degrees(phase == .release ? 180 : 0))
                    .offset(y: reduceMotion ? 0 : (isAnimating ? 3 : -2))
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .foregroundStyle(OunjePalette.softCream.opacity(phase == .refreshing ? 0.95 : 0.76))
        .padding(.vertical, 4)
        .scaleEffect(
            x: reduceMotion ? 1 : 1 + (pullProgress * 0.06),
            y: reduceMotion ? 1 : 1 + (pullProgress * 0.16),
            anchor: .center
        )
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: phase)
        .animation(.spring(response: 0.24, dampingFraction: 0.78), value: pullProgress)
        .accessibilityLabel(phase == .refreshing ? "Refreshing Discover recipes" : "Pull down to refresh Discover recipes")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}
