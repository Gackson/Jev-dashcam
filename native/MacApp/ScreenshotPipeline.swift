import Foundation
import ImageIO

/// ImageIO work stays on this actor's serial executor, never the UI actor.
/// Separate caches keep a large preview from evicting all card thumbnails.
actor ScreenshotPipeline {
    static let shared = ScreenshotPipeline()
    private let thumbnails = NSCache<NSString, CGImage>()
    private let details = NSCache<NSString, CGImage>()
    private let originals = NSCache<NSString, CGImage>()
    private(set) var decodeCount = 0
    init() {
        thumbnails.totalCostLimit = 32 * 1024 * 1024
        details.totalCostLimit = 48 * 1024 * 1024
        originals.totalCostLimit = 96 * 1024 * 1024
    }
    func image(directory: URL, filename: String, maxPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled,
              filename.range(of: "^[a-f0-9-]+\\.jpg$", options: .regularExpression) != nil else { return nil }
        let url = directory.appendingPathComponent("screenshots").appendingPathComponent(filename)
        let key = "\(url.path):\(maxPixelSize)" as NSString
        let cache = maxPixelSize <= 640 ? thumbnails : maxPixelSize <= 1920 ? details : originals
        if let cached = cache.object(forKey: key) { return cached }
        // A regression must fail loudly in tests instead of silently blocking the UI.
        precondition(!Thread.isMainThread, "Screenshot decoding must run off the main thread")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        decodeCount += 1
        cache.setObject(decoded, forKey: key, cost: decoded.bytesPerRow * decoded.height)
        return decoded
    }
}
