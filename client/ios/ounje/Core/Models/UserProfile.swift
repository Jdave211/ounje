import Foundation

enum CuisinePreference: String, CaseIterable, Codable, Identifiable {
    case italian
    case mexican
    case mediterranean
    case asian
    case indian
    case american
    case middleEastern
    case japanese
    case thai
    case korean
    case chinese
    case greek
    case french
    case spanish
    case caribbean
    case westAfrican
    case ethiopian
    case brazilian
    case vietnamese
    case turkish
    case moroccan
    case persian
    case filipino
    case southern
    case cajun
    case portuguese
    case german
    case british
    case vegan

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()

        switch normalized {
        case "italian": self = .italian
        case "mexican": self = .mexican
        case "mediterranean": self = .mediterranean
        case "asian": self = .asian
        case "indian": self = .indian
        case "american": self = .american
        case "middleeastern", "levantine": self = .middleEastern
        case "japanese": self = .japanese
        case "thai": self = .thai
        case "korean": self = .korean
        case "chinese": self = .chinese
        case "greek": self = .greek
        case "french": self = .french
        case "spanish": self = .spanish
        case "caribbean": self = .caribbean
        case "westafrican", "nigerian": self = .westAfrican
        case "ethiopian": self = .ethiopian
        case "brazilian": self = .brazilian
        case "vietnamese": self = .vietnamese
        case "turkish": self = .turkish
        case "moroccan": self = .moroccan
        case "persian", "iranian": self = .persian
        case "filipino": self = .filipino
        case "southern", "southernamerican": self = .southern
        case "cajun", "creole", "cajuncreole": self = .cajun
        case "portuguese": self = .portuguese
        case "german": self = .german
        case "british", "uk": self = .british
        case "vegan": self = .vegan
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported cuisine value: \(rawValue)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var title: String {
        switch self {
        case .italian: return "Italian"
        case .mexican: return "Mexican"
        case .mediterranean: return "Mediterranean"
        case .asian: return "Pan-Asian"
        case .indian: return "Indian"
        case .american: return "American"
        case .middleEastern: return "Middle Eastern"
        case .japanese: return "Japanese"
        case .thai: return "Thai"
        case .korean: return "Korean"
        case .chinese: return "Chinese"
        case .greek: return "Greek"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .caribbean: return "Caribbean"
        case .westAfrican: return "West African"
        case .ethiopian: return "Ethiopian"
        case .brazilian: return "Brazilian"
        case .vietnamese: return "Vietnamese"
        case .turkish: return "Turkish"
        case .moroccan: return "Moroccan"
        case .persian: return "Persian"
        case .filipino: return "Filipino"
        case .southern: return "Southern"
        case .cajun: return "Cajun"
        case .portuguese: return "Portuguese"
        case .german: return "German"
        case .british: return "British"
        case .vegan: return "Vegan"
        }
    }

    var flagEmoji: String? {
        switch self {
        case .italian: return "🇮🇹"
        case .mexican: return "🇲🇽"
        case .mediterranean: return "🇬🇷"
        case .asian: return "🌏"
        case .indian: return "🇮🇳"
        case .american: return "🇺🇸"
        case .middleEastern: return "🇱🇧"
        case .japanese: return "🇯🇵"
        case .thai: return "🇹🇭"
        case .korean: return "🇰🇷"
        case .chinese: return "🇨🇳"
        case .greek: return "🇬🇷"
        case .french: return "🇫🇷"
        case .spanish: return "🇪🇸"
        case .caribbean: return "🇯🇲"
        case .westAfrican: return "🇳🇬"
        case .ethiopian: return "🇪🇹"
        case .brazilian: return "🇧🇷"
        case .vietnamese: return "🇻🇳"
        case .turkish: return "🇹🇷"
        case .moroccan: return "🇲🇦"
        case .persian: return "🇮🇷"
        case .filipino: return "🇵🇭"
        case .southern: return "🇺🇸"
        case .cajun: return "🇺🇸"
        case .portuguese: return "🇵🇹"
        case .german: return "🇩🇪"
        case .british: return "🇬🇧"
        case .vegan: return nil
        }
    }

    var flagCode: String? {
        switch self {
        case .italian: return "IT"
        case .mexican: return "MX"
        case .mediterranean: return "GR"
        case .asian: return "AS"
        case .indian: return "IN"
        case .american: return "US"
        case .middleEastern: return "LB"
        case .japanese: return "JP"
        case .thai: return "TH"
        case .korean: return "KR"
        case .chinese: return "CN"
        case .greek: return "GR"
        case .french: return "FR"
        case .spanish: return "ES"
        case .caribbean: return "JM"
        case .westAfrican: return "NG"
        case .ethiopian: return "ET"
        case .brazilian: return "BR"
        case .vietnamese: return "VN"
        case .turkish: return "TR"
        case .moroccan: return "MA"
        case .persian: return "IR"
        case .filipino: return "PH"
        case .southern: return "US"
        case .cajun: return "US"
        case .portuguese: return "PT"
        case .german: return "DE"
        case .british: return "GB"
        case .vegan: return nil
        }
    }

    var badgeText: String {
        switch self {
        case .italian: return "IT"
        case .mexican: return "MX"
        case .mediterranean: return "MED"
        case .asian: return "AS"
        case .indian: return "IN"
        case .american: return "US"
        case .middleEastern: return "ME"
        case .japanese: return "JP"
        case .thai: return "TH"
        case .korean: return "KR"
        case .chinese: return "CN"
        case .greek: return "GR"
        case .french: return "FR"
        case .spanish: return "ES"
        case .caribbean: return "CAR"
        case .westAfrican: return "WA"
        case .ethiopian: return "ET"
        case .brazilian: return "BR"
        case .vietnamese: return "VN"
        case .turkish: return "TR"
        case .moroccan: return "MA"
        case .persian: return "IR"
        case .filipino: return "PH"
        case .southern: return "SO"
        case .cajun: return "CAJ"
        case .portuguese: return "PT"
        case .german: return "DE"
        case .british: return "UK"
        case .vegan: return "VG"
        }
    }

    var badgeHex: String {
        switch self {
        case .italian: return "E4512F"
        case .mexican: return "E95B3C"
        case .mediterranean: return "4A90A4"
        case .asian: return "8F63FF"
        case .indian: return "F08A24"
        case .american: return "5C7CFA"
        case .middleEastern: return "D97706"
        case .japanese: return "E11D48"
        case .thai: return "14B8A6"
        case .korean: return "EF4444"
        case .chinese: return "DC2626"
        case .greek: return "2563EB"
        case .french: return "6366F1"
        case .spanish: return "F59E0B"
        case .caribbean: return "10B981"
        case .westAfrican: return "84CC16"
        case .ethiopian: return "CA8A04"
        case .brazilian: return "22C55E"
        case .vietnamese: return "FB7185"
        case .turkish: return "EF4444"
        case .moroccan: return "B91C1C"
        case .persian: return "0EA5A4"
        case .filipino: return "3B82F6"
        case .southern: return "A16207"
        case .cajun: return "EA580C"
        case .portuguese: return "16A34A"
        case .german: return "52525B"
        case .british: return "1D4ED8"
        case .vegan: return "16A34A"
        }
    }
}

enum MealCadence: String, CaseIterable, Codable, Identifiable {
    case daily
    case everyFewDays
    case twiceWeekly
    case weekly
    case biweekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .everyFewDays: return "Every few days"
        case .twiceWeekly: return "Twice weekly"
        case .weekly: return "Every week"
        case .biweekly: return "Every two weeks"
        case .monthly: return "Every month"
        }
    }

    var dayInterval: Int {
        switch self {
        case .daily: return 1
        case .everyFewDays: return 3
        case .twiceWeekly: return 4
        case .weekly: return 7
        case .biweekly: return 14
        case .monthly: return 30
        }
    }

    var baseRecipeCount: Int {
        switch self {
        case .daily: return 2
        case .everyFewDays: return 3
        case .twiceWeekly: return 4
        case .weekly: return 5
        case .biweekly: return 9
        case .monthly: return 16
        }
    }
}

enum DeliveryAnchorDay: String, CaseIterable, Codable, Identifiable {
    case sunday
    case monday
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }

    var pluralTitle: String {
        "\(title)s"
    }

    var weekdayIndex: Int {
        switch self {
        case .sunday: return 1
        case .monday: return 2
        case .tuesday: return 3
        case .wednesday: return 4
        case .thursday: return 5
        case .friday: return 6
        case .saturday: return 7
        }
    }

    static func from(date: Date, calendar: Calendar = .current) -> DeliveryAnchorDay {
        switch calendar.component(.weekday, from: date) {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return .sunday
        }
    }
}

enum RecipeRotationPreference: String, CaseIterable, Codable, Identifiable {
    case dynamic
    case stable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dynamic: return "Dynamic"
        case .stable: return "Stable"
        }
    }

    var subtitle: String {
        switch self {
        case .dynamic: return "Prefer variety and avoid last cycle repeats."
        case .stable: return "Keep favorites and rotate only a small subset."
        }
    }
}

enum MealExplorationLevel: String, CaseIterable, Codable, Identifiable {
    case comfort
    case balanced
    case adventurous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfort: return "Comfort"
        case .balanced: return "Balanced"
        case .adventurous: return "Adventurous"
        }
    }

    var subtitle: String {
        switch self {
        case .comfort: return "Mostly familiar recipes."
        case .balanced: return "Some familiar, some new."
        case .adventurous: return "Frequent variety and surprises."
        }
    }
}

enum ShoppingProvider: String, CaseIterable, Codable, Identifiable {
    case walmart
    case instacart
    case kroger
    case amazonFresh

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch rawValue {
        case "instacart":
            self = .instacart
        case "walmart":
            self = .walmart
        case "kroger":
            self = .kroger
        case "amazonfresh", "amazon_fresh", "amazon-fresh":
            self = .amazonFresh
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported shopping provider value: \(rawValue)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var marketingTitle: String {
        switch self {
        case .instacart:
            return "Instacart"
        case .walmart:
            return "Walmart"
        case .kroger:
            return "Kroger"
        case .amazonFresh:
            return "Amazon Fresh"
        }
    }

    var title: String {
        switch self {
        case .walmart:     return "Walmart"
        case .instacart:   return "Instacart"
        case .kroger:      return "Kroger"
        case .amazonFresh: return "Amazon Fresh"
        }
    }

    var subtitle: String {
        switch self {
        case .walmart:     return "Everyday low prices"
        case .instacart:   return "Same-day from local stores"
        case .kroger:      return "Kroger, Ralphs, Fred Meyer & more"
        case .amazonFresh: return "Prime delivery"
        }
    }

    var logoSystemName: String {
        switch self {
        case .walmart:     return "cart.fill"
        case .instacart:   return "leaf.fill"
        case .kroger:      return "storefront.fill"
        case .amazonFresh: return "shippingbox.fill"
        }
    }

    var priceMultiplier: Double {
        switch self {
        case .walmart:     return 0.96
        case .instacart:   return 1.08
        case .kroger:      return 1.00
        case .amazonFresh: return 1.02
        }
    }

    var deliveryFee: Double {
        switch self {
        case .walmart:     return 8.95
        case .instacart:   return 9.99
        case .kroger:      return 10.95
        case .amazonFresh: return 7.99
        }
    }

    var etaDays: Int {
        switch self {
        case .walmart:     return 2
        case .instacart:   return 1
        case .kroger:      return 2
        case .amazonFresh: return 2
        }
    }

    var deliveryWindowReference: String {
        switch self {
        case .walmart, .kroger:
            return "Based on delivery coverage spanning 6 AM to 10:30 PM."
        case .instacart:
            return "Based on Instacart scheduled windows starting at 9 AM and running as late as midnight."
        case .amazonFresh:
            return "Based on standard daytime grocery delivery windows."
        }
    }

    var deliveryWindowOptions: [DeliveryWindowOption] {
        switch self {
        case .instacart:
            return [
                .init(startMinutes: 9 * 60, endMinutes: 11 * 60),
                .init(startMinutes: 11 * 60, endMinutes: 13 * 60),
                .init(startMinutes: 13 * 60, endMinutes: 15 * 60),
                .init(startMinutes: 15 * 60, endMinutes: 17 * 60),
                .init(startMinutes: 17 * 60, endMinutes: 19 * 60),
                .init(startMinutes: 19 * 60, endMinutes: 21 * 60),
                .init(startMinutes: 21 * 60, endMinutes: 23 * 60),
                .init(startMinutes: 22 * 60, endMinutes: 24 * 60)
            ]
        case .walmart, .kroger:
            return [
                .init(startMinutes: 6 * 60, endMinutes: 8 * 60),
                .init(startMinutes: 8 * 60, endMinutes: 10 * 60),
                .init(startMinutes: 10 * 60, endMinutes: 12 * 60),
                .init(startMinutes: 12 * 60, endMinutes: 14 * 60),
                .init(startMinutes: 14 * 60, endMinutes: 16 * 60),
                .init(startMinutes: 16 * 60, endMinutes: 18 * 60),
                .init(startMinutes: 18 * 60, endMinutes: 20 * 60),
                .init(startMinutes: 20 * 60, endMinutes: 22 * 60)
            ]
        case .amazonFresh:
            return [
                .init(startMinutes: 8 * 60, endMinutes: 10 * 60),
                .init(startMinutes: 10 * 60, endMinutes: 12 * 60),
                .init(startMinutes: 12 * 60, endMinutes: 14 * 60),
                .init(startMinutes: 14 * 60, endMinutes: 16 * 60),
                .init(startMinutes: 16 * 60, endMinutes: 18 * 60),
                .init(startMinutes: 18 * 60, endMinutes: 20 * 60)
            ]
        }
    }

    var availableDeliveryMinuteRange: ClosedRange<Int> {
        let options = deliveryWindowOptions
        let lower = options.map(\.startMinutes).min() ?? 9 * 60
        let upper = (options.map(\.endMinutes).max() ?? 21 * 60) - 1
        return lower...max(lower, upper)
    }

    func closestDeliveryWindow(to minutes: Int) -> DeliveryWindowOption {
        if let containing = deliveryWindowOptions.first(where: { minutes >= $0.startMinutes && minutes < $0.endMinutes }) {
            return containing
        }

        return deliveryWindowOptions.min {
            abs($0.startMinutes - minutes) < abs($1.startMinutes - minutes)
        } ?? deliveryWindowOptions[0]
    }

    func closestAvailableDeliveryTime(from date: Date, on baseDate: Date = .now) -> Date {
        let calendar = Calendar.current
        let minuteOfDay = (calendar.component(.hour, from: date) * 60) + calendar.component(.minute, from: date)
        let clampedMinutes = min(max(minuteOfDay, availableDeliveryMinuteRange.lowerBound), availableDeliveryMinuteRange.upperBound)
        let hour = clampedMinutes / 60
        let minute = clampedMinutes % 60
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: baseDate) ?? baseDate
    }

    func buildOrderURL(using items: [GroceryItem], deliveryAddress: DeliveryAddress? = nil) -> URL {
        let groceryQuery = items
            .prefix(10)
            .map { $0.name }
            .joined(separator: ", ")
        let locationQuery = [deliveryAddress?.city, deliveryAddress?.postalCode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let query = [groceryQuery, locationQuery]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "groceries"

        let rawURL: String
        switch self {
        case .walmart:
            rawURL = "https://www.walmart.com/search?q=\(query)"
        case .instacart:
            rawURL = "https://www.instacart.com/store/s?k=\(query)"
        case .kroger:
            rawURL = "https://www.kroger.com/search?query=\(query)"
        case .amazonFresh:
            rawURL = "https://www.amazon.com/s?k=\(query)&i=amazonfresh"
        }

        return URL(string: rawURL) ?? URL(string: "https://www.google.com/search?q=groceries")!
    }
}

struct DeliveryWindowOption: Identifiable, Hashable {
    let startMinutes: Int
    let endMinutes: Int

    var id: String {
        "\(startMinutes)-\(endMinutes)"
    }

    var title: String {
        "\(Self.formattedTime(minutes: startMinutes)) – \(Self.formattedTime(minutes: endMinutes))"
    }

    var shortTitle: String {
        title.replacingOccurrences(of: ":00", with: "")
    }

    var detail: String {
        let durationHours = max(1, (endMinutes - startMinutes) / 60)
        return durationHours == 1 ? "1-hour window" : "\(durationHours)-hour window"
    }

    private static func formattedTime(minutes: Int) -> String {
        let hour24 = min(max(minutes / 60, 0), 24)
        let minute = minutes % 60
        let normalizedHour = hour24 == 24 ? 0 : hour24
        let period = normalizedHour >= 12 ? "PM" : "AM"
        let hour12Base = normalizedHour % 12
        let hour12 = hour12Base == 0 ? 12 : hour12Base

        if minute == 0 {
            return "\(hour12) \(period)"
        }

        let minuteString = String(format: "%02d", minute)
        return "\(hour12):\(minuteString) \(period)"
    }
}

struct StorageProfile: Codable, Hashable {
    var pantryCapacity: Int
    var fridgeCapacity: Int
    var freezerCapacity: Int

    static let starter = StorageProfile(pantryCapacity: 18, fridgeCapacity: 14, freezerCapacity: 10)
}

struct ConsumptionProfile: Codable, Hashable {
    var adults: Int
    var kids: Int
    var mealsPerWeek: Int
    var includeLeftovers: Bool

    static let starter = ConsumptionProfile(adults: 2, kids: 0, mealsPerWeek: 4, includeLeftovers: true)

    var householdMultiplier: Double {
        Double(adults) + (Double(kids) * 0.6)
    }
}

struct DeliveryAddress: Codable, Hashable {
    var line1: String
    var line2: String
    var city: String
    var region: String
    var postalCode: String
    var deliveryNotes: String

    static let empty = DeliveryAddress(
        line1: "",
        line2: "",
        city: "",
        region: "",
        postalCode: "",
        deliveryNotes: ""
    )

    var isComplete: Bool {
        !line1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !postalCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BudgetWindow: String, CaseIterable, Codable, Identifiable {
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: return "Per week"
        case .monthly: return "Per month"
        }
    }
}

enum BudgetFlexibility: String, CaseIterable, Codable, Identifiable {
    case strict
    case slightlyFlexible
    case convenienceFirst

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strict: return "Save when possible"
        case .slightlyFlexible: return "Hold the line"
        case .convenienceFirst: return "More dynamic"
        }
    }

    var subtitle: String {
        switch self {
        case .strict: return "Let the planner come in under budget when it can."
        case .slightlyFlexible: return "Stay close to the target budget by default."
        case .convenienceFirst: return "Stretch more often for stronger ingredients and better meals."
        }
    }

    var calibrationScore: Int {
        switch self {
        case .strict: return 18
        case .slightlyFlexible: return 50
        case .convenienceFirst: return 82
        }
    }

    static func from(calibrationScore: Int) -> BudgetFlexibility {
        switch calibrationScore {
        case ..<34:
            return .strict
        case 67...:
            return .convenienceFirst
        default:
            return .slightlyFlexible
        }
    }
}

enum PurchasingBehavior: String, CaseIterable, Codable, Identifiable {
    case cheapest
    case healthier
    case premium
    case largerPacks
    case lowLeftovers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cheapest: return "Cheapest options"
        case .healthier: return "Healthier picks"
        case .premium: return "Premium ingredients"
        case .largerPacks: return "Larger packs"
        case .lowLeftovers: return "Fewer leftovers"
        }
    }
}

enum OrderingAutonomyLevel: String, CaseIterable, Codable, Identifiable {
    case suggestOnly
    case approvalRequired
    case autoOrderWithinBudget
    case fullyAutonomousGuardrails

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggestOnly: return "Suggest only"
        case .approvalRequired: return "Approve before checkout"
        case .autoOrderWithinBudget: return "Auto-order within budget"
        case .fullyAutonomousGuardrails: return "Fully autonomous with guardrails"
        }
    }
}

enum OunjePricingTier: String, CaseIterable, Codable, Identifiable {
    case free
    case plus
    case autopilot
    case foundingLifetime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free:
            return "Free"
        case .plus:
            return "Plus"
        case .autopilot:
            return "Autopilot"
        case .foundingLifetime:
            return "Founding lifetime"
        }
    }

    var subtitle: String {
        switch self {
        case .free:
            return "Discovery, saved recipes, and guided planning."
        case .plus:
            return "Unlimited imports, prep planning, and cart sync."
        case .autopilot:
            return "Legacy beta access. New plans use Plus."
        case .foundingLifetime:
            return "One-time founder access with Plus."
        }
    }

    var priceText: String {
        switch self {
        case .free:
            return "Free"
        case .plus:
            return "$4.99"
        case .autopilot:
            return "$4.99"
        case .foundingLifetime:
            return "$150"
        }
    }

    var originalPriceText: String? {
        switch self {
        case .foundingLifetime:
            return "$300"
        default:
            return nil
        }
    }

    var cadenceText: String {
        switch self {
        case .free:
            return "starter"
        case .plus, .autopilot:
            return "/month"
        case .foundingLifetime:
            return "one-time"
        }
    }

    var badgeText: String? {
        switch self {
        case .free:
            return "No card"
        case .plus:
            return "Best value"
        case .autopilot:
            return "Automation"
        case .foundingLifetime:
            return "40 spots"
        }
    }

    var economicsText: String {
        switch self {
        case .free:
            return "Planning only"
        case .plus:
            return "Social imports, prep plans, and cart sync"
        case .autopilot:
            return "Legacy beta mapped to Plus"
        case .foundingLifetime:
            return "Full access without monthly renewal"
        }
    }

    var maxOrderingAutonomy: OrderingAutonomyLevel {
        switch self {
        case .free:
            return .approvalRequired
        case .plus, .autopilot, .foundingLifetime:
            return .fullyAutonomousGuardrails
        }
    }

    func supports(_ autonomy: OrderingAutonomyLevel) -> Bool {
        switch autonomy {
        case .suggestOnly, .approvalRequired:
            return true
        case .autoOrderWithinBudget:
            return self == .plus || self == .autopilot || self == .foundingLifetime
        case .fullyAutonomousGuardrails:
            return self == .plus || self == .autopilot || self == .foundingLifetime
        }
    }

    static func minimumTier(for autonomy: OrderingAutonomyLevel) -> OunjePricingTier {
        switch autonomy {
        case .suggestOnly, .approvalRequired:
            return .free
        case .autoOrderWithinBudget:
            return .plus
        case .fullyAutonomousGuardrails:
            return .plus
        }
    }
}

enum OunjeMembershipBillingCadence: String, CaseIterable, Codable, Identifiable {
    case monthly
    case yearly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .monthly:
            return "Monthly"
        case .yearly:
            return "Yearly"
        }
    }

    var subtitle: String {
        switch self {
        case .monthly:
            return "Billed every month."
        case .yearly:
            return "Billed once a year."
        }
    }

    var cadenceSuffix: String {
        switch self {
        case .monthly:
            return "/month"
        case .yearly:
            return "/year"
        }
    }
}

struct OunjeMembershipPlan: Hashable, Codable, Identifiable {
    let tier: OunjePricingTier
    let cadence: OunjeMembershipBillingCadence

    var id: String { "\(tier.rawValue)-\(cadence.rawValue)" }

    var title: String { tier.title }
    var subtitle: String { tier.subtitle }

    var productID: String {
        switch (tier, cadence) {
        case (.plus, .monthly):
            return "net.ounje.plus.monthly"
        case (.plus, .yearly):
            return "net.ounje.plus.yearly"
        case (.autopilot, .monthly):
            return "net.ounje.autopilot.monthly"
        case (.autopilot, .yearly):
            return "net.ounje.autopilot.yearly"
        case (.free, .monthly):
            return "net.ounje.free.monthly"
        case (.free, .yearly):
            return "net.ounje.free.yearly"
        case (.foundingLifetime, .monthly):
            return "net.ounje.founding.monthly"
        case (.foundingLifetime, .yearly):
            return "net.ounje.founding.yearly"
        }
    }

    var displayPriceText: String {
        switch (tier, cadence) {
        case (.plus, .monthly):
            return "$4.99"
        case (.plus, .yearly):
            return "$39.99"
        case (.autopilot, .monthly):
            return "$4.99"
        case (.autopilot, .yearly):
            return "$39.99"
        case (.free, _):
            return "Free"
        case (.foundingLifetime, _):
            return "$399"
        }
    }

    var displayPriceLine: String {
        switch tier {
        case .free:
            return displayPriceText
        default:
            return "\(displayPriceText)\(cadence.cadenceSuffix)"
        }
    }

    var savingsText: String? {
        guard cadence == .yearly else { return nil }
        switch tier {
        case .plus:
            return "Save 33%"
        case .autopilot:
            return "Save 33%"
        case .free, .foundingLifetime:
            return nil
        }
    }

    var badgeText: String? {
        switch (tier, cadence) {
        case (.plus, .yearly):
            return "Best value"
        case (.plus, .monthly):
            return "Most picked"
        case (.autopilot, .monthly):
            return "Hands-off"
        case (.autopilot, .yearly):
            return "Best annual"
        case (.free, _):
            return "Starter"
        case (.foundingLifetime, _):
            return "Founding offer"
        }
    }

    static let defaultMonthlyPlans: [OunjeMembershipPlan] = [
        .init(tier: .plus, cadence: .monthly)
    ]

    static let defaultYearlyPlans: [OunjeMembershipPlan] = [
        .init(tier: .plus, cadence: .yearly)
    ]
}

enum AppEntitlementStatus: String, Codable, Hashable {
    case active
    case expired
    case revoked
    case inactive
}

enum AppEntitlementSource: String, Codable, Hashable {
    case appStore = "app_store"
    case manual
    case system
}

struct AppUserEntitlement: Codable, Hashable {
    var userID: String
    var tier: OunjePricingTier
    var status: AppEntitlementStatus
    var source: AppEntitlementSource
    var productID: String?
    var transactionID: String?
    var originalTransactionID: String?
    var expiresAt: Date?
    var updatedAt: Date?
    var metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case tier
        case status
        case source
        case productID = "product_id"
        case transactionID = "transaction_id"
        case originalTransactionID = "original_transaction_id"
        case expiresAt = "expires_at"
        case updatedAt = "updated_at"
        case metadata
    }

    var isActive: Bool {
        status == .active
    }

    var effectiveTier: OunjePricingTier {
        isActive ? tier : .free
    }
}

struct MealPrepSummarySection: Identifiable, Codable, Hashable {
    var id: String { title }
    var title: String
    var detail: String
}

struct UserProfile: Codable, Hashable {
    var preferredName: String?
    var preferredCuisines: [CuisinePreference]
    var cadence: MealCadence
    var deliveryAnchorDay: DeliveryAnchorDay
    var deliveryAnchorDate: Date?
    var deliveryTimeMinutes: Int
    var rotationPreference: RecipeRotationPreference
    var maxRepeatsPerCycle: Int
    var storage: StorageProfile
    var consumption: ConsumptionProfile
    var preferredProviders: [ShoppingProvider]
    var pantryStaples: [String]
    var ownedMainShopItems: [String]
    var allergies: [String]
    var budgetPerCycle: Double
    var explorationLevel: MealExplorationLevel
    var deliveryAddress: DeliveryAddress
    var dietaryPatterns: [String]
    var cuisineCountries: [String]
    var hardRestrictions: [String]
    var favoriteFoods: [String]
    var favoriteFlavors: [String]
    var neverIncludeFoods: [String]
    var mealPrepGoals: [String]
    var cooksForOthers: Bool
    var kitchenEquipment: [String]
    var budgetWindow: BudgetWindow
    var budgetFlexibility: BudgetFlexibility
    var purchasingBehavior: PurchasingBehavior
    var orderingAutonomy: OrderingAutonomyLevel
    var pricingTier: OunjePricingTier

    init(
        preferredName: String? = nil,
        preferredCuisines: [CuisinePreference],
        cadence: MealCadence,
        deliveryAnchorDay: DeliveryAnchorDay = .sunday,
        deliveryAnchorDate: Date? = nil,
        deliveryTimeMinutes: Int = 18 * 60,
        rotationPreference: RecipeRotationPreference,
        maxRepeatsPerCycle: Int,
        storage: StorageProfile,
        consumption: ConsumptionProfile,
        preferredProviders: [ShoppingProvider],
        pantryStaples: [String],
        ownedMainShopItems: [String] = [],
        allergies: [String],
        budgetPerCycle: Double,
        explorationLevel: MealExplorationLevel,
        deliveryAddress: DeliveryAddress,
        dietaryPatterns: [String] = [],
        cuisineCountries: [String] = [],
        hardRestrictions: [String] = [],
        favoriteFoods: [String] = [],
        favoriteFlavors: [String] = [],
        neverIncludeFoods: [String] = [],
        mealPrepGoals: [String] = [],
        cooksForOthers: Bool = false,
        kitchenEquipment: [String] = [],
        budgetWindow: BudgetWindow = .weekly,
        budgetFlexibility: BudgetFlexibility = .strict,
        purchasingBehavior: PurchasingBehavior = .healthier,
        orderingAutonomy: OrderingAutonomyLevel = .autoOrderWithinBudget,
        pricingTier: OunjePricingTier = .free
    ) {
        self.preferredName = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preferredCuisines = preferredCuisines
        self.cadence = cadence
        self.deliveryAnchorDay = deliveryAnchorDay
        self.deliveryAnchorDate = deliveryAnchorDate
        self.deliveryTimeMinutes = max(0, min(deliveryTimeMinutes, 23 * 60 + 59))
        self.rotationPreference = rotationPreference
        self.maxRepeatsPerCycle = maxRepeatsPerCycle
        self.storage = storage
        self.consumption = consumption
        self.preferredProviders = Self.normalizedPreferredProviders(preferredProviders)
        self.pantryStaples = pantryStaples
        self.ownedMainShopItems = ownedMainShopItems
        self.allergies = allergies
        self.budgetPerCycle = budgetPerCycle
        self.explorationLevel = explorationLevel
        self.deliveryAddress = deliveryAddress
        self.dietaryPatterns = dietaryPatterns
        self.cuisineCountries = cuisineCountries
        self.hardRestrictions = hardRestrictions
        self.favoriteFoods = favoriteFoods
        self.favoriteFlavors = favoriteFlavors
        self.neverIncludeFoods = neverIncludeFoods
        self.mealPrepGoals = mealPrepGoals
        self.cooksForOthers = cooksForOthers
        self.kitchenEquipment = kitchenEquipment
        self.budgetWindow = budgetWindow
        self.budgetFlexibility = budgetFlexibility
        self.purchasingBehavior = purchasingBehavior
        self.orderingAutonomy = orderingAutonomy
        self.pricingTier = pricingTier
    }

    static let starter = UserProfile(
        preferredName: nil,
        preferredCuisines: [.american, .chinese, .westAfrican],
        cadence: .biweekly,
        deliveryAnchorDay: .sunday,
        deliveryAnchorDate: .now,
        deliveryTimeMinutes: 18 * 60,
        rotationPreference: .dynamic,
        maxRepeatsPerCycle: 2,
        storage: .starter,
        consumption: .starter,
        preferredProviders: [.walmart, .instacart],
        pantryStaples: ["olive oil", "salt", "black pepper", "garlic"],
        ownedMainShopItems: [],
        allergies: [],
        budgetPerCycle: 140,
        explorationLevel: .balanced,
        deliveryAddress: .empty,
        dietaryPatterns: ["Omnivore"],
        cuisineCountries: [],
        favoriteFoods: ["Chicken bowls", "Pasta", "Rice bowls"],
        favoriteFlavors: ["Savory", "Spicy"],
        mealPrepGoals: [],
        kitchenEquipment: [],
        budgetWindow: .weekly,
        budgetFlexibility: .slightlyFlexible,
        purchasingBehavior: .healthier,
        orderingAutonomy: .approvalRequired,
        pricingTier: .free
    )

    var isPlanningReady: Bool {
        !preferredCuisines.isEmpty && budgetPerCycle >= 25
    }

    var isAutomationReady: Bool {
        isPlanningReady && deliveryAddress.isComplete
    }

    var absoluteRestrictions: [String] {
        normalizedUnique(allergies + hardRestrictions + neverIncludeFoods)
    }

    var trimmedPreferredName: String? {
        guard let preferredName else { return nil }
        let trimmed = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var budgetSummary: String {
        "\(budgetPerCycle.asCurrency) \(budgetWindow == .weekly ? "per week" : "per month")"
    }

    var cadenceScheduleSummary: String {
        cadence.title
    }

    var cadenceTitleOnly: String {
        cadence.title
    }

    var deliveryTimeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: dateForDeliveryTime())
    }

    func scheduledDeliveryDate(after reference: Date = .now) -> Date {
        let calendar = Calendar.current
        let hour = deliveryTimeMinutes / 60
        let minute = deliveryTimeMinutes % 60

        if deliveryAnchorDate == nil {
            func nextWeeklyOccurrence(weekday: Int) -> Date {
                let components = DateComponents(hour: hour, minute: minute, weekday: weekday)
                return calendar.nextDate(
                    after: reference.addingTimeInterval(-60),
                    matching: components,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                ) ?? reference
            }

            switch cadence {
            case .daily:
                let todayAtTime = calendar.date(
                    bySettingHour: hour,
                    minute: minute,
                    second: 0,
                    of: reference
                ) ?? reference
                if todayAtTime.timeIntervalSince(reference) > 0 {
                    return todayAtTime
                }
                return calendar.date(byAdding: .day, value: 1, to: todayAtTime) ?? todayAtTime
            case .everyFewDays:
                let future = calendar.date(byAdding: .day, value: cadence.dayInterval, to: reference) ?? reference
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: future) ?? future
            case .twiceWeekly, .weekly:
                return nextWeeklyOccurrence(weekday: deliveryAnchorDay.weekdayIndex)
            case .biweekly:
                let nextAnchor = nextWeeklyOccurrence(weekday: deliveryAnchorDay.weekdayIndex)
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: reference), to: calendar.startOfDay(for: nextAnchor)).day ?? 0
                if days >= 7 {
                    return nextAnchor
                }
                return calendar.date(byAdding: .day, value: 7, to: nextAnchor) ?? nextAnchor
            case .monthly:
                let nextMonth = calendar.date(byAdding: .month, value: 1, to: reference) ?? reference
                let monthInterval = calendar.dateInterval(of: .month, for: nextMonth) ?? DateInterval(start: nextMonth, duration: 30 * 24 * 60 * 60)
                var candidate = monthInterval.start
                while calendar.component(.weekday, from: candidate) != deliveryAnchorDay.weekdayIndex {
                    candidate = calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
                }
                return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: candidate) ?? candidate
            }
        }

        let anchorStartOfDay = calendar.startOfDay(for: deliveryAnchorDate ?? reference)

        func dateAtDeliveryTime(on day: Date) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        func nextAnchoredIntervalDate(intervalDays: Int) -> Date {
            let clampedInterval = max(1, intervalDays)
            let anchorAtTime = dateAtDeliveryTime(on: anchorStartOfDay)
            if reference <= anchorAtTime {
                return anchorAtTime
            }

            let referenceDay = calendar.startOfDay(for: reference)
            let elapsedDays = max(0, calendar.dateComponents([.day], from: anchorStartOfDay, to: referenceDay).day ?? 0)
            let completedIntervals = elapsedDays / clampedInterval

            var candidateDay = calendar.date(
                byAdding: .day,
                value: completedIntervals * clampedInterval,
                to: anchorStartOfDay
            ) ?? anchorStartOfDay
            var candidate = dateAtDeliveryTime(on: candidateDay)

            if candidate <= reference {
                candidateDay = calendar.date(byAdding: .day, value: clampedInterval, to: candidateDay) ?? candidateDay
                candidate = dateAtDeliveryTime(on: candidateDay)
            }

            return candidate
        }

        switch cadence {
        case .daily:
            return nextAnchoredIntervalDate(intervalDays: 1)
        case .everyFewDays, .twiceWeekly, .weekly, .biweekly:
            return nextAnchoredIntervalDate(intervalDays: cadence.dayInterval)
        case .monthly:
            var candidate = dateAtDeliveryTime(on: anchorStartOfDay)
            if candidate > reference {
                return candidate
            }

            while candidate <= reference {
                candidate = calendar.date(byAdding: .month, value: 1, to: candidate) ?? candidate.addingTimeInterval(30 * 24 * 60 * 60)
            }
            return candidate
        }
    }

    func dateForDeliveryTime(on date: Date = .now) -> Date {
        let hour = deliveryTimeMinutes / 60
        let minute = deliveryTimeMinutes % 60
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
    }

    var userFacingCuisineTitles: [String] {
        preferredCuisines
            .filter { $0 != .vegan }
            .map(\.title)
    }

    var householdSummary: String {
        let peopleCount = consumption.adults + consumption.kids
        let peopleText = peopleCount == 1 ? "1 person" : "\(peopleCount) people"
        if cooksForOthers {
            return "\(peopleText), cooking for others too"
        }
        return "\(peopleText), primarily self-serve"
    }

    var profileHeadline: String {
        "\(cadenceDescriptor.capitalized) prep profile"
    }

    var profileNarrative: String {
        var fragments: [String] = []
        fragments.append("Built around \(joinedOrFallback(userFacingCuisineTitles, fallback: "flexible comfort meals"))")
        fragments.append("for \(householdSummary)")
        fragments.append("at \(budgetSummary.lowercased())")

        if !absoluteRestrictions.isEmpty {
            fragments.append("while locking out \(joinedOrFallback(Array(absoluteRestrictions.prefix(3)), fallback: "hard restrictions").lowercased())")
        }

        return fragments.joined(separator: ", ") + "."
    }

    var profileSignals: [String] {
        var signals: [String] = [
            cadence.title,
            orderingAutonomy.title
        ]

        if let firstCuisine = userFacingCuisineTitles.first {
            signals.append(firstCuisine)
        }

        return normalizedUnique(signals)
    }

    var profileReadinessNotes: [String] {
        var notes: [String] = []

        if !absoluteRestrictions.isEmpty {
            notes.append("Hard guardrails are active for \(joinedOrFallback(Array(absoluteRestrictions.prefix(3)), fallback: "restricted ingredients").lowercased()).")
        }

        if !favoriteFoods.isEmpty {
            notes.append("The planner will lean into \(joinedOrFallback(Array(favoriteFoods.prefix(3)), fallback: "your go-to meals").lowercased()) first.")
        }

        notes.append("Meal cadence is set to \(cadenceScheduleSummary.lowercased()) with \(consumption.mealsPerWeek) planned meals per week.")
        notes.append("Budget guardrails are set to \(budgetSummary.lowercased()).")

        return notes
    }

    var structuredSummarySections: [MealPrepSummarySection] {
        var tasteLines: [String] = [
            "Cuisines: \(joinedOrFallback(userFacingCuisineTitles, fallback: "Open"))",
            "Country cuisines: \(joinedOrFallback(cuisineCountries, fallback: "None added"))",
            "Likes: \(joinedOrFallback(favoriteFoods, fallback: "Not specified"))"
        ]

        if !neverIncludeFoods.isEmpty {
            tasteLines.append("Never include: \(joinedOrFallback(neverIncludeFoods, fallback: "None listed"))")
        }

        return [
            MealPrepSummarySection(
                title: "Dietary identity",
                detail: joinedOrFallback(dietaryPatterns, fallback: "No dietary pattern set")
            ),
            MealPrepSummarySection(
                title: "Hard restrictions",
                detail: joinedOrFallback(absoluteRestrictions, fallback: "No hard restrictions recorded")
            ),
            MealPrepSummarySection(
                title: "Taste profile",
                detail: tasteLines.joined(separator: "\n")
            ),
            MealPrepSummarySection(
                title: "Household",
                detail: [
                    householdSummary,
                    "\(consumption.adults) adult(s), \(consumption.kids) kid(s)",
                    "\(consumption.mealsPerWeek) planned meals per week",
                    consumption.includeLeftovers ? "Leftovers encouraged" : "Minimal leftovers"
                ].joined(separator: "\n")
            ),
            MealPrepSummarySection(
                title: "Cadence and budget",
                detail: [
                    cadenceScheduleSummary,
                    budgetSummary
                ].joined(separator: "\n")
            ),
            MealPrepSummarySection(
                title: "Ordering",
                detail: "Autonomy: \(orderingAutonomy.title)"
            )
        ]
    }

    private var primaryGoalDescriptor: String {
        let loweredGoals = mealPrepGoals.map { $0.lowercased() }

        if loweredGoals.contains(where: { $0.contains("speed") }) {
            return "Fast-lane"
        }
        if loweredGoals.contains(where: { $0.contains("cost") }) {
            return "Budget-locked"
        }
        if loweredGoals.contains(where: { $0.contains("variety") }) {
            return "Variety-first"
        }
        if loweredGoals.contains(where: { $0.contains("macro") || $0.contains("protein") }) {
            return "Macro-minded"
        }
        if loweredGoals.contains(where: { $0.contains("family") }) {
            return "Household-ready"
        }
        if loweredGoals.contains(where: { $0.contains("cleanup") }) {
            return "Low-mess"
        }
        if loweredGoals.contains(where: { $0.contains("taste") }) {
            return "Flavor-first"
        }

        return "Adaptive"
    }

    private var cadenceDescriptor: String {
        switch cadence {
        case .daily:
            return "daily"
        case .everyFewDays:
            return "steady-cycle"
        case .twiceWeekly:
            return "twice-weekly"
        case .weekly:
            return "weekly"
        case .biweekly:
            return "biweekly"
        case .monthly:
            return "monthly"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case preferredName
        case preferredCuisines
        case cadence
        case deliveryAnchorDay
        case deliveryAnchorDate
        case deliveryTimeMinutes
        case rotationPreference
        case maxRepeatsPerCycle
        case storage
        case consumption
        case preferredProviders
        case pantryStaples
        case ownedMainShopItems
        case allergies
        case budgetPerCycle
        case explorationLevel
        case deliveryAddress
        case dietaryPatterns
        case cuisineCountries
        case hardRestrictions
        case favoriteFoods
        case favoriteFlavors
        case neverIncludeFoods
        case mealPrepGoals
        case cooksForOthers
        case kitchenEquipment
        case budgetWindow
        case budgetFlexibility
        case purchasingBehavior
        case orderingAutonomy
        case pricingTier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preferredName = try container.decodeIfPresent(String.self, forKey: .preferredName)
        preferredCuisines = try container.decode([CuisinePreference].self, forKey: .preferredCuisines)
        cadence = try container.decode(MealCadence.self, forKey: .cadence)
        deliveryAnchorDay = try container.decodeIfPresent(DeliveryAnchorDay.self, forKey: .deliveryAnchorDay) ?? .sunday
        deliveryAnchorDate = try container.decodeIfPresent(Date.self, forKey: .deliveryAnchorDate)
        deliveryTimeMinutes = try container.decodeIfPresent(Int.self, forKey: .deliveryTimeMinutes) ?? UserProfile.starter.deliveryTimeMinutes
        rotationPreference = try container.decode(RecipeRotationPreference.self, forKey: .rotationPreference)
        maxRepeatsPerCycle = try container.decode(Int.self, forKey: .maxRepeatsPerCycle)
        storage = try container.decode(StorageProfile.self, forKey: .storage)
        consumption = try container.decode(ConsumptionProfile.self, forKey: .consumption)
        preferredProviders = Self.normalizedPreferredProviders(
            try container.decode([ShoppingProvider].self, forKey: .preferredProviders)
        )
        pantryStaples = try container.decode([String].self, forKey: .pantryStaples)
        ownedMainShopItems = try container.decodeIfPresent([String].self, forKey: .ownedMainShopItems) ?? []
        allergies = try container.decodeIfPresent([String].self, forKey: .allergies) ?? []
        budgetPerCycle = try container.decodeIfPresent(Double.self, forKey: .budgetPerCycle) ?? UserProfile.starter.budgetPerCycle
        explorationLevel = try container.decodeIfPresent(MealExplorationLevel.self, forKey: .explorationLevel) ?? .balanced
        deliveryAddress = try container.decodeIfPresent(DeliveryAddress.self, forKey: .deliveryAddress) ?? .empty
        dietaryPatterns = try container.decodeIfPresent([String].self, forKey: .dietaryPatterns) ?? UserProfile.starter.dietaryPatterns
        cuisineCountries = try container.decodeIfPresent([String].self, forKey: .cuisineCountries) ?? []
        hardRestrictions = try container.decodeIfPresent([String].self, forKey: .hardRestrictions) ?? []
        favoriteFoods = try container.decodeIfPresent([String].self, forKey: .favoriteFoods) ?? []
        favoriteFlavors = try container.decodeIfPresent([String].self, forKey: .favoriteFlavors) ?? []
        neverIncludeFoods = try container.decodeIfPresent([String].self, forKey: .neverIncludeFoods) ?? []
        mealPrepGoals = try container.decodeIfPresent([String].self, forKey: .mealPrepGoals) ?? []
        cooksForOthers = try container.decodeIfPresent(Bool.self, forKey: .cooksForOthers) ?? false
        kitchenEquipment = try container.decodeIfPresent([String].self, forKey: .kitchenEquipment) ?? []
        budgetWindow = try container.decodeIfPresent(BudgetWindow.self, forKey: .budgetWindow) ?? .weekly
        budgetFlexibility = try container.decodeIfPresent(BudgetFlexibility.self, forKey: .budgetFlexibility) ?? .slightlyFlexible
        purchasingBehavior = try container.decodeIfPresent(PurchasingBehavior.self, forKey: .purchasingBehavior) ?? .healthier
        orderingAutonomy = try container.decodeIfPresent(OrderingAutonomyLevel.self, forKey: .orderingAutonomy) ?? .autoOrderWithinBudget
        pricingTier = try container.decodeIfPresent(OunjePricingTier.self, forKey: .pricingTier) ?? .plus
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(preferredName, forKey: .preferredName)
        try container.encode(preferredCuisines, forKey: .preferredCuisines)
        try container.encode(cadence, forKey: .cadence)
        try container.encode(deliveryAnchorDay, forKey: .deliveryAnchorDay)
        try container.encodeIfPresent(deliveryAnchorDate, forKey: .deliveryAnchorDate)
        try container.encode(deliveryTimeMinutes, forKey: .deliveryTimeMinutes)
        try container.encode(rotationPreference, forKey: .rotationPreference)
        try container.encode(maxRepeatsPerCycle, forKey: .maxRepeatsPerCycle)
        try container.encode(storage, forKey: .storage)
        try container.encode(consumption, forKey: .consumption)
        try container.encode(preferredProviders, forKey: .preferredProviders)
        try container.encode(pantryStaples, forKey: .pantryStaples)
        try container.encode(ownedMainShopItems, forKey: .ownedMainShopItems)
        try container.encode(allergies, forKey: .allergies)
        try container.encode(budgetPerCycle, forKey: .budgetPerCycle)
        try container.encode(explorationLevel, forKey: .explorationLevel)
        try container.encode(deliveryAddress, forKey: .deliveryAddress)
        try container.encode(dietaryPatterns, forKey: .dietaryPatterns)
        try container.encode(cuisineCountries, forKey: .cuisineCountries)
        try container.encode(hardRestrictions, forKey: .hardRestrictions)
        try container.encode(favoriteFoods, forKey: .favoriteFoods)
        try container.encode(favoriteFlavors, forKey: .favoriteFlavors)
        try container.encode(neverIncludeFoods, forKey: .neverIncludeFoods)
        try container.encode(cooksForOthers, forKey: .cooksForOthers)
        try container.encode(budgetWindow, forKey: .budgetWindow)
        try container.encode(purchasingBehavior, forKey: .purchasingBehavior)
        try container.encode(orderingAutonomy, forKey: .orderingAutonomy)
        try container.encode(pricingTier, forKey: .pricingTier)
    }

    private func joinedOrFallback(_ values: [String], fallback: String) -> String {
        let filtered = normalizedUnique(values)
        return filtered.isEmpty ? fallback : filtered.joined(separator: ", ")
    }

    private static func normalizedPreferredProviders(_ providers: [ShoppingProvider]) -> [ShoppingProvider] {
        var seen = Set<ShoppingProvider>()
        return providers.filter { seen.insert($0).inserted }
    }

    private func normalizedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }
}

enum AuthProvider: String, Codable, Hashable, Identifiable {
    case apple
    case google

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }
}

struct AuthSession: Codable, Hashable {
    var provider: AuthProvider
    var userID: String
    var email: String?
    var displayName: String?
    var signedInAt: Date
    var accessToken: String? = nil
    var refreshToken: String? = nil
}
