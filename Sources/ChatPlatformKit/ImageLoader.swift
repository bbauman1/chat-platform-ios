#if canImport(UIKit)
import ChatPlatformCore
import UIKit

/// Loads and decodes bubble images off the main thread, at display size, with
/// an in-memory cache and one load per image at a time (cells and
/// prefetching share it).
@MainActor
final class ImageLoader {
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let source: () -> ThreadSource?
    private let session: URLSession

    init(source: @escaping () -> ThreadSource?, session: URLSession = .shared) {
        self.source = source
        self.session = session
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func cached(_ ref: ImageRef, size: CGSize) -> UIImage? {
        cache.object(forKey: key(ref, size) as NSString)
    }

    @discardableResult
    func load(_ ref: ImageRef, size: CGSize) -> Task<UIImage?, Never> {
        let key = key(ref, size)
        if let image = cache.object(forKey: key as NSString) { return Task { image } }
        if let task = inFlight[key] { return task }
        let scale = UIScreen.main.scale
        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        let session = self.session
        let source = self.source()
        let task = Task<UIImage?, Never> {
            defer { self.inFlight[key] = nil }
            let data: Data?
            switch ref {
            case .local(let localKey, _, _):
                data = source?.localImageData(localKey)
            case .attachment(let attachment):
                guard let url = try? await source?.imageURL(for: attachment) else { return nil }
                data = try? await session.data(from: url).0
            }
            guard let data else { return nil }
            let image = await Self.decode(data, pixels: pixels)
            if let image {
                let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
                self.cache.setObject(image, forKey: key as NSString, cost: cost)
            }
            return image
        }
        inFlight[key] = task
        return task
    }

    func cancel(_ ref: ImageRef, size: CGSize) {
        let key = key(ref, size)
        inFlight[key]?.cancel()
        inFlight[key] = nil
    }

    /// Decodes and downsamples on a background thread.
    nonisolated static func decode(_ data: Data, pixels: CGSize) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else { return nil }
            let fit = min(1, pixels.width / max(image.size.width, 1), pixels.height / max(image.size.height, 1))
            let target = CGSize(
                width: max(1, (image.size.width * fit).rounded()),
                height: max(1, (image.size.height * fit).rounded()))
            return await image.byPreparingThumbnail(ofSize: target) ?? image.preparingForDisplay()
        }.value
    }

    private func key(_ ref: ImageRef, _ size: CGSize) -> String {
        "\(ref.cacheKey)@\(Int(size.width))x\(Int(size.height))"
    }
}

/// Turns a picked photo into an upload: at most 2000 px on the long side
/// (the server's own limit) and JPEG under the server's 3 MiB limit. Lowers
/// the quality, then the size, until a detailed photo fits.
enum PhotoEncoder {
    static let maxBytes = 3 * 1024 * 1024
    static let qualities: [CGFloat] = [0.85, 0.7, 0.55, 0.4]

    static func upload(from image: UIImage) async -> ImageUpload? {
        await Task.detached(priority: .userInitiated) {
            let longest = max(image.size.width * image.scale, image.size.height * image.scale)
            var side = min(longest, 2000)
            while true {
                let fit = side / max(longest, 1)
                let size = CGSize(
                    width: max(1, (image.size.width * image.scale * fit).rounded()),
                    height: max(1, (image.size.height * image.scale * fit).rounded()))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                if let data = encode(resized, maxBytes: maxBytes) {
                    return ImageUpload(data: data, width: Int(size.width), height: Int(size.height))
                }
                // Shrink until it fits, but not below 200 px.
                if side <= 200 { return nil }
                side = max(200, (side * 0.75).rounded())
            }
        }.value
    }

    /// The highest listed quality whose JPEG fits in `maxBytes`, or nil.
    static func encode(_ image: UIImage, maxBytes: Int) -> Data? {
        for quality in qualities {
            guard let data = image.jpegData(compressionQuality: quality) else { return nil }
            if data.count <= maxBytes { return data }
        }
        return nil
    }
}
#endif
