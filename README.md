# Ounje (Swift Native Pivot)

Ounje is now a **SwiftUI-first, fully agentic meal planning app**.

The iOS app lives in `/client/ios/ounje` and runs a native planning pipeline:

1. User onboarding captures cuisines, cadence (weekly / biweekly / monthly), storage, consumption, and provider preferences.
2. The planning agent curates recipes from the in-app recipe database.
3. Rotation strategy is applied:
   - `Dynamic`: maximize variety and avoid immediate repeats.
   - `Stable`: preserve favorites and rotate a smaller subset.
4. Ingredient requirements are aggregated and pantry staples are subtracted.
5. Providers (Walmart / Instacart / Amazon Fresh) are scored for best total + speed.
6. The app outputs a plan, grocery list, and provider checkout links.

## Key Native Files

- `/client/ios/ounje/OunjeAgenticApp.swift`
- `/client/ios/ounje/MealPlanningAppStore.swift`
- `/client/ios/ounje/MealPlanningAgent.swift`
- `/client/ios/ounje/MealPlanningModels.swift`
- `/client/ios/ounje/RecipeCatalog.swift`

## Build

```bash
cd client/ios
xcodebuild -project ounje.xcodeproj -scheme ounje -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
