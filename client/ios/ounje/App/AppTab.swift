import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case prep
    case discover
    case cookbook
    case cart
    case profile

    var id: String { rawValue }

    var motionIndex: Int {
        switch self {
        case .prep:
            return 0
        case .discover:
            return 1
        case .cookbook:
            return 2
        case .cart:
            return 3
        case .profile:
            return 4
        }
    }

    var title: String {
        switch self {
        case .prep: return "Prep"
        case .discover: return "Discover"
        case .cookbook: return "Cookbook"
        case .cart: return "Cart"
        case .profile: return "Profile"
        }
    }

    var symbol: String {
        switch self {
        case .prep: return "calendar"
        case .discover: return "safari"
        case .cookbook: return "book.closed"
        case .cart: return "basket"
        case .profile: return "person.crop.circle"
        }
    }

}
