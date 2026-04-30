import Foundation

enum MainShopSnapshotBuilder {
    static func signature(for groceryItems: [GroceryItem]) -> String {
        groceryItems
            .map { item in
                let normalizedName = normalizedIngredientKey(item.name)
                let normalizedUnit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let normalizedAmount = String(format: "%.4f", item.amount)
                let sources = item.sourceIngredients
                    .map {
                        [
                            normalizedIngredientKey($0.recipeID),
                            normalizedIngredientKey($0.ingredientName),
                            $0.unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        ]
                        .joined(separator: "::")
                    }
                    .sorted()
                    .joined(separator: "|")
                return "\(normalizedName)::\(normalizedAmount)::\(normalizedUnit)::\(sources)"
            }
            .sorted()
            .joined(separator: "||")
    }

    static func buildSnapshot(
        for plan: MealPlan,
        profile: UserProfile? = nil,
        refreshToken: String? = nil
    ) async throws -> MainShopSnapshot {
        guard !plan.groceryItems.isEmpty else {
            return MainShopSnapshot(
                signature: signature(for: plan.groceryItems),
                generatedAt: .now,
                items: [],
                coverageSummary: nil
            )
        }

        let ownedItemKeys = ownedMainShopItemKeys(from: profile)
        let shoppingSpec = try await GroceryService.shared.fetchShoppingSpec(
            items: plan.groceryItems,
            plan: plan,
            refreshToken: refreshToken
        )
        let normalizedNames = Array(
            Set(
                candidateImageNames(for: shoppingSpec.items)
                + plan.groceryItems.flatMap { item in
                    [item.name] + item.sourceIngredients.map(\.ingredientName)
                }
                .map(normalizedIngredientKey)
                .filter { !$0.isEmpty }
            )
        ).sorted()
        let imageLookup = try await SupabaseIngredientsCatalogService.shared.fetchImageLookup(
            normalizedNames: normalizedNames
        )

        let derivedItems = shoppingSpec.items.compactMap { item in
            snapshotItem(for: item, imageLookup: imageLookup, ownedItemKeys: ownedItemKeys)
        }
        let items = sortedSnapshotItems(
            mergeLexicallyIdenticalSnapshotItems(
                ensuringCoverage(
                    snapshotItems: derivedItems,
                    groceryItems: plan.groceryItems,
                    imageLookup: imageLookup,
                    ownedItemKeys: ownedItemKeys
                )
            )
        )

        return MainShopSnapshot(
            signature: signature(for: plan.groceryItems),
            generatedAt: .now,
            items: items,
            coverageSummary: MainShopCoverageSummary(
                totalBaseUses: shoppingSpec.coverageSummary.totalBaseUses,
                accountedBaseUses: shoppingSpec.coverageSummary.accountedBaseUses,
                uncoveredBaseLabels: shoppingSpec.coverageSummary.uncoveredBaseLabels
            )
        )
    }

    private static func candidateImageNames(for items: [GroceryShoppingSpecResponse.ShoppingSpecItem]) -> [String] {
        var names: [String] = []
        for item in items {
            names.append(contentsOf: [
                item.shoppingContext?.canonicalName,
                item.shoppingContext?.canonicalKey,
                item.canonicalName,
                item.canonicalKey,
                item.originalName,
                item.name,
            ].compactMap { $0 })
            names.append(contentsOf: item.sourceIngredients.map(\.ingredientName))
            names.append(contentsOf: item.shoppingContext?.sourceIngredientNames ?? [])
        }
        return Array(
            Set(
                names
                    .map { normalizedIngredientKey($0) }
                    .filter { !$0.isEmpty }
            )
        ).sorted()
    }

    private static func snapshotItem(
        for item: GroceryShoppingSpecResponse.ShoppingSpecItem,
        imageLookup: [String: String],
        ownedItemKeys: Set<String>
    ) -> MainShopSnapshotItem? {
        let rawName = item.shoppingContext?.canonicalName ?? item.canonicalName ?? item.name
        let displayName = canonicalMainShopDisplayName(rawName)
        let canonicalKey = item.canonicalKey
            ?? item.shoppingContext?.canonicalKey
            ?? semanticMainShopMergeKey(rawName)
        guard !isExcludedMainShopIngredient(displayName),
              !isOwnedMainShopIngredient(displayName, canonicalKey: canonicalKey, ownedItemKeys: ownedItemKeys)
        else { return nil }

        let quantityText = formattedQuantity(amount: item.amount, unit: item.unit)
        let sourceUseCount = max(1, Set(item.sourceIngredients.map {
            "\(normalizedIngredientKey($0.recipeID))::\(normalizedIngredientKey($0.ingredientName))::\($0.unit.lowercased())"
        }).count)
        let recipeCount = Set((item.shoppingContext?.recipeTitles ?? []) + item.sourceRecipes).count
        let supportingParts = coverageSupportingParts(sourceUseCount: sourceUseCount, recipeCount: recipeCount)
        let isPantryStaple = item.shoppingContext?.isPantryStaple ?? false
        let isOptional = item.shoppingContext?.isOptional ?? false
        let sectionKindRawValue = sectionKindRawValue(
            displayName: displayName,
            role: item.shoppingContext?.role ?? "ingredient",
            isPantryStaple: isPantryStaple,
            isOptional: isOptional,
            combinedContext: [
                item.shoppingContext?.canonicalName,
                item.name,
                item.shoppingContext?.sourceIngredientNames.joined(separator: " "),
                item.sourceIngredients.map(\.ingredientName).joined(separator: " ")
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        )

        let imageURLString = imageLookup[
            normalizedIngredientKey(rawName)
        ] ?? imageLookup[
            normalizedIngredientKey(displayName)
        ] ?? imageLookup[
            normalizedIngredientKey(item.name)
        ]

        return MainShopSnapshotItem(
            name: displayName,
            quantityText: quantityText,
            supportingText: supportingParts.isEmpty ? nil : supportingParts.joined(separator: " • "),
            imageURLString: imageURLString,
            estimatedPriceText: nil,
            estimatedPriceValue: 0,
            sectionKindRawValue: sectionKindRawValue,
            removalKey: normalizedIngredientKey(displayName),
            canonicalKey: canonicalKey.isEmpty ? nil : canonicalKey,
            sourceIngredients: item.sourceIngredients,
            sourceEdgeIDs: item.sourceEdgeIDs ?? item.shoppingContext?.sourceEdgeIDs,
            alternativeNames: item.alternativeNames ?? item.shoppingContext?.alternativeNames,
            coverageState: item.coverageState ?? item.shoppingContext?.coverageState
        )
    }

    private static func ensuringCoverage(
        snapshotItems: [MainShopSnapshotItem],
        groceryItems: [GroceryItem],
        imageLookup: [String: String],
        ownedItemKeys: Set<String>
    ) -> [MainShopSnapshotItem] {
        var resolvedItems = snapshotItems

        for groceryItem in groceryItems {
            let displayName = canonicalMainShopDisplayName(groceryItem.name)
            let canonicalKey = semanticMainShopMergeKey(groceryItem.name)
            guard !canonicalKey.isEmpty else { continue }
            guard !isExcludedMainShopIngredient(displayName),
                  !isOwnedMainShopIngredient(displayName, canonicalKey: canonicalKey, ownedItemKeys: ownedItemKeys)
            else { continue }

            var coverageKeys = Set<String>()
            let sourceEdgeIDs = Set(groceryItem.sourceIngredients.map(sourceEdgeID).filter { !$0.isEmpty })
            coverageKeys.insert(canonicalKey)
            coverageKeys.insert(semanticMainShopMergeKey(groceryItem.name))
            for source in groceryItem.sourceIngredients {
                let normalizedSource = normalizedIngredientKey(source.ingredientName)
                if !normalizedSource.isEmpty {
                    coverageKeys.insert(normalizedSource)
                }
                let semanticSource = semanticMainShopMergeKey(source.ingredientName)
                if !semanticSource.isEmpty {
                    coverageKeys.insert(semanticSource)
                }
            }

            let isRepresented = resolvedItems.contains { item in
                let snapshotSourceEdgeIDs = Set(item.sourceEdgeIDs ?? [])
                if !sourceEdgeIDs.isEmpty, !snapshotSourceEdgeIDs.isDisjoint(with: sourceEdgeIDs) {
                    return true
                }
                var itemKeys = Set<String>()
                let normalizedName = normalizedIngredientKey(item.name)
                if !normalizedName.isEmpty {
                    itemKeys.insert(normalizedName)
                }
                let semanticName = semanticMainShopMergeKey(item.name)
                if !semanticName.isEmpty {
                    itemKeys.insert(semanticName)
                }
                let normalizedCanonical = normalizedIngredientKey(item.canonicalKey ?? "")
                if !normalizedCanonical.isEmpty {
                    itemKeys.insert(normalizedCanonical)
                }
                let semanticCanonical = semanticMainShopMergeKey(item.canonicalKey ?? "")
                if !semanticCanonical.isEmpty {
                    itemKeys.insert(semanticCanonical)
                }
                for source in item.sourceIngredients ?? [] {
                    let normalizedSource = normalizedIngredientKey(source.ingredientName)
                    if !normalizedSource.isEmpty {
                        itemKeys.insert(normalizedSource)
                    }
                    let semanticSource = semanticMainShopMergeKey(source.ingredientName)
                    if !semanticSource.isEmpty {
                        itemKeys.insert(semanticSource)
                    }
                }
                return !itemKeys.isDisjoint(with: coverageKeys)
            }

            guard !isRepresented else { continue }

            let sourceUseCount = max(
                1,
                Set(groceryItem.sourceIngredients.map {
                    "\(normalizedIngredientKey($0.recipeID))::\(normalizedIngredientKey($0.ingredientName))::\($0.unit.lowercased())"
                })
                .count
            )
            let recipeCount = Set(
                groceryItem.sourceIngredients
                    .map(\.recipeID)
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            ).count
            let supportingParts = coverageSupportingParts(sourceUseCount: sourceUseCount, recipeCount: recipeCount)
            let sectionKind = sectionKindRawValue(
                displayName: displayName,
                role: "ingredient",
                isPantryStaple: false,
                isOptional: false,
                combinedContext: (
                    [groceryItem.name] + groceryItem.sourceIngredients.map(\.ingredientName)
                )
                .joined(separator: " ")
            )
            let imageURLString = imageLookup[canonicalKey]
                ?? imageLookup[normalizedIngredientKey(displayName)]
            let quantityText = formattedQuantity(amount: groceryItem.amount, unit: groceryItem.unit)

            resolvedItems.append(
                MainShopSnapshotItem(
                    name: displayName,
                    quantityText: quantityText,
                    supportingText: supportingParts.isEmpty ? nil : supportingParts.joined(separator: " • "),
                    imageURLString: imageURLString,
                    estimatedPriceText: nil,
                    estimatedPriceValue: groceryItem.estimatedPrice,
                    sectionKindRawValue: sectionKind,
                    removalKey: canonicalKey,
                    canonicalKey: canonicalKey,
                    sourceIngredients: groceryItem.sourceIngredients,
                    sourceEdgeIDs: Array(sourceEdgeIDs).sorted(),
                    alternativeNames: nil,
                    coverageState: sourceEdgeIDs.isEmpty ? "fallback" : "covered"
                )
            )
        }

        return resolvedItems
    }

    private static func ownedMainShopItemKeys(from profile: UserProfile?) -> Set<String> {
        Set(
            (profile?.ownedMainShopItems ?? [])
                .map(normalizedIngredientKey)
                .filter { !$0.isEmpty }
        )
    }

    private static func isOwnedMainShopIngredient(
        _ value: String,
        canonicalKey: String,
        ownedItemKeys: Set<String>
    ) -> Bool {
        guard !ownedItemKeys.isEmpty else { return false }

        let normalized = normalizedIngredientKey(value)
        let semanticKey = semanticMainShopMergeKey(value)
        let candidateKeys = Set([normalized, canonicalKey, semanticKey].filter { !$0.isEmpty })
        guard !candidateKeys.isEmpty else { return false }

        return ownedItemKeys.contains { ownedKey in
            candidateKeys.contains(where: { candidateKey in
                ownedKey == candidateKey
                    || ownedKey.contains(candidateKey)
                    || candidateKey.contains(ownedKey)
            })
        }
    }

    private static func sortedSnapshotItems(_ items: [MainShopSnapshotItem]) -> [MainShopSnapshotItem] {
        items.sorted { lhs, rhs in
            let lhsSection = lhs.sectionKindRawValue ?? Int.max
            let rhsSection = rhs.sectionKindRawValue ?? Int.max
            if lhsSection != rhsSection {
                return lhsSection < rhsSection
            }

            let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameComparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }

            let lhsQuantity = lhs.quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhsQuantity = rhs.quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
            return lhsQuantity.localizedCaseInsensitiveCompare(rhsQuantity) == .orderedAscending
        }
    }

    private static func mergeLexicallyIdenticalSnapshotItems(_ items: [MainShopSnapshotItem]) -> [MainShopSnapshotItem] {
        struct Aggregate {
            var item: MainShopSnapshotItem
            var count: Int
            var unitLabel: String
            var supportingParts: Set<String>
        }

        var aggregates: [String: Aggregate] = [:]
        var order: [String] = []

        for item in items {
            guard !isExcludedMainShopIngredient(item.name) else { continue }
            let key = item.canonicalKey ?? semanticMainShopMergeKey(item.name)
            guard !key.isEmpty else { continue }

            let parsed = parsedDisplayQuantity(item.quantityText)
            let count = max(1, parsed?.roundedCount ?? 1)
            let rawUnit = parsed?.unitLabel ?? "items"
            if var existing = aggregates[key] {
                existing.count += count
                existing.supportingParts.formUnion(splitSupportingText(item.supportingText))
                let preferredItem = preferredMergedSnapshotItem(existing.item, item)
                let bestUnit = existing.unitLabel.count >= rawUnit.count ? existing.unitLabel : rawUnit
                existing.unitLabel = normalizedMainShopUnitLabel(bestUnit, count: existing.count)
                let combinedSources = mergedSourceIngredients(
                    existing.item.sourceIngredients ?? [],
                    item.sourceIngredients ?? []
                )
                let combinedSourceEdgeIDs = Array(Set((existing.item.sourceEdgeIDs ?? []) + (item.sourceEdgeIDs ?? []))).sorted()
                let combinedAlternativeNames = Array(Set((existing.item.alternativeNames ?? []) + (item.alternativeNames ?? []))).sorted()
                let resolvedName = canonicalMainShopDisplayName(preferredItem.name)
                existing.item = MainShopSnapshotItem(
                    name: resolvedName,
                    quantityText: "\(existing.count) \(existing.unitLabel)",
                    supportingText: combinedSupportingText(from: existing.supportingParts),
                    imageURLString: preferredItem.imageURLString ?? existing.item.imageURLString ?? item.imageURLString,
                    estimatedPriceText: preferredItem.estimatedPriceText ?? existing.item.estimatedPriceText ?? item.estimatedPriceText,
                    estimatedPriceValue: existing.item.estimatedPriceValue + item.estimatedPriceValue,
                    sectionKindRawValue: min(preferredItem.sectionKindRawValue ?? Int.max, existing.item.sectionKindRawValue ?? Int.max),
                    removalKey: key,
                    canonicalKey: key,
                    sourceIngredients: combinedSources,
                    sourceEdgeIDs: combinedSourceEdgeIDs.isEmpty ? nil : combinedSourceEdgeIDs,
                    alternativeNames: combinedAlternativeNames.isEmpty ? nil : combinedAlternativeNames,
                    coverageState: combinedSourceEdgeIDs.isEmpty ? existing.item.coverageState ?? item.coverageState : "covered"
                )
                aggregates[key] = existing
            } else {
                let unitLabel = normalizedMainShopUnitLabel(rawUnit, count: count)
                let resolvedName = canonicalMainShopDisplayName(item.name)
                aggregates[key] = Aggregate(
                    item: MainShopSnapshotItem(
                        name: resolvedName,
                        quantityText: "\(count) \(unitLabel)",
                        supportingText: item.supportingText,
                        imageURLString: item.imageURLString,
                        estimatedPriceText: item.estimatedPriceText,
                        estimatedPriceValue: item.estimatedPriceValue,
                        sectionKindRawValue: item.sectionKindRawValue,
                        removalKey: key,
                        canonicalKey: key,
                        sourceIngredients: item.sourceIngredients,
                        sourceEdgeIDs: item.sourceEdgeIDs,
                        alternativeNames: item.alternativeNames,
                        coverageState: item.coverageState
                    ),
                    count: count,
                    unitLabel: unitLabel,
                    supportingParts: splitSupportingText(item.supportingText)
                )
                order.append(key)
            }
        }

        return order.compactMap { aggregates[$0]?.item }
    }

    private static func splitSupportingText(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(
            value
                .split(separator: "•")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter {
                    !$0.isEmpty
                    && $0.caseInsensitiveCompare("Pantry check") != .orderedSame
                }
        )
    }

    private static func combinedSupportingText(from parts: Set<String>) -> String? {
        guard !parts.isEmpty else { return nil }
        return parts.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.joined(separator: " • ")
    }

    private static func coverageSupportingParts(sourceUseCount: Int, recipeCount: Int) -> [String] {
        switch (sourceUseCount > 1, recipeCount > 1) {
        case (_, true):
            return ["Used in \(recipeCount) recipes"]
        case (true, false):
            return ["Used \(sourceUseCount)x in this prep"]
        case (false, false):
            return []
        }
    }

    private static func formattedQuantity(amount: Double, unit: String) -> String {
        let normalizedUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let roundedAmount = normalizedAmount(amount)

        if ["oz", "ounce", "ounces"].contains(normalizedUnit),
           amount >= 16,
           amount.truncatingRemainder(dividingBy: 16) == 0 {
            let pounds = amount / 16
            return "\(normalizedAmount(pounds)) lb"
        }

        if normalizedUnit == "ct" || normalizedUnit == "count" {
            let label = amount == 1 ? "item" : "items"
            return "\(roundedAmount) \(label)"
        }

        if normalizedUnit.isEmpty {
            return roundedAmount
        }

        return "\(roundedAmount) \(unit)"
    }

    private static func parsedDisplayQuantity(_ quantityText: String) -> (roundedCount: Int, unitLabel: String)? {
        let trimmed = quantityText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return nil }

        let numericParts = first
            .split(separator: "-")
            .compactMap { parseNumericToken(String($0)) }
        guard !numericParts.isEmpty else { return nil }

        let baseAmount = numericParts.max() ?? 1
        let roundedCount = max(1, Int(ceil(baseAmount)))
        let unitTokens = Array(tokens.dropFirst())
        let unitLabel = unitTokens.isEmpty ? "units" : unitTokens.joined(separator: " ")
        return (roundedCount, unitLabel)
    }

    private static func parseNumericToken(_ token: String) -> Double? {
        let cleaned = token.trimmingCharacters(in: CharacterSet(charactersIn: ",()"))
        guard !cleaned.isEmpty else { return nil }

        if cleaned.contains("/") {
            let parts = cleaned.split(separator: "/")
            guard parts.count == 2,
                  let numerator = Double(parts[0]),
                  let denominator = Double(parts[1]),
                  denominator != 0
            else {
                return nil
            }
            return numerator / denominator
        }

        return Double(cleaned)
    }

    private static func normalizedAmount(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 {
            return String(Int(value.rounded()))
        }
        return value.roundedString(1)
    }

    private static func normalizedMainShopUnitLabel(_ rawLabel: String, count: Int) -> String {
        let normalized = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return count == 1 ? "item" : "items"
        }

        let singularToPlural: [String: String] = [
            "item": "items",
            "bottle": "bottles",
            "jar": "jars",
            "can": "cans",
            "bag": "bags",
            "pack": "packs",
            "head": "heads",
            "bunch": "bunches",
            "carton": "cartons",
            "tub": "tubs",
            "clove": "cloves"
        ]
        let pluralToSingular = Dictionary(uniqueKeysWithValues: singularToPlural.map { ($1, $0) })

        if count == 1 {
            return pluralToSingular[normalized] ?? normalized
        }
        return singularToPlural[normalized] ?? normalized
    }

    private static func normalizedIngredientKey(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalMainShopDisplayName(_ rawName: String) -> String {
        var normalized = normalizedIngredientKey(rawName)
        guard !normalized.isEmpty else { return prettyShoppingName(rawName) }

        if let orRange = normalized.range(of: " or ") {
            normalized = String(normalized[..<orRange.lowerBound])
        }
        if let slashRange = normalized.range(of: " / ") {
            normalized = String(normalized[..<slashRange.lowerBound])
        }

        let tokens = normalized
            .split(separator: " ")
            .map { normalizedMainShopToken(String($0)) }
            .filter { !$0.isEmpty && !mainShopDescriptorTokens.contains($0) }
        let canonical = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return prettyShoppingName(canonical.isEmpty ? normalized : canonical)
    }

    private static func semanticMainShopMergeKey(_ value: String) -> String {
        let normalized = normalizedIngredientKey(canonicalMainShopDisplayName(value))
        guard !normalized.isEmpty else { return "" }
        let tokens = normalized
            .split(separator: " ")
            .map { normalizedMainShopToken(String($0)) }
            .filter { !mainShopDescriptorTokens.contains($0) }
        let key = tokens.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? normalized : key
    }

    private static func normalizedMainShopToken(_ value: String) -> String {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else { return "" }
        if token == "tomatoes" { return "tomato" }
        if token == "potatoes" { return "potato" }
        if token == "avocados" { return "avocado" }
        if token == "onions" { return "onion" }
        if token == "thighs" { return "thigh" }
        if token == "breasts" { return "breast" }
        if token.hasSuffix("ies"), token.count > 4 {
            return String(token.dropLast(3)) + "y"
        }
        if token.hasSuffix("s"), token.count > 3, !token.hasSuffix("ss") {
            return String(token.dropLast())
        }
        return token
    }

    private static func isExcludedMainShopIngredient(_ value: String) -> Bool {
        [
            "water",
            "cold water",
            "warm water",
            "hot water",
            "boiling water",
            "ice water",
            "filtered water"
        ].contains(normalizedIngredientKey(value))
    }

    private static let mainShopDescriptorTokens: Set<String> = [
        "baby",
        "boneless",
        "dried",
        "extra",
        "fresh",
        "frozen",
        "grated",
        "ground",
        "kosher",
        "lean",
        "light",
        "low",
        "mild",
        "natural",
        "organic",
        "pure",
        "reduced",
        "salted",
        "shredded",
        "skinless",
        "smoked",
        "sweet",
        "thin",
        "unsalted",
        "virgin",
        "whole",
        "and",
        "or",
        "cooked",
        "instant",
        "cup",
        "cups",
        "prepared",
        "bag",
        "bags",
        "box",
        "boxes",
        "can",
        "cans",
        "carton",
        "cartons",
        "jar",
        "jars",
        "pack",
        "packs",
        "packet",
        "packets",
        "package",
        "packages"
    ]

    private static func mergedSourceIngredients(
        _ lhs: [GroceryItemSource],
        _ rhs: [GroceryItemSource]
    ) -> [GroceryItemSource] {
        var seen = Set<String>()
        var merged: [GroceryItemSource] = []
        for source in lhs + rhs {
            let key = [
                normalizedIngredientKey(source.recipeID),
                normalizedIngredientKey(source.ingredientName),
                normalizedIngredientKey(source.unit)
            ].joined(separator: "::")
            guard seen.insert(key).inserted else { continue }
            merged.append(source)
        }
        return merged
    }

    private static func sourceEdgeID(_ source: GroceryItemSource) -> String {
        let recipeID = normalizedIngredientKey(source.recipeID)
        let ingredientName = normalizedIngredientKey(source.ingredientName)
        let unit = normalizedIngredientKey(source.unit)
        guard !recipeID.isEmpty, !ingredientName.isEmpty else { return "" }
        return "\(recipeID)::\(ingredientName)::\(unit)"
    }

    private static func preferredMergedSnapshotItem(_ lhs: MainShopSnapshotItem, _ rhs: MainShopSnapshotItem) -> MainShopSnapshotItem {
        let lhsScore = displaySpecificityScore(lhs.name)
        let rhsScore = displaySpecificityScore(rhs.name)
        if lhsScore == rhsScore {
            return lhs.name.count >= rhs.name.count ? lhs : rhs
        }
        return lhsScore >= rhsScore ? lhs : rhs
    }

    private static func displaySpecificityScore(_ value: String) -> Int {
        let normalized = normalizedIngredientKey(value)
        guard !normalized.isEmpty else { return 0 }
        let tokenCount = normalized.split(separator: " ").count
        let abbreviationPenalty = normalized.count <= 3 ? 50 : 0
        return tokenCount * 20 + normalized.count - abbreviationPenalty
    }

    private static func prettyShoppingName(_ rawName: String) -> String {
        rawName
            .split(separator: " ")
            .map { token in
                let lowered = token.lowercased()
                return ["bbq", "caesar"].contains(lowered) ? lowered.uppercased() : lowered.capitalized
            }
            .joined(separator: " ")
    }

    private static func sectionKindRawValue(
        displayName: String,
        role: String,
        isPantryStaple: Bool,
        isOptional: Bool,
        combinedContext: String
    ) -> Int {
        if isOptional { return 4 }
        if isPantryStaple { return 3 }

        switch role.lowercased() {
        case "protein":
            return 0
        case "dairy":
            return 0
        case "sauce":
            return 2
        case "wrapper", "pantry":
            return 1
        case "fresh garnish", "salad base":
            return 0
        case "cooking tool":
            return 5
        default:
            break
        }

        let normalizedName = normalizedIngredientKey(displayName)
        if combinedContext.contains("sauce")
            || combinedContext.contains("dressing")
            || combinedContext.contains("marinade")
            || combinedContext.contains("dip") {
            return 2
        }
        if normalizedName.contains("skewer") || normalizedName.contains("toothpick") {
            return 5
        }
        if normalizedName.contains("rice")
            || normalizedName.contains("flour")
            || normalizedName.contains("sugar")
            || normalizedName.contains("chips")
            || normalizedName.contains("beans")
            || normalizedName.contains("stock")
            || normalizedName.contains("broth") {
            return 1
        }
        if normalizedName.contains("romaine")
            || normalizedName.contains("greens")
            || normalizedName.contains("lettuce")
            || normalizedName.contains("cilantro")
            || normalizedName.contains("green onions")
            || normalizedName.contains("scallions")
            || normalizedName.contains("jalape")
            || normalizedName.contains("garlic")
            || normalizedName.contains("carrot")
            || normalizedName.contains("cucumber")
            || normalizedName.contains("apple")
            || normalizedName.contains("avocado")
            || normalizedName.contains("blueberr")
            || normalizedName.contains("broccoli")
            || normalizedName.contains("tomato") {
            return 0
        }
        if normalizedName.contains("chicken")
            || normalizedName.contains("shrimp")
            || normalizedName.contains("salmon")
            || normalizedName.contains("steak")
            || normalizedName.contains("egg") {
            return 0
        }
        if normalizedName.contains("cheese")
            || normalizedName.contains("yogurt")
            || normalizedName.contains("milk")
            || normalizedName.contains("cream") {
            return 0
        }
        return 0
    }
}
