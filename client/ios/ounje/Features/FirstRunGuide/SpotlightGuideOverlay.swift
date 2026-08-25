import SwiftUI
import UIKit

private struct FirstRunGuideTargetPreferenceKey: PreferenceKey {
    static var defaultValue: [FirstRunGuideTargetID: CGRect] = [:]

    static func reduce(
        value: inout [FirstRunGuideTargetID: CGRect],
        nextValue: () -> [FirstRunGuideTargetID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct FirstRunGuideResolvedTarget: Identifiable {
    let id: FirstRunGuideTargetID
    let globalFrame: CGRect
}

extension View {
    func firstRunGuideTarget(_ id: FirstRunGuideTargetID?, enabled: Bool = true) -> some View {
        background {
            GeometryReader { proxy in
                if enabled, let id {
                    Color.clear.preference(
                        key: FirstRunGuideTargetPreferenceKey.self,
                        value: [id: proxy.frame(in: .global)]
                    )
                }
            }
        }
    }

    func firstRunGuideHost() -> some View {
        modifier(FirstRunGuideHostModifier())
    }
}

private struct FirstRunGuideHostModifier: ViewModifier {
    @EnvironmentObject private var guide: FirstRunGuideCoordinator

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(FirstRunGuideTargetPreferenceKey.self) { targets in
            let resolvedTargets = guide.currentTargets.compactMap { targetID in
                targets[targetID].map {
                    FirstRunGuideResolvedTarget(id: targetID, globalFrame: $0)
                }
            }

            if guide.isActive, !resolvedTargets.isEmpty {
                FirstRunGuideSpotlightOverlay(
                    targets: resolvedTargets,
                    message: guide.coachmark,
                    showsAdvance: guide.showsCoachmarkAdvance,
                    showsSaveCelebration: guide.phase == .recipeCommunity,
                    onAdvance: guide.advanceCoachmark,
                    onDismiss: guide.dismiss
                )
                .transition(.opacity)
                .zIndex(100)
            }
        }
    }
}

private struct FirstRunGuideSpotlightOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let targets: [FirstRunGuideResolvedTarget]
    let message: String
    let showsAdvance: Bool
    let showsSaveCelebration: Bool
    let onAdvance: () -> Void
    let onDismiss: () -> Void
    @State private var outlineOpacity = 0.72
    @State private var isFrameStable = false

    var body: some View {
        GeometryReader { proxy in
            let spotlightTargets = resolvedSpotlightTargets(in: proxy)
            let focusFrame = unionFrame(of: spotlightTargets.map(\.globalFrame))

            ZStack(alignment: .topLeading) {
                spotlightPath(
                    in: proxy.size,
                    targets: spotlightTargets
                )
                    .fill(Color.black.opacity(0.66), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                ForEach(spotlightTargets) { target in
                    let targetFrame = target.globalFrame
                    RoundedRectangle(
                        cornerRadius: cornerRadius(for: target.id, targetFrame: targetFrame),
                        style: .continuous
                    )
                        .stroke(Color.white.opacity(outlineOpacity), lineWidth: 2.5)
                        .frame(width: targetFrame.width, height: targetFrame.height)
                        .position(x: targetFrame.midX, y: targetFrame.midY)
                        .shadow(color: Color.white.opacity(0.24), radius: 9)
                        .allowsHitTesting(false)
                }

                if showsSaveCelebration,
                   let savedTarget = spotlightTargets.first(where: { $0.id == .recipeCommunity }) {
                    FirstRunGuideConfettiBurst(origin: CGPoint(x: savedTarget.globalFrame.midX, y: savedTarget.globalFrame.midY))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if showsAdvance {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onAdvance)
                        .accessibilityLabel("Next")
                        .accessibilityAddTraits(.isButton)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(1)
                } else {
                    FirstRunGuideTouchShield(cutouts: spotlightTargets.map(\.globalFrame))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .zIndex(1)
                }

                coachmark(availableSize: proxy.size, focusFrame: focusFrame)
                    .allowsHitTesting(!showsAdvance)
                    .zIndex(2)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .opacity(isFrameStable ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: isFrameStable)
        .allowsHitTesting(isFrameStable)
        .accessibilityElement(children: .contain)
        .task(id: frameStabilityKey) {
            isFrameStable = false
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            isFrameStable = true
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                outlineOpacity = 1
            }
        }
    }

    private var frameStabilityKey: String {
        targets
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .flatMap { target in
                [target.globalFrame.minX, target.globalFrame.minY, target.globalFrame.width, target.globalFrame.height]
            }
            .map { String(format: "%.1f", $0) }
            .joined(separator: ":")
    }

    private func resolvedSpotlightTargets(in proxy: GeometryProxy) -> [FirstRunGuideResolvedTarget] {
        let overlayGlobalFrame = proxy.frame(in: .global)
        let resolvedTargets = targets.map { target in
            let localFrame = target.globalFrame
                .offsetBy(dx: -overlayGlobalFrame.minX, dy: -overlayGlobalFrame.minY)
            let padding: CGFloat = target.id.isSuggestedRecipeTarget || target.id == .firstPlan ? 0 : 5
            return FirstRunGuideResolvedTarget(
                id: target.id,
                globalFrame: localFrame.insetBy(dx: -padding, dy: -padding)
            )
        }

        if resolvedTargets.count > 1,
           resolvedTargets.allSatisfy({ $0.id.isCartListItemTarget }) {
            return [
                FirstRunGuideResolvedTarget(
                    id: .cartListItemOne,
                    globalFrame: unionFrame(of: resolvedTargets.map(\.globalFrame))
                )
            ]
        }

        return resolvedTargets
    }

    private func cornerRadius(for targetID: FirstRunGuideTargetID, targetFrame: CGRect) -> CGFloat {
        if targetID.isSuggestedRecipeTarget {
            return 24
        }
        if targetID == .firstPlan {
            return 4
        }
        if targetID == .cartScope || targetID == .cartAlreadyHaveIntro {
            return 5
        }
        return min(18, min(targetFrame.width, targetFrame.height) / 2)
    }

    private func spotlightPath(
        in size: CGSize,
        targets: [FirstRunGuideResolvedTarget]
    ) -> Path {
        var path = Path(CGRect(origin: .zero, size: size))
        for target in targets {
            let radius = cornerRadius(for: target.id, targetFrame: target.globalFrame)
            path.addRoundedRect(
                in: target.globalFrame,
                cornerSize: CGSize(width: radius, height: radius)
            )
        }
        return path
    }

    private func unionFrame(of frames: [CGRect]) -> CGRect {
        frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
    }

    private func coachmark(availableSize: CGSize, focusFrame: CGRect) -> some View {
        let preferredWidth: CGFloat
        if targets.contains(where: { $0.id == .recipeSavedInfo }) {
            preferredWidth = 238
        } else if targets.allSatisfy(\.id.isSuggestedRecipeTarget) {
            preferredWidth = 258
        } else {
            preferredWidth = 310
        }
        let coachmarkWidth = min(preferredWidth, availableSize.width - 32)

        return ZStack(alignment: .trailing) {
            Text(message)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(OunjePalette.background)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 3)
                .padding(.trailing, 34)
                .accessibilityAddTraits(.isStaticText)

            Button(action: showsAdvance ? onAdvance : onDismiss) {
                Image(systemName: showsAdvance ? "arrow.right" : "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(OunjePalette.background.opacity(0.75))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(OunjePalette.background.opacity(showsAdvance ? 0.09 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsAdvance ? "Next" : "Dismiss app guide")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(width: coachmarkWidth)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OunjePalette.softCream)
                .shadow(color: Color.black.opacity(0.28), radius: 16, y: 8)
        )
        .position(
            x: 16 + coachmarkWidth / 2,
            y: coachmarkCenterY(
                availableHeight: availableSize.height,
                focusFrame: focusFrame
            )
        )
        .accessibilityLabel(message)
    }

    private func coachmarkCenterY(
        availableHeight: CGFloat,
        focusFrame: CGRect
    ) -> CGFloat {
        let estimatedHalfHeight: CGFloat = 48

        if targets.contains(where: { $0.id == .planRecipes }) {
            return 88
        }

        if targets.allSatisfy({ $0.id.isSuggestedRecipeTarget }) {
            let aboveTarget = focusFrame.minY - estimatedHalfHeight - 14
            if aboveTarget - estimatedHalfHeight >= 12 {
                return aboveTarget
            }
        }

        if focusFrame.midY < availableHeight * 0.56 {
            return min(availableHeight - estimatedHalfHeight - 16, focusFrame.maxY + estimatedHalfHeight + 18)
        }
        return max(estimatedHalfHeight + 16, focusFrame.minY - estimatedHalfHeight - 18)
    }
}

private struct FirstRunGuideConfettiBurst: View {
    let origin: CGPoint
    @State private var isBurst = false

    private let colors: [Color] = [
        OunjePalette.softCream,
        .white,
        Color(hex: "63D471"),
        Color(hex: "F8B36A")
    ]

    var body: some View {
        ZStack {
            ForEach(0..<18, id: \.self) { index in
                let angle = Double(index) * (.pi * 2 / 18) - .pi / 2
                let distance = CGFloat(42 + (index % 4) * 12)
                RoundedRectangle(cornerRadius: index.isMultiple(of: 3) ? 3 : 1.5, style: .continuous)
                    .fill(colors[index % colors.count])
                    .frame(
                        width: index.isMultiple(of: 3) ? 5 : 7,
                        height: index.isMultiple(of: 3) ? 11 : 6
                    )
                    .rotationEffect(.degrees(isBurst ? Double(index * 37 + 90) : Double(index * 8)))
                    .position(origin)
                    .offset(
                        x: isBurst ? CGFloat(cos(angle)) * distance : 0,
                        y: isBurst ? CGFloat(sin(angle)) * distance : 0
                    )
                    .scaleEffect(isBurst ? 1 : 0.35)
                    .opacity(isBurst ? 0 : 1)
                    .animation(
                        .easeOut(duration: 0.9).delay(Double(index % 4) * 0.025),
                        value: isBurst
                    )
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isBurst = true
            }
        }
    }
}

private struct FirstRunGuideTouchShield: UIViewRepresentable {
    let cutouts: [CGRect]

    func makeUIView(context: Context) -> CutoutTouchShieldView {
        let view = CutoutTouchShieldView()
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: CutoutTouchShieldView, context: Context) {
        uiView.cutouts = cutouts
    }

    final class CutoutTouchShieldView: UIView {
        var cutouts: [CGRect] = []

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            !cutouts.contains(where: { $0.contains(point) })
        }
    }
}
