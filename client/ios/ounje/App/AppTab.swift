import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case discover
    case cookbook
    case cart
    case profile

    var id: String { rawValue }

    static let navigationTabs: [AppTab] = [.cookbook, .discover, .cart, .profile]

    var motionIndex: Int {
        switch self {
        case .cookbook:
            return 0
        case .discover:
            return 1
        case .cart:
            return 2
        case .profile:
            return 3
        }
    }

    var title: String {
        switch self {
        case .discover: return "Discover"
        case .cookbook: return "Recipes"
        case .cart: return "Cart"
        case .profile: return "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .discover: return "safari"
        case .cookbook: return "book.closed"
        case .cart: return "basket"
        case .profile: return "person.crop.circle"
        }
    }

}
