import Foundation

protocol RecipeCatalog {
    func recipes(matching cuisines: [CuisinePreference]) async -> [Recipe]
}

actor LocalRecipeCatalog: RecipeCatalog {
    private let allRecipes: [Recipe] = RecipeSeedData.all

    func recipes(matching cuisines: [CuisinePreference]) async -> [Recipe] {
        guard !cuisines.isEmpty else { return allRecipes }
        let allowed = Set(cuisines)
        let matched = allRecipes.filter { allowed.contains($0.cuisine) }
        return matched.isEmpty ? allRecipes : matched
    }
}

enum RecipeSeedData {
    static let all: [Recipe] = [
        Recipe(
            id: "it-001",
            title: "Sheet Pan Lemon Chicken",
            cuisine: .italian,
            prepMinutes: 30,
            servings: 4,
            storageFootprint: .medium,
            tags: ["high-protein", "batch-friendly"],
            ingredients: [
                .init(name: "chicken thighs", amount: 2.0, unit: "lb", estimatedUnitPrice: 4.2),
                .init(name: "baby potatoes", amount: 1.5, unit: "lb", estimatedUnitPrice: 1.2),
                .init(name: "zucchini", amount: 2.0, unit: "ct", estimatedUnitPrice: 0.9),
                .init(name: "lemon", amount: 2.0, unit: "ct", estimatedUnitPrice: 0.7),
                .init(name: "olive oil", amount: 0.25, unit: "cup", estimatedUnitPrice: 0.9)
            ]
        ),
        Recipe(
            id: "it-002",
            title: "Turkey Spinach Meatballs",
            cuisine: .italian,
            prepMinutes: 40,
            servings: 4,
            storageFootprint: .high,
            tags: ["freezer-friendly", "batch-friendly"],
            ingredients: [
                .init(name: "ground turkey", amount: 1.5, unit: "lb", estimatedUnitPrice: 4.5),
                .init(name: "spinach", amount: 5.0, unit: "oz", estimatedUnitPrice: 1.8),
                .init(name: "breadcrumbs", amount: 1.0, unit: "cup", estimatedUnitPrice: 0.8),
                .init(name: "eggs", amount: 1.0, unit: "ct", estimatedUnitPrice: 0.35),
                .init(name: "marinara sauce", amount: 2.0, unit: "cup", estimatedUnitPrice: 2.4)
            ]
        ),
        Recipe(
            id: "mx-001",
            title: "Chipotle Chicken Burrito Bowls",
            cuisine: .mexican,
            prepMinutes: 35,
            servings: 4,
            storageFootprint: .medium,
            tags: ["meal-prep", "high-protein"],
            ingredients: [
                .init(name: "chicken breast", amount: 1.8, unit: "lb", estimatedUnitPrice: 4.0),
                .init(name: "rice", amount: 2.0, unit: "cup", estimatedUnitPrice: 0.5),
                .init(name: "black beans", amount: 1.0, unit: "can", estimatedUnitPrice: 1.2),
                .init(name: "corn", amount: 1.0, unit: "cup", estimatedUnitPrice: 1.1),
                .init(name: "avocado", amount: 2.0, unit: "ct", estimatedUnitPrice: 1.3)
            ]
        ),
        Recipe(
            id: "mx-002",
            title: "Slow Cooker Beef Tinga",
            cuisine: .mexican,
            prepMinutes: 25,
            servings: 6,
            storageFootprint: .high,
            tags: ["slow-cooker", "batch-friendly"],
            ingredients: [
                .init(name: "beef chuck", amount: 2.5, unit: "lb", estimatedUnitPrice: 5.2),
                .init(name: "onion", amount: 1.0, unit: "ct", estimatedUnitPrice: 0.9),
                .init(name: "chipotle peppers", amount: 3.0, unit: "tbsp", estimatedUnitPrice: 0.7),
                .init(name: "crushed tomatoes", amount: 1.0, unit: "can", estimatedUnitPrice: 1.6),
                .init(name: "corn tortillas", amount: 12.0, unit: "ct", estimatedUnitPrice: 3.4)
            ]
        ),
        Recipe(
            id: "md-001",
            title: "Greek Salmon and Orzo",
            cuisine: .mediterranean,
            prepMinutes: 28,
            servings: 4,
            storageFootprint: .medium,
            tags: ["omega3", "high-protein"],
            ingredients: [
                .init(name: "salmon", amount: 1.5, unit: "lb", estimatedUnitPrice: 8.2),
                .init(name: "orzo", amount: 1.5, unit: "cup", estimatedUnitPrice: 0.9),
                .init(name: "cherry tomatoes", amount: 1.0, unit: "pint", estimatedUnitPrice: 2.8),
                .init(name: "cucumber", amount: 1.0, unit: "ct", estimatedUnitPrice: 1.0),
                .init(name: "feta", amount: 4.0, unit: "oz", estimatedUnitPrice: 2.6)
            ]
        ),
        Recipe(
            id: "md-002",
            title: "Lentil Shawarma Bowls",
            cuisine: .middleEastern,
            prepMinutes: 32,
            servings: 4,
            storageFootprint: .low,
            tags: ["vegetarian", "meal-prep"],
            ingredients: [
                .init(name: "brown lentils", amount: 1.5, unit: "cup", estimatedUnitPrice: 0.6),
                .init(name: "basmati rice", amount: 1.5, unit: "cup", estimatedUnitPrice: 0.7),
                .init(name: "red onion", amount: 1.0, unit: "ct", estimatedUnitPrice: 0.8),
                .init(name: "cucumber", amount: 1.0, unit: "ct", estimatedUnitPrice: 1.0),
                .init(name: "greek yogurt", amount: 0.5, unit: "cup", estimatedUnitPrice: 1.2)
            ]
        ),
        Recipe(
            id: "as-001",
            title: "Teriyaki Turkey Stir Fry",
            cuisine: .asian,
            prepMinutes: 26,
            servings: 4,
            storageFootprint: .medium,
            tags: ["quick", "high-protein"],
            ingredients: [
                .init(name: "ground turkey", amount: 1.5, unit: "lb", estimatedUnitPrice: 4.5),
                .init(name: "broccoli", amount: 3.0, unit: "cup", estimatedUnitPrice: 1.4),
                .init(name: "carrots", amount: 3.0, unit: "ct", estimatedUnitPrice: 0.3),
                .init(name: "soy sauce", amount: 0.25, unit: "cup", estimatedUnitPrice: 0.5),
                .init(name: "jasmine rice", amount: 1.75, unit: "cup", estimatedUnitPrice: 0.7)
            ]
        ),
        Recipe(
            id: "as-002",
            title: "Miso Tofu Noodle Soup",
            cuisine: .asian,
            prepMinutes: 24,
            servings: 4,
            storageFootprint: .low,
            tags: ["vegetarian", "quick"],
            ingredients: [
                .init(name: "firm tofu", amount: 14.0, unit: "oz", estimatedUnitPrice: 2.1),
                .init(name: "rice noodles", amount: 8.0, unit: "oz", estimatedUnitPrice: 2.0),
                .init(name: "mushrooms", amount: 8.0, unit: "oz", estimatedUnitPrice: 2.2),
                .init(name: "miso paste", amount: 3.0, unit: "tbsp", estimatedUnitPrice: 0.9),
                .init(name: "green onions", amount: 1.0, unit: "bunch", estimatedUnitPrice: 1.2)
            ]
        ),
        Recipe(
            id: "in-001",
            title: "Coconut Chickpea Curry",
            cuisine: .indian,
            prepMinutes: 30,
            servings: 4,
            storageFootprint: .low,
            tags: ["vegan", "batch-friendly"],
            ingredients: [
                .init(name: "chickpeas", amount: 2.0, unit: "can", estimatedUnitPrice: 1.2),
                .init(name: "coconut milk", amount: 1.0, unit: "can", estimatedUnitPrice: 2.1),
                .init(name: "spinach", amount: 5.0, unit: "oz", estimatedUnitPrice: 1.8),
                .init(name: "curry powder", amount: 1.0, unit: "tbsp", estimatedUnitPrice: 0.6),
                .init(name: "basmati rice", amount: 1.5, unit: "cup", estimatedUnitPrice: 0.7)
            ]
        ),
        Recipe(
            id: "in-002",
            title: "Tandoori Chicken Tray Bake",
            cuisine: .indian,
            prepMinutes: 36,
            servings: 4,
            storageFootprint: .medium,
            tags: ["high-protein", "meal-prep"],
            ingredients: [
                .init(name: "chicken thighs", amount: 2.0, unit: "lb", estimatedUnitPrice: 4.2),
                .init(name: "greek yogurt", amount: 1.0, unit: "cup", estimatedUnitPrice: 2.3),
                .init(name: "cauliflower", amount: 1.0, unit: "ct", estimatedUnitPrice: 2.6),
                .init(name: "red onion", amount: 1.0, unit: "ct", estimatedUnitPrice: 0.8),
                .init(name: "garam masala", amount: 1.0, unit: "tbsp", estimatedUnitPrice: 0.7)
            ]
        ),
        Recipe(
            id: "am-001",
            title: "Turkey Chili",
            cuisine: .american,
            prepMinutes: 34,
            servings: 6,
            storageFootprint: .high,
            tags: ["batch-friendly", "freezer-friendly"],
            ingredients: [
                .init(name: "ground turkey", amount: 2.0, unit: "lb", estimatedUnitPrice: 4.5),
                .init(name: "kidney beans", amount: 2.0, unit: "can", estimatedUnitPrice: 1.1),
                .init(name: "crushed tomatoes", amount: 1.0, unit: "can", estimatedUnitPrice: 1.6),
                .init(name: "bell peppers", amount: 2.0, unit: "ct", estimatedUnitPrice: 1.0),
                .init(name: "onion", amount: 1.0, unit: "ct", estimatedUnitPrice: 0.9)
            ]
        ),
        Recipe(
            id: "am-002",
            title: "BBQ Chicken Sweet Potato Skillet",
            cuisine: .american,
            prepMinutes: 29,
            servings: 4,
            storageFootprint: .medium,
            tags: ["quick", "meal-prep"],
            ingredients: [
                .init(name: "chicken breast", amount: 1.5, unit: "lb", estimatedUnitPrice: 4.0),
                .init(name: "sweet potatoes", amount: 2.0, unit: "ct", estimatedUnitPrice: 1.1),
                .init(name: "bbq sauce", amount: 0.75, unit: "cup", estimatedUnitPrice: 1.3),
                .init(name: "broccoli", amount: 3.0, unit: "cup", estimatedUnitPrice: 1.4),
                .init(name: "cheddar", amount: 4.0, unit: "oz", estimatedUnitPrice: 2.0)
            ]
        ),
        Recipe(
            id: "ve-001",
            title: "Roasted Veggie Quinoa Bowls",
            cuisine: .vegan,
            prepMinutes: 31,
            servings: 4,
            storageFootprint: .low,
            tags: ["vegan", "batch-friendly"],
            ingredients: [
                .init(name: "quinoa", amount: 1.5, unit: "cup", estimatedUnitPrice: 1.1),
                .init(name: "chickpeas", amount: 1.0, unit: "can", estimatedUnitPrice: 1.2),
                .init(name: "zucchini", amount: 2.0, unit: "ct", estimatedUnitPrice: 0.9),
                .init(name: "bell peppers", amount: 2.0, unit: "ct", estimatedUnitPrice: 1.0),
                .init(name: "tahini", amount: 0.25, unit: "cup", estimatedUnitPrice: 1.5)
            ]
        ),
        Recipe(
            id: "ve-002",
            title: "Smoky Black Bean Pasta",
            cuisine: .vegan,
            prepMinutes: 27,
            servings: 4,
            storageFootprint: .low,
            tags: ["quick", "vegan"],
            ingredients: [
                .init(name: "whole wheat pasta", amount: 12.0, unit: "oz", estimatedUnitPrice: 1.8),
                .init(name: "black beans", amount: 1.0, unit: "can", estimatedUnitPrice: 1.2),
                .init(name: "crushed tomatoes", amount: 1.0, unit: "can", estimatedUnitPrice: 1.6),
                .init(name: "spinach", amount: 5.0, unit: "oz", estimatedUnitPrice: 1.8),
                .init(name: "nutritional yeast", amount: 0.25, unit: "cup", estimatedUnitPrice: 1.7)
            ]
        )
    ]
}
