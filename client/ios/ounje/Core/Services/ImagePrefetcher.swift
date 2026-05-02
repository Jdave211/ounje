import Foundation
import UIKit

actor ImagePrefetcher {
    static let shared = ImagePrefetcher()

    private let cache = NSCache<NSURL, UIImage>()

    func prefetch(_ urlStrings: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for urlString in urlStrings {
                group.addTask { [cache] in
                    guard let url = URL(string: urlString), cache.object(forKey: url as NSURL) == nil else {
                        return
                    }
                    guard let (data, _) = try? await URLSession.shared.data(from: url),
                          let image = UIImage(data: data) else {
                        return
                    }
                    cache.setObject(image, forKey: url as NSURL)
                }
            }
        }
    }

    func cachedImage(for urlString: String) -> UIImage? {
        guard let url = URL(string: urlString) else { return nil }
        return cache.object(forKey: url as NSURL)
    }
}
