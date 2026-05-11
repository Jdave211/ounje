import SwiftUI
import Foundation

/// Manages the `DiscoverFeedContext` for the current session.
///
/// Weather was previously fetched from Open-Meteo (geocode + forecast) to
/// adjust `sweetTreatBias` and surface "comfort food" or "refreshing" signals.
/// In practice the nudge (±0.04–0.14) was imperceptible to users but added
/// two external HTTP hops on every first Discover open, contributing 0.3–5s
/// of tail latency on slow networks.
///
/// `DiscoverFeedContext.current` already derives `sweetTreatBias` from the
/// local time-of-day and day-of-week, which is a stronger and cheaper signal
/// (Friday evening reliably wants dessert; Tuesday morning doesn't — regardless
/// of cloud cover). We simply apply that plus the user's location for the
/// regional cache-key, with no network call needed.
@MainActor
final class DiscoverEnvironmentViewModel: ObservableObject {
    @Published private(set) var feedContext = DiscoverFeedContext.current
    private var lastKey: String?

    func refresh(profile: UserProfile?) async {
        let address = profile?.deliveryAddress
        let city = address?.city.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let region = address?.region.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let locationLabel = [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
        let key = "\(DiscoverFeedContext.current.windowKey)|\(locationLabel)"
        guard lastKey != key else { return }

        let context = DiscoverFeedContext.current.withLocation(
            locationLabel: locationLabel.isEmpty ? nil : locationLabel,
            regionCode: region.isEmpty ? Locale.current.region?.identifier : region
        )

        feedContext = context
        lastKey = key
    }
}
