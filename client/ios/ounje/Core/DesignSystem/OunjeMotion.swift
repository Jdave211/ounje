import SwiftUI
import Foundation

enum OunjeMotion {
    static let heroSpring = Animation.spring(response: 0.46, dampingFraction: 0.86)
    static let screenSpring = Animation.spring(response: 0.4, dampingFraction: 0.86)
    static let tabSpring = Animation.spring(response: 0.34, dampingFraction: 0.8)
    static let quickSpring = Animation.spring(response: 0.28, dampingFraction: 0.82)
    static let subtleEase = Animation.easeInOut(duration: 0.18)
    static let cardPressScale: CGFloat = 0.985
}

struct DirectionalSurfaceRevealModifier: ViewModifier {
    var xOffset: CGFloat = 0
    var yOffset: CGFloat = 0
    var scale: CGFloat = 1
    var blur: CGFloat = 0
    var opacity: Double = 1

    func body(content: Content) -> some View {
        content
            .offset(x: xOffset, y: yOffset)
            .scaleEffect(scale)
            .opacity(opacity)
            .blur(radius: blur)
    }
}

struct OunjeCardPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? OunjeMotion.cardPressScale : 1)
            .animation(OunjeMotion.subtleEase, value: configuration.isPressed)
    }
}

struct RecipeTransitionContext {
    let namespace: Namespace.ID
    let recipeID: String

    var imageID: String { "recipe-transition-image-\(recipeID)" }
    var titleID: String { "recipe-transition-title-\(recipeID)" }
}

struct RecipeImageTransitionModifier: ViewModifier {
    let transitionContext: RecipeTransitionContext?
    var isSource: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if let transitionContext {
            content.matchedGeometryEffect(id: transitionContext.imageID, in: transitionContext.namespace, isSource: isSource)
        } else {
            content
        }
    }
}

struct RecipeTitleTransitionModifier: ViewModifier {
    let transitionContext: RecipeTransitionContext?
    var isSource: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if let transitionContext {
            content.matchedGeometryEffect(id: transitionContext.titleID, in: transitionContext.namespace, isSource: isSource)
        } else {
            content
        }
    }
}

struct RecipeDetailChromeRevealModifier: ViewModifier {
    let isVisible: Bool
    let yOffset: CGFloat
    let delay: Double

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0.001)
            .offset(y: isVisible ? 0 : yOffset)
            .blur(radius: isVisible ? 0 : 8)
            .animation(OunjeMotion.screenSpring.delay(delay), value: isVisible)
    }
}
