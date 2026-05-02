import Foundation

enum BackendEndpoint {
    static var primaryBaseURL: String { OunjeDevelopmentServer.primaryBaseURL }
    static var workerBaseURL: String { OunjeDevelopmentServer.workerBaseURL }
    static var candidateBaseURLs: [String] { OunjeDevelopmentServer.candidateBaseURLs }
    static var workerCandidateBaseURLs: [String] { OunjeDevelopmentServer.workerCandidateBaseURLs }
}
