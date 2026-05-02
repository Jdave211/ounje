import SwiftUI
import Foundation

private struct DiscoverWeatherSnapshot {
    let summary: String
    let mood: String
    let temperatureBand: String
    let sweetTreatBias: Double
}

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
        if lastKey == key { return }

        var context = DiscoverFeedContext.current.withLocation(
            locationLabel: locationLabel.isEmpty ? nil : locationLabel,
            regionCode: region.isEmpty ? Locale.current.region?.identifier : region
        )

        if !city.isEmpty, let snapshot = try? await DiscoverWeatherService.shared.fetchWeather(city: city, region: region) {
            context = context.withWeather(
                summary: snapshot.summary,
                mood: snapshot.mood,
                temperatureBand: snapshot.temperatureBand,
                sweetTreatBias: snapshot.sweetTreatBias
            )
        }

        feedContext = context
        lastKey = key
    }
}

private actor DiscoverWeatherService {
    static let shared = DiscoverWeatherService()
    private var cache: [String: (timestamp: Date, snapshot: DiscoverWeatherSnapshot)] = [:]

    func fetchWeather(city: String, region: String) async throws -> DiscoverWeatherSnapshot {
        let key = "\(city.lowercased())|\(region.lowercased())"
        if let cached = cache[key], Date().timeIntervalSince(cached.timestamp) < 3600 {
            return cached.snapshot
        }

        let query = [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
        guard let geocodeURL = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&count=1&language=en&format=json") else {
            throw URLError(.badURL)
        }

        let (geoData, _) = try await URLSession.shared.data(from: geocodeURL)
        let geocode = try JSONDecoder().decode(DiscoverWeatherGeocodeResponse.self, from: geoData)
        guard let result = geocode.results?.first else {
            throw URLError(.resourceUnavailable)
        }

        guard let weatherURL = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(result.latitude)&longitude=\(result.longitude)&current=temperature_2m,weather_code,cloud_cover,precipitation&temperature_unit=celsius") else {
            throw URLError(.badURL)
        }

        let (weatherData, _) = try await URLSession.shared.data(from: weatherURL)
        let weather = try JSONDecoder().decode(DiscoverWeatherForecastResponse.self, from: weatherData)

        let temperatureBand: String
        switch weather.current.temperature2m {
        case ..<4:
            temperatureBand = "cold"
        case 4..<14:
            temperatureBand = "cool"
        case 14..<24:
            temperatureBand = "mild"
        default:
            temperatureBand = "hot"
        }

        let mood: String
        switch weather.current.weatherCode {
        case 51...67, 80...99:
            mood = "rainy"
        case 71...77, 85...86:
            mood = "snowy"
        case 0, 1:
            mood = "sunny"
        case 2, 3, 45, 48:
            mood = "cloudy"
        default:
            mood = "mild"
        }

        var sweetTreatBias = DiscoverFeedContext.current.sweetTreatBias
        if mood == "sunny" && temperatureBand == "hot" { sweetTreatBias += 0.14 }
        if mood == "rainy" || mood == "snowy" { sweetTreatBias += 0.06 }
        if temperatureBand == "cold" { sweetTreatBias -= 0.04 }
        sweetTreatBias = min(max(sweetTreatBias, 0.05), 0.8)

        let snapshot = DiscoverWeatherSnapshot(
            summary: "\(temperatureBand)-\(mood)",
            mood: mood,
            temperatureBand: temperatureBand,
            sweetTreatBias: sweetTreatBias
        )
        cache[key] = (Date(), snapshot)
        return snapshot
    }
}

private struct DiscoverWeatherGeocodeResponse: Decodable {
    let results: [DiscoverWeatherGeocodeResult]?
}

private struct DiscoverWeatherGeocodeResult: Decodable {
    let latitude: Double
    let longitude: Double
}

private struct DiscoverWeatherForecastResponse: Decodable {
    let current: DiscoverWeatherCurrent
}

private struct DiscoverWeatherCurrent: Decodable {
    let temperature2m: Double
    let weatherCode: Int

    enum CodingKeys: String, CodingKey {
        case temperature2m = "temperature_2m"
        case weatherCode = "weather_code"
    }
}
