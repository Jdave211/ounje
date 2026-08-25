import SwiftUI
import Foundation
import UIKit

enum OunjeLayout {
    static let screenHorizontalPadding: CGFloat = 16
    static let authButtonHeight: CGFloat = 52
    static let tabBarHeight: CGFloat = 58
    static let setupActionBarReservedHeight: CGFloat = 112
    static let welcomeActionBarHeight: CGFloat = 182

    static let sheetHorizontalPadding: CGFloat = 20
    static let sheetTopPadding: CGFloat = 18
    static let sheetBottomPadding: CGFloat = 12
    static let sheetCornerRadius: CGFloat = 24
    static let panelCornerRadius: CGFloat = 8
    static let controlCornerRadius: CGFloat = 10
    static let closeButtonSize: CGFloat = 36
    static let primaryButtonHeight: CGFloat = 48
}

enum OunjeSheetTitleStyle {
    case brand
    case recipe(RecipeTypographyStyle)
    case standard
}

struct OunjeSheetCloseButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    init(accessibilityLabel: String = "Close", action: @escaping () -> Void) {
        self.accessibilityLabel = accessibilityLabel
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(OunjePalette.secondaryText)
                .frame(width: OunjeLayout.closeButtonSize, height: OunjeLayout.closeButtonSize)
                .background(
                    Circle()
                        .fill(OunjePalette.surface)
                        .overlay(Circle().stroke(OunjePalette.stroke, lineWidth: 1))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct OunjeSheetHeader: View {
    let title: String
    let subtitle: String?
    let titleStyle: OunjeSheetTitleStyle
    let closeAccessibilityLabel: String
    let onClose: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        titleStyle: OunjeSheetTitleStyle = .brand,
        closeAccessibilityLabel: String = "Close",
        onClose: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.titleStyle = titleStyle
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self.onClose = onClose
    }

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                titleLabel

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            OunjeSheetCloseButton(
                accessibilityLabel: closeAccessibilityLabel,
                action: onClose
            )
        }
    }

    @ViewBuilder
    private var titleLabel: some View {
        switch titleStyle {
        case .brand:
            Text(title)
                .biroHeaderFont(28)
                .foregroundStyle(OunjePalette.primaryText)
        case let .recipe(style):
            RecipeTypographyTitleText(
                title,
                size: style == .playful ? 29 : 27,
                color: OunjePalette.primaryText,
                style: style
            )
        case .standard:
            Text(title)
                .font(.system(size: 27, weight: .heavy, design: .rounded))
                .foregroundStyle(OunjePalette.primaryText)
        }
    }
}

struct OunjeSheetActionRow<Leading: View>: View {
    let title: String
    let subtitle: String
    let isDisabled: Bool
    let showsChevron: Bool
    let action: () -> Void
    let leading: Leading

    init(
        title: String,
        subtitle: String,
        isDisabled: Bool = false,
        showsChevron: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder leading: @escaping () -> Leading
    ) {
        self.title = title
        self.subtitle = subtitle
        self.isDisabled = isDisabled
        self.showsChevron = showsChevron
        self.action = action
        self.leading = leading()
    }

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 12) {
                leading

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(OunjePalette.primaryText)

                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OunjePalette.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(OunjePalette.secondaryText)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 72)
            .contentShape(Rectangle())
            .opacity(isDisabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityHint(subtitle)
    }
}

private struct OunjeSheetSurfaceModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16.4, *) {
            content
                .background(OunjePalette.background.ignoresSafeArea())
                .presentationBackground(OunjePalette.background)
                .presentationCornerRadius(OunjeLayout.sheetCornerRadius)
                .preferredColorScheme(.dark)
        } else {
            content
                .background(OunjePalette.background.ignoresSafeArea())
                .preferredColorScheme(.dark)
        }
    }
}

extension View {
    func ounjeSheetSurface() -> some View {
        modifier(OunjeSheetSurfaceModifier())
    }
}
