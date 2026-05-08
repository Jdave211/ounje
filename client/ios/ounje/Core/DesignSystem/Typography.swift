import SwiftUI
import Foundation
import UIKit

enum RecipeTypographyStyle: String, Codable, Hashable {
    case clean
    case playful

    static let defaultStyle: RecipeTypographyStyle = .clean

    var displayName: String {
        switch self {
        case .clean:
            return "Clean"
        case .playful:
            return "Personal"
        }
    }

    static func resolved(from rawValue: String?) -> RecipeTypographyStyle {
        guard let rawValue else { return defaultStyle }
        return RecipeTypographyStyle(rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? defaultStyle
    }
}

struct BiroScriptDisplayText: View {
    let text: String
    let size: CGFloat
    let color: Color

    init(_ text: String, size: CGFloat, color: Color = OunjePalette.primaryText) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        HelveticaNowDisplayText(text, size: size, color: color)
    }
}

struct HelveticaNowDisplayText: View {
    let text: String
    let size: CGFloat
    let color: Color
    let weight: Font.Weight

    init(
        _ text: String,
        size: CGFloat,
        color: Color = OunjePalette.primaryText,
        weight: Font.Weight = .heavy
    ) {
        self.text = text
        self.size = size
        self.color = color
        self.weight = weight
    }

    var body: some View {
        Text(text)
            .font(HelveticaNowDisplayFont.font(size: size, weight: weight))
            .tracking(0)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }
}

struct SleeScriptDisplayText: View {
    let text: String
    let size: CGFloat
    let color: Color

    init(_ text: String, size: CGFloat, color: Color = OunjePalette.primaryText) {
        self.text = text
        self.size = size
        self.color = color
    }

    var body: some View {
        Group {
            if shouldUseCustomNumerals {
                HandwrittenRunText(
                    text: text,
                    size: size,
                    color: color,
                    style: .slee
                )
            } else {
                ZStack(alignment: .topLeading) {
                    Text(text)
                        .font(.custom("Slee_handwritting-Regular", size: size))
                        .tracking(0.1)
                        .foregroundStyle(color.opacity(0.78))
                        .offset(x: 0.45, y: 0.35)

                    Text(text)
                        .font(.custom("Slee_handwritting-Regular", size: size))
                        .tracking(0.1)
                        .foregroundStyle(color)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var shouldUseCustomNumerals: Bool {
        guard text.contains(where: \.isNumber) else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowedScalars = CharacterSet.decimalDigits
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: ":+-–—/.,"))

        let isMostlyNumericLabel = trimmed.unicodeScalars.allSatisfy { allowedScalars.contains($0) }
        return isMostlyNumericLabel && trimmed.count <= 14
    }
}

struct SleeRecipeCardTitleText: View {
    let text: String
    let size: CGFloat
    let color: Color

    init(_ text: String, size: CGFloat, color: Color = OunjePalette.primaryText) {
        self.text = text
        self.size = size
        self.color = color
    }

    private var leadingDigitPrefix: String? {
        guard let match = text.range(of: #"^\d+"#, options: .regularExpression) else { return nil }
        return String(text[match])
    }

    private var remainderText: String {
        guard let prefix = leadingDigitPrefix else { return text }
        return text.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if let prefix = leadingDigitPrefix, !remainderText.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: size * 0.1) {
                    HandwrittenRunText(
                        text: prefix,
                        size: size,
                        color: color,
                        style: .slee
                    )
                    .fixedSize()

                    Text(remainderText)
                        .recipeCardTitleFont(size)
                        .foregroundStyle(color)
                        .lineLimit(2)
                        .minimumScaleFactor(0.84)
                }
            } else {
                Text(text)
                    .recipeCardTitleFont(size)
                    .foregroundStyle(color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

struct RecipeTypographyTitleText: View {
    let text: String
    let size: CGFloat
    let color: Color
    let style: RecipeTypographyStyle

    init(
        _ text: String,
        size: CGFloat,
        color: Color = OunjePalette.primaryText,
        style: RecipeTypographyStyle
    ) {
        self.text = text
        self.size = size
        self.color = color
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .clean:
                Text(text)
                    .font(.system(size: size, weight: .bold, design: .serif))
                    .tracking(0)
                    .foregroundStyle(color)
            case .playful:
                SleeRecipeCardTitleText(text, size: size, color: color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

extension View {
    func biroHeaderFont(_ size: CGFloat) -> some View {
        self.helveticaNowDisplayFont(size, weight: size >= 28 ? .heavy : .bold)
    }

    func helveticaNowDisplayFont(_ size: CGFloat, weight: Font.Weight = .heavy) -> some View {
        self
            .font(HelveticaNowDisplayFont.font(size: size, weight: weight))
            .tracking(0)
    }

    func sleeDisplayFont(_ size: CGFloat) -> some View {
        self.modifier(SleeDisplayModifier(size: size))
    }

    func recipeCardTitleFont(_ size: CGFloat) -> some View {
        self.modifier(RecipeCardTitleModifier(size: size))
    }
}

private enum HelveticaNowDisplayFont {
    private static let licensedFontCandidates = [
        "HelveticaNowDisplay-Bold",
        "HelveticaNowDisplay-ExtraBold",
        "HelveticaNowDisplay-Regular",
        "Helvetica Now Display",
        "HelveticaNowDisplay"
    ]

    static func font(size: CGFloat, weight: Font.Weight) -> Font {
        if let customName = licensedFontCandidates.first(where: { UIFont(name: $0, size: size) != nil }) {
            return .custom(customName, size: size)
        }

        return .system(size: size, weight: weight, design: .default)
    }
}

private struct SleeDisplayModifier: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content
                .font(.custom("Slee_handwritting-Regular", size: size))
                .tracking(0.12)
                .foregroundStyle(OunjePalette.primaryText.opacity(0.82))
                .offset(x: 0.55, y: 0.4)

            content
                .font(.custom("Slee_handwritting-Regular", size: size))
                .tracking(0.12)
        }
    }
}

private struct RecipeCardTitleModifier: ViewModifier {
    let size: CGFloat

    func body(content: Content) -> some View {
        ZStack(alignment: .topLeading) {
            content
                .font(.custom("Slee_handwritting-Regular", size: size))
                .tracking(0.1)
                .foregroundStyle(OunjePalette.primaryText.opacity(0.78))
                .offset(x: 0.45, y: 0.35)

            content
                .font(.custom("Slee_handwritting-Regular", size: size))
                .tracking(0.1)
        }
    }
}

private enum HandwrittenNumeralStyle {
    case slee

    var baseFontName: String {
        switch self {
        case .slee:
            return "Slee_handwritting-Regular"
        }
    }

    var tracking: CGFloat {
        switch self {
        case .slee:
            return 0.1
        }
    }

    var shadowOffset: CGSize {
        switch self {
        case .slee:
            return CGSize(width: 0.45, height: 0.35)
        }
    }

    var strokeWidthFactor: CGFloat {
        switch self {
        case .slee:
            return 0.08
        }
    }

    var characterSpacingFactor: CGFloat {
        switch self {
        case .slee:
            return 0.025
        }
    }

    var wordSpacingFactor: CGFloat {
        switch self {
        case .slee:
            return 0.16
        }
    }

    var numeralWidthFactor: CGFloat {
        switch self {
        case .slee:
            return 0.54
        }
    }
}

private struct HandwrittenRunText: View {
    let text: String
    let size: CGFloat
    let color: Color
    let style: HandwrittenNumeralStyle

    var body: some View {
        FlowWrapLayout(
            lineSpacing: size * 0.16,
            itemSpacing: size * style.wordSpacingFactor
        ) {
            ForEach(tokenizedWords.indices, id: \.self) { index in
                HandwrittenWordView(
                    word: tokenizedWords[index],
                    size: size,
                    color: color,
                    style: style
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var tokenizedWords: [String] {
        text
            .split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
    }
}

private struct HandwrittenWordView: View {
    let word: String
    let size: CGFloat
    let color: Color
    let style: HandwrittenNumeralStyle

    var body: some View {
        HStack(spacing: size * style.characterSpacingFactor) {
            ForEach(Array(word.enumerated()), id: \.offset) { _, character in
                if character.isNumber {
                    HandwrittenDigitView(
                        digit: character,
                        size: size,
                        color: color,
                        style: style
                    )
                } else {
                    ZStack(alignment: .topLeading) {
                    Text(String(character))
                        .font(.custom(style.baseFontName, size: size))
                        .tracking(style.tracking)
                        .foregroundStyle(color.opacity(0.78))
                        .offset(style.shadowOffset)

                        Text(String(character))
                            .font(.custom(style.baseFontName, size: size))
                            .tracking(style.tracking)
                            .foregroundStyle(color)
                    }
                }
            }
        }
    }
}

private struct HandwrittenDigitView: View {
    let digit: Character
    let size: CGFloat
    let color: Color
    let style: HandwrittenNumeralStyle

    var body: some View {
        HandwrittenDigitShape(digit: digit)
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: size * style.strokeWidthFactor,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(
                width: size * style.numeralWidthFactor,
                height: size * 0.9
            )
            .overlay(alignment: .topLeading) {
                HandwrittenDigitShape(digit: digit)
                    .stroke(
                        color.opacity(0.78),
                        style: StrokeStyle(
                            lineWidth: size * style.strokeWidthFactor,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .offset(style.shadowOffset)
            }
            .padding(.vertical, size * 0.02)
    }
}

private struct HandwrittenDigitShape: Shape {
    let digit: Character

    func path(in rect: CGRect) -> Path {
        switch digit {
        case "0":
            return zeroPath(in: rect)
        case "1":
            return onePath(in: rect)
        case "2":
            return twoPath(in: rect)
        case "3":
            return threePath(in: rect)
        case "4":
            return fourPath(in: rect)
        case "5":
            return fivePath(in: rect)
        case "6":
            return sixPath(in: rect)
        case "7":
            return sevenPath(in: rect)
        case "8":
            return eightPath(in: rect)
        case "9":
            return ninePath(in: rect)
        default:
            return Path()
        }
    }

    private func pt(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }

    private func zeroPath(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.12,
            y: rect.minY + rect.height * 0.08,
            width: rect.width * 0.72,
            height: rect.height * 0.78
        ))
        return path
    }

    private func onePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.28, 0.28, in: rect))
        path.addLine(to: pt(0.48, 0.12, in: rect))
        path.addLine(to: pt(0.48, 0.86, in: rect))
        path.move(to: pt(0.22, 0.84, in: rect))
        path.addLine(to: pt(0.64, 0.84, in: rect))
        return path
    }

    private func twoPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.18, 0.28, in: rect))
        path.addQuadCurve(to: pt(0.72, 0.24, in: rect), control: pt(0.42, 0.02, in: rect))
        path.addQuadCurve(to: pt(0.26, 0.58, in: rect), control: pt(0.72, 0.46, in: rect))
        path.addLine(to: pt(0.14, 0.84, in: rect))
        path.addLine(to: pt(0.76, 0.84, in: rect))
        return path
    }

    private func threePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.16, 0.2, in: rect))
        path.addQuadCurve(to: pt(0.66, 0.34, in: rect), control: pt(0.62, 0.02, in: rect))
        path.addQuadCurve(to: pt(0.3, 0.48, in: rect), control: pt(0.6, 0.46, in: rect))
        path.move(to: pt(0.3, 0.48, in: rect))
        path.addQuadCurve(to: pt(0.68, 0.82, in: rect), control: pt(0.7, 0.5, in: rect))
        path.addQuadCurve(to: pt(0.16, 0.8, in: rect), control: pt(0.46, 0.98, in: rect))
        return path
    }

    private func fourPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.66, 0.12, in: rect))
        path.addLine(to: pt(0.66, 0.84, in: rect))
        path.move(to: pt(0.18, 0.56, in: rect))
        path.addLine(to: pt(0.76, 0.56, in: rect))
        path.move(to: pt(0.18, 0.56, in: rect))
        path.addLine(to: pt(0.5, 0.12, in: rect))
        return path
    }

    private func fivePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.72, 0.12, in: rect))
        path.addLine(to: pt(0.24, 0.12, in: rect))
        path.addLine(to: pt(0.22, 0.46, in: rect))
        path.addQuadCurve(to: pt(0.7, 0.78, in: rect), control: pt(0.7, 0.44, in: rect))
        path.addQuadCurve(to: pt(0.18, 0.78, in: rect), control: pt(0.46, 0.96, in: rect))
        return path
    }

    private func sixPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.68, 0.18, in: rect))
        path.addQuadCurve(to: pt(0.24, 0.54, in: rect), control: pt(0.32, 0.08, in: rect))
        path.addQuadCurve(to: pt(0.66, 0.82, in: rect), control: pt(0.18, 0.88, in: rect))
        path.addQuadCurve(to: pt(0.42, 0.52, in: rect), control: pt(0.76, 0.56, in: rect))
        path.addQuadCurve(to: pt(0.22, 0.62, in: rect), control: pt(0.28, 0.48, in: rect))
        return path
    }

    private func sevenPath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.16, 0.16, in: rect))
        path.addLine(to: pt(0.78, 0.16, in: rect))
        path.addLine(to: pt(0.32, 0.86, in: rect))
        return path
    }

    private func eightPath(in rect: CGRect) -> Path {
        var path = Path()
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.22,
            y: rect.minY + rect.height * 0.08,
            width: rect.width * 0.44,
            height: rect.height * 0.34
        ))
        path.addEllipse(in: CGRect(
            x: rect.minX + rect.width * 0.18,
            y: rect.minY + rect.height * 0.42,
            width: rect.width * 0.52,
            height: rect.height * 0.4
        ))
        return path
    }

    private func ninePath(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: pt(0.64, 0.46, in: rect))
        path.addQuadCurve(to: pt(0.26, 0.2, in: rect), control: pt(0.24, 0.48, in: rect))
        path.addQuadCurve(to: pt(0.7, 0.22, in: rect), control: pt(0.48, 0.0, in: rect))
        path.addLine(to: pt(0.62, 0.84, in: rect))
        return path
    }
}

private struct FlowWrapLayout: SwiftUI.Layout {
    let lineSpacing: CGFloat
    let itemSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                usedWidth = max(usedWidth, x - itemSpacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            lineHeight = max(lineHeight, size.height)
            x += size.width + itemSpacing
        }

        usedWidth = max(usedWidth, x > 0 ? x - itemSpacing : 0)
        return CGSize(width: min(maxWidth, usedWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        let maxWidth = bounds.width

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && (x - bounds.minX) + size.width > maxWidth {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
