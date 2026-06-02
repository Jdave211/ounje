import Foundation

enum OunjeLaunchFlags {
    static let paywallsEnabled = true
    static var forceOnboardingIncomplete: Bool {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["OUNJE_FORCE_ONBOARDING_INCOMPLETE"] == "1"
#else
        false
#endif
    }

    static var usesSimulatorBillingBypass: Bool {
#if DEBUG && targetEnvironment(simulator)
        // Always bypass on simulator — StoreKit purchases require a real Apple ID
        // in Simulator Settings and a matching StoreKit config, neither of which
        // is available in normal dev/testing. The env-var opt-out lets you force
        // the paywall if you're specifically testing it.
        ProcessInfo.processInfo.environment["OUNJE_SIMULATOR_BILLING_BYPASS"] != "0"
#else
        false
#endif
    }

    static var allowsLocalOnlyAuthFallback: Bool {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["OUNJE_ALLOW_LOCAL_AUTH_FALLBACK"] != "0"
#elseif DEBUG
        ProcessInfo.processInfo.environment["OUNJE_ALLOW_LOCAL_AUTH_FALLBACK"] == "1"
#else
        false
#endif
    }
}

enum OunjeDevelopmentServer {
    static let productionBaseURL = "https://ounje-idbl.onrender.com"

    static var baseURL: String {
        explicitPrimaryBaseURL ?? productionBaseURL
    }

    static var candidateBaseURLs: [String] {
        deduplicated(
            [
                explicitPrimaryBaseURL,
                productionBaseURL
            ].compactMap { $0 }
        )
    }

    static var primaryBaseURL: String {
        explicitPrimaryBaseURL ?? productionBaseURL
    }

    static var workerBaseURL: String {
        explicitWorkerBaseURL ?? explicitPrimaryBaseURL ?? productionBaseURL
    }

    static var interactiveCandidateBaseURLs: [String] {
        candidateBaseURLs
    }

    static var workerCandidateBaseURLs: [String] {
        deduplicated(
            [
                explicitWorkerBaseURL,
                explicitPrimaryBaseURL,
                productionBaseURL
            ].compactMap { $0 }
        )
    }

    private static var explicitPrimaryBaseURL: String? {
#if DEBUG
        explicitBaseURL(hostKey: "OunjePrimaryServerHost", portKey: "OunjePrimaryServerPort", defaultPort: "8080")
#else
        nil
#endif
    }

    private static var explicitWorkerBaseURL: String? {
#if DEBUG
        explicitBaseURL(hostKey: "OunjeWorkerServerHost", portKey: "OunjeWorkerServerPort", defaultPort: "80")
            ?? explicitBaseURL(hostKey: "OunjeDevServerHost", portKey: "OunjeDevServerPort", defaultPort: "80")
#else
        nil
#endif
    }

    private static func explicitBaseURL(hostKey: String, portKey: String, defaultPort: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        let rawHost = environment[hostKey] ?? (Bundle.main.object(forInfoDictionaryKey: hostKey) as? String)

        let host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else { return nil }

        let configuredPort = (environment[portKey] ?? (Bundle.main.object(forInfoDictionaryKey: portKey) as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = (configuredPort?.isEmpty == false ? configuredPort! : defaultPort)

        if host.contains("://") {
            guard var components = URLComponents(string: host) else {
                return host
            }
            if components.port == nil, !port.isEmpty {
                components.port = Int(port)
            }
            return components.string ?? host
        }

        return "http://\(host):\(port)"
    }

    private static func deduplicated(_ baseURLs: [String]) -> [String] {
        var uniqueBaseURLs: [String] = []
        for baseURL in baseURLs where !uniqueBaseURLs.contains(baseURL) {
            uniqueBaseURLs.append(baseURL)
        }
        return uniqueBaseURLs
    }
}

private enum DiscoverAPIConfig {
    static let baseURL = OunjeDevelopmentServer.baseURL
}
