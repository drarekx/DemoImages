import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Videos live in albums next to images: same `ImageItem`, with a duration. Reading,
// thumbnails and encoding go through AVFoundation, so only what macOS can decode
// (MP4, MOV, M4V…) is accepted.

/// Reads video files: type check, size and duration, single frames.
enum VideoFile {
    struct Info {
        let width: Int
        let height: Int
        let duration: Double
        let typeID: String
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    /// Display size (rotation applied) and duration, or nil if AVFoundation can't read the file.
    static func info(_ url: URL) async -> Info? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let width = Int(abs(rect.width).rounded()), height = Int(abs(rect.height).rounded())
        guard width > 0, height > 0, duration.seconds.isFinite else { return nil }
        let typeID = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.movie.identifier
        return Info(width: width, height: height, duration: max(0, duration.seconds), typeID: typeID)
    }

    /// `info` for the library's synchronous file operations. Reads the header only.
    static func infoBlocking(_ url: URL) -> Info? {
        final class Box: @unchecked Sendable { var info: Info? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            box.info = await info(url)
            done.signal()
        }
        done.wait()
        return box.info
    }

    /// A frame near the start (not the very first one, which is often black). `exact`
    /// asks for that precise frame, so two encodings of a video can be compared.
    static func frame(_ url: URL, maxPixel: Int? = nil, exact: Bool = false) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        if let maxPixel { generator.maximumSize = CGSize(width: maxPixel, height: maxPixel) }
        if exact {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let seconds = duration.isFinite ? min(1, max(0, duration * 0.1)) : 0
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let image = try? await generator.image(at: time).image else { return nil }
        // A bitmap rep keeps the frame's real pixel size (NSImage(cgImage:) reports it
        // doubled on Retina screens), which the comparison's 1:1 zoom relies on.
        let rep = NSBitmapImageRep(cgImage: image)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}

/// Full-size picture of a library file: the image itself, or a frame of a video.
enum MediaImage {
    static func load(_ url: URL) async -> NSImage? {
        if VideoFile.isVideo(url) { return await VideoFile.frame(url, exact: true) }
        return await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
    }
}

extension Format {
    /// "0:07", "12:34", "1:02:03"
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}

// MARK: - Optimizing

enum VideoCodec: String, CaseIterable, Identifiable, Codable {
    case hevc, h264

    var id: String { rawValue }
    var title: String { self == .hevc ? "HEVC" : "H.264" }
    var fileExtension: String { "mp4" }
}

/// Output size. macOS's export presets pick the bitrate for each one and never upscale.
enum VideoSize: String, CaseIterable, Identifiable, Codable {
    case original, p2160, p1080, p720, p540

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return tr("Original")
        case .p2160: return "4K"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p540: return "540p"
        }
    }

    /// The `AVAssetExportSession` preset, or nil if macOS has none for this pair.
    func preset(for codec: VideoCodec) -> String? {
        switch (codec, self) {
        case (.hevc, .original): return AVAssetExportPresetHEVCHighestQuality
        case (.hevc, .p2160): return AVAssetExportPresetHEVC3840x2160
        case (.hevc, .p1080): return AVAssetExportPresetHEVC1920x1080
        case (.hevc, .p720), (.hevc, .p540): return nil
        case (.h264, .original): return AVAssetExportPresetHighestQuality
        case (.h264, .p2160): return AVAssetExportPreset3840x2160
        case (.h264, .p1080): return AVAssetExportPreset1920x1080
        case (.h264, .p720): return AVAssetExportPreset1280x720
        case (.h264, .p540): return AVAssetExportPreset960x540
        }
    }

    static func available(for codec: VideoCodec) -> [VideoSize] {
        allCases.filter { $0.preset(for: codec) != nil }
    }
}

struct VideoOptions: Codable, Equatable {
    var codec: VideoCodec = .hevc
    var size: VideoSize = .p1080
    var destination: OptimizeDestination = .copyInAlbum
    var onlyIfSmaller = true

    mutating func selectCodec(_ codec: VideoCodec) {
        self.codec = codec
        if size.preset(for: codec) == nil { size = .p1080 }
    }

    /// Settings that change the encoded bytes (destination doesn't).
    var encodingKey: String { "video|\(codec.rawValue)|\(size.rawValue)" }
}

enum VideoEncoder {
    enum EncodeError: LocalizedError {
        case unreadable, unsupported
        var errorDescription: String? {
            switch self {
            case .unreadable: return tr("No se pudo leer el vídeo.")
            case .unsupported: return tr("Este vídeo no se puede exportar con esos ajustes.")
            }
        }
    }

    /// Re-encodes `source` into `directory/<name>.mp4` and returns the file.
    static func encode(_ source: URL, options: VideoOptions, in directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Library.requestDownload(source)
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isExportable)) == true else { throw EncodeError.unreadable }
        guard let preset = options.size.preset(for: options.codec),
              let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw EncodeError.unsupported
        }
        let name = source.deletingPathExtension().lastPathComponent
        let output = directory.appendingPathComponent(name).appendingPathExtension(options.codec.fileExtension)
        try? FileManager.default.removeItem(at: output)
        session.outputURL = output
        session.outputFileType = .mp4
        // Metadata first, so the video starts playing before it has fully downloaded.
        session.shouldOptimizeForNetworkUse = true

        // The session isn't Sendable, but cancelExport() may be called from any thread.
        struct Handle: @unchecked Sendable { let session: AVAssetExportSession }
        let handle = Handle(session: session)
        await withTaskCancellationHandler {
            await handle.session.export()
        } onCancel: {
            handle.session.cancelExport()
        }
        try Task.checkCancellation()
        guard session.status == .completed, FileManager.default.fileExists(atPath: output.path) else {
            throw session.error ?? EncodeError.unsupported
        }
        return output
    }
}

// MARK: - Player

/// AVKit player with its own controls. It never takes keyboard focus, so the viewer's
/// keys (arrows, Esc, Space) keep working.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = PassivePlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    private final class PassivePlayerView: AVPlayerView {
        override var acceptsFirstResponder: Bool { false }
    }
}
