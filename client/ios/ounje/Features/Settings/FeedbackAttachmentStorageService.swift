import Foundation
import UIKit

/// Uploads feedback attachments (photos + videos) to the private
/// `feedback-attachments` Supabase Storage bucket.
///
/// Path convention: `<userID>/<messageID>/<filename>`. The bucket's RLS policy
/// enforces that the first folder segment matches `auth.uid()`, so a stolen
/// access token cannot read or overwrite another user's attachments.
///
/// For reads, callers can either:
///   • request a short-lived **signed URL** via `signedUrl(for:expiresIn:)`, or
///   • hit `\(SupabaseConfig.url)/storage/v1/object/authenticated/feedback-attachments/<path>`
///     directly with the user's bearer token (RLS-gated SELECT).
enum FeedbackAttachmentStorageError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case uploadFailed(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "Attachment upload request was invalid."
        case .invalidResponse: return "Attachment upload returned an unexpected response."
        case let .uploadFailed(message): return message
        case .unauthorized: return "Sign in again to attach photos to feedback."
        }
    }
}

struct FeedbackUploadedAttachment {
    let storagePath: String
    let fileName: String
    let mimeType: String
    let kind: String
    let width: Int?
    let height: Int?
    let sizeBytes: Int

    var metadata: AppFeedbackMessageAttachment {
        AppFeedbackMessageAttachment(
            fileName: fileName,
            mimeType: mimeType,
            kind: kind,
            storagePath: storagePath,
            width: width,
            height: height,
            sizeBytes: sizeBytes
        )
    }
}

final class FeedbackAttachmentStorageService {
    static let shared = FeedbackAttachmentStorageService()

    private init() {}

    private let bucket = "feedback-attachments"

    /// Uploads a single attachment to storage and returns the canonical path
    /// to embed in the feedback message metadata.
    ///
    /// - Parameters:
    ///   - data: file bytes (already compressed by the caller).
    ///   - userID: authenticated user id; first folder segment in the path.
    ///   - messageID: a UUID the caller mints up-front so all attachments for
    ///     the same feedback message land in the same folder. We do not depend
    ///     on the server's row id because we upload BEFORE the row is inserted.
    ///   - fileName: original file name; preserved for download UX.
    ///   - mimeType: e.g. `image/jpeg`, `video/mp4`.
    ///   - kind: `"image"` | `"video"`.
    ///   - dimensions: optional pixel size for image bubble layout.
    ///   - accessToken: Supabase access token (passed by the caller).
    func upload(
        data: Data,
        userID: String,
        messageID: UUID,
        fileName: String,
        mimeType: String,
        kind: String,
        dimensions: CGSize? = nil,
        accessToken: String
    ) async throws -> FeedbackUploadedAttachment {
        guard !accessToken.isEmpty else {
            throw FeedbackAttachmentStorageError.unauthorized
        }
        let safeName = sanitizedFileName(fileName)
        let path = "\(userID)/\(messageID.uuidString.lowercased())/\(safeName)"
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: pathAllowed),
              let url = URL(string: "\(SupabaseConfig.url)/storage/v1/object/\(bucket)/\(encodedPath)")
        else {
            throw FeedbackAttachmentStorageError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Cache-Control: keep attachments cacheable client-side once fetched.
        request.setValue("max-age=31536000", forHTTPHeaderField: "Cache-Control")
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        // x-upsert allows overwriting if the same path is uploaded twice (rare).
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        request.timeoutInterval = 60
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackAttachmentStorageError.invalidResponse
        }

        guard (200 ... 299).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw FeedbackAttachmentStorageError.unauthorized
            }
            let message = String(data: responseData, encoding: .utf8) ?? "Upload failed (\(http.statusCode))"
            throw FeedbackAttachmentStorageError.uploadFailed(message)
        }

        return FeedbackUploadedAttachment(
            storagePath: path,
            fileName: safeName,
            mimeType: mimeType,
            kind: kind,
            width: dimensions.map { Int($0.width.rounded()) },
            height: dimensions.map { Int($0.height.rounded()) },
            sizeBytes: data.count
        )
    }

    /// Returns the authenticated-read URL for an attachment. The iOS client
    /// pairs this with `Authorization: Bearer <accessToken>` to fetch the
    /// bytes (RLS will reject anyone but the owner).
    func authenticatedReadURL(for storagePath: String) -> URL? {
        guard let encoded = storagePath.addingPercentEncoding(withAllowedCharacters: pathAllowed) else {
            return nil
        }
        return URL(string: "\(SupabaseConfig.url)/storage/v1/object/authenticated/\(bucket)/\(encoded)")
    }

    /// Generates a short-lived signed URL for an attachment. Used when we want
    /// to render the image inside a webview / Apple share sheet that won't be
    /// able to attach a bearer header.
    func signedUrl(
        for storagePath: String,
        expiresIn seconds: Int = 3600,
        accessToken: String
    ) async throws -> URL {
        guard let encoded = storagePath.addingPercentEncoding(withAllowedCharacters: pathAllowed),
              let url = URL(string: "\(SupabaseConfig.url)/storage/v1/object/sign/\(bucket)/\(encoded)")
        else {
            throw FeedbackAttachmentStorageError.invalidRequest
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["expiresIn": seconds])
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200 ... 299).contains(http.statusCode)
        else {
            let message = String(data: data, encoding: .utf8) ?? "Could not generate signed URL"
            throw FeedbackAttachmentStorageError.uploadFailed(message)
        }

        struct SignedResponse: Decodable { let signedURL: String? }
        let decoded = try JSONDecoder().decode(SignedResponse.self, from: data)
        guard let signed = decoded.signedURL,
              let signedURL = URL(string: "\(SupabaseConfig.url)/storage/v1\(signed)") ?? URL(string: signed)
        else {
            throw FeedbackAttachmentStorageError.invalidResponse
        }
        return signedURL
    }

    private var pathAllowed: CharacterSet {
        // URL path segment safe characters. We exclude `/` from `.urlPathAllowed`
        // because we want to keep our own `/` separators (the path is already
        // assembled with valid segments).
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: " ")
        return set
    }

    private func sanitizedFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "attachment-\(UUID().uuidString).bin" }
        // Replace anything that isn't alphanum / dash / dot / underscore.
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
        return trimmed.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
    }
}
