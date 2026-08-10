import ImageIO
import SwiftUI

struct CachedPosterImage<Placeholder: View>: View {
    let url: URL
    let contentMode: ContentMode
    let maxPixelSize: Int
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(
        url: URL,
        contentMode: ContentMode,
        maxPixelSize: Int = 360,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.contentMode = contentMode
        self.maxPixelSize = maxPixelSize
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: "\(url.absoluteString):\(maxPixelSize)") {
            image = await PosterImageLoader.shared.image(
                for: url,
                maxPixelSize: maxPixelSize
            )
        }
    }
}

actor PosterImageLoader {
    static let shared = PosterImageLoader()

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.urlCache = URLCache(
            memoryCapacity: 0,
            diskCapacity: 32 * 1_024 * 1_024
        )
        return URLSession(configuration: configuration)
    }()
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()
    private var requests: [String: Task<UIImage?, Never>] = [:]
    private var failedUntil: [String: Date] = [:]

    func releaseMemory() {
        cache.removeAllObjects()
        requests.values.forEach { $0.cancel() }
        requests.removeAll(keepingCapacity: false)
        failedUntil.removeAll(keepingCapacity: false)
    }

    func image(for url: URL, maxPixelSize: Int) async -> UIImage? {
        let targetSize = max(120, min(maxPixelSize, 480))
        let key = "\(url.absoluteString):\(targetSize)"
        if let cached = cache.object(forKey: key as NSString) { return cached }
        if let retryDate = failedUntil[key], retryDate > .now { return nil }
        failedUntil[key] = nil
        if let request = requests[key] { return await request.value }

        let session = self.session
        let requestURL = Self.optimizedURL(url, maxPixelSize: targetSize)
        let request = Task {
            await Self.download(
                requestURL,
                maxPixelSize: targetSize,
                session: session
            )
        }
        requests[key] = request
        let image = await request.value
        requests[key] = nil

        if let image {
            let cost = (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)
            cache.setObject(image, forKey: key as NSString, cost: cost)
        } else {
            failedUntil = failedUntil.filter { $0.value > .now }
            if failedUntil.count >= 100,
               let earliest = failedUntil.min(by: { $0.value < $1.value })?.key {
                failedUntil.removeValue(forKey: earliest)
            }
            failedUntil[key] = Date.now.addingTimeInterval(5 * 60)
        }
        return image
    }

    private static func download(
        _ url: URL,
        maxPixelSize: Int,
        session: URLSession
    ) async -> UIImage? {
        for attempt in 0..<2 {
            do {
                var request = URLRequest(
                    url: url,
                    cachePolicy: .returnCacheDataElseLoad,
                    timeoutInterval: 20
                )
                request.setValue("image/*", forHTTPHeaderField: "Accept")
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      200..<300 ~= http.statusCode else { return nil }
                return downsample(data, maxPixelSize: maxPixelSize)
            } catch is CancellationError {
                return nil
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(600))
                }
            }
        }
        return nil
    }

    private static func downsample(_ data: Data, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceShouldCache: false
              ] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
              ] as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    private static func optimizedURL(_ url: URL, maxPixelSize: Int) -> URL {
        guard url.host == "image.tmdb.org" else { return url }
        let width = maxPixelSize <= 220 ? "w185" : maxPixelSize <= 360 ? "w342" : "w500"
        let path = url.path.replacingOccurrences(
            of: #"/t/p/w\d+"#,
            with: "/t/p/\(width)",
            options: .regularExpression
        )
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = path
        return components?.url ?? url
    }
}
