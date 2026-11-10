import AppKit
import ImageIO
import SwiftUI

/// Decoded thumbnails, kept in memory. Decoding runs on a small background queue.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init() { cache.countLimit = 1500 }

    private func key(_ url: URL, _ maxPixel: Int) -> NSString { "\(maxPixel)|\(url.path)" as NSString }

    func cached(_ url: URL, maxPixel: Int) -> NSImage? { cache.object(forKey: key(url, maxPixel)) }

    func thumbnail(for url: URL, maxPixel: Int) async -> NSImage? {
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        let image: NSImage?
        if VideoFile.isVideo(url) {
            Library.requestDownload(url)
            image = await VideoFile.frame(url, maxPixel: maxPixel)
        } else {
            image = await withCheckedContinuation { continuation in
                queue.addOperation {
                    continuation.resume(returning: Self.decode(url, maxPixel: maxPixel))
                }
            }
        }
        if let image { cache.setObject(image, forKey: key(url, maxPixel)) }
        return image
    }

    /// Forget a file whose contents changed or that moved.
    func invalidate(_ url: URL) {
        for size in [ThumbnailSize.grid, ThumbnailSize.small] {
            cache.removeObject(forKey: key(url, size))
        }
    }

    private static func decode(_ url: URL, maxPixel: Int) -> NSImage? {
        Library.requestDownload(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

enum ThumbnailSize {
    /// Enough for the largest grid tile on a Retina screen.
    static let grid = 640
    static let small = 120
}

/// Thumbnail of an image or a video frame, aspect-fit, decoded in the background.
struct Thumbnail: View {
    let url: URL
    var maxPixel = ThumbnailSize.grid
    /// Changes when the file is replaced, so the view reloads.
    var version: Int64 = 0

    @State private var image: NSImage?
    @State private var waiting = false

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if waiting {
                // The file isn't here yet (still coming from iCloud) or was deleted.
                VStack(spacing: 6) {
                    Image(systemName: Library.isInICloud(url) ? "icloud.and.arrow.down" : "questionmark.square.dashed")
                        .font(.system(size: 22))
                    Text(Library.isInICloud(url) ? tr("Esperando a iCloud") : tr("No se encuentra el archivo"))
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Theme.text3)
                .padding(6)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(url.path)|\(version)") {
            image = ThumbnailCache.shared.cached(url, maxPixel: maxPixel)
            waiting = false
            // Retry for a while: iCloud may deliver the file after the library index.
            var attempt = 0
            while image == nil && !Task.isCancelled {
                image = await ThumbnailCache.shared.thumbnail(for: url, maxPixel: maxPixel)
                guard image == nil else { break }
                waiting = true
                attempt += 1
                guard Library.isInICloud(url), attempt < 100 else { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

/// Grey checkerboard that shows transparency behind images.
struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x1E1E21)))
            let columns = Int(ceil(size.width / square)), rows = Int(ceil(size.height / square))
            var path = Path()
            for row in 0..<rows {
                for column in 0..<columns where (row + column) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(path, with: .color(Color(hex: 0x27272B)))
        }
    }
}
