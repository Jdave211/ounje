import SwiftUI

struct CleanPaywallCadenceCard: View {
    let title: String
    let price: String
    let badgeText: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(isSelected ? 0.92 : 0.58), lineWidth: 1.2)
                        .frame(width: 19, height: 19)

                    if isSelected {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 9, height: 9)
                    }
                }

                HStack(spacing: 7) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)

                    if let badgeText {
                        Text(badgeText.uppercased())
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(0.16))
                            .clipShape(Capsule())
                    }
                }

                Spacer(minLength: 0)

                Text(price)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(height: 54)
            .background(Color.white.opacity(isSelected ? 0.16 : 0.09))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        Color.white.opacity(isSelected ? 0.92 : 0.20),
                        lineWidth: isSelected ? 1.3 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
