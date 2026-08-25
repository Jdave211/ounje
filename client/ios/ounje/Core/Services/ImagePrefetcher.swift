import Foundation
import ImageIO
import UIKit

actor ImagePrefetcher {
    static let shared = ImagePrefetcher()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 120
        cache.totalCostLimit = 72 * 1_024 * 1_024
    }

    func prefetch(_ urlStrings: [String]) async {
        let uniqueURLs = Array(Set(urlStrings)).filter { !$0.isEmpty }
        for startIndex in stride(from: 0, to: uniqueURLs.count, by: 6) {
            let endIndex = min(startIndex + 6, uniqueURLs.count)
            await withTaskGroup(of: Void.self) { group in
                for urlString in uniqueURLs[startIndex..<endIndex] {
                    group.addTask {
                        _ = await self.image(for: urlString)
                    }
                }
            }
        }
    }

    func cachedImage(for urlString: String) -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    func image(for urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        let cacheKey = url as NSURL
        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }
        if let task = inFlight[urlString] {
            return await task.value
        }

        let task = Task.detached(priority: .utility) { () -> UIImage? in
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse,
                  (200 ... 299).contains(httpResponse.statusCode)
            else { return nil }
            return Self.downsampledImage(from: data, maxPixelSize: 520)
        }
        inFlight[urlString] = task
        let fetchedImage = await task.value
        inFlight[urlString] = nil

        if let fetchedImage {
            let pixelCost = Int(fetchedImage.size.width * fetchedImage.size.height * fetchedImage.scale * fetchedImage.scale * 4)
            cache.setObject(fetchedImage, forKey: cacheKey, cost: pixelCost)
        }
        return fetchedImage
    }

    nonisolated private static func downsampledImage(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: image)
    }
}
