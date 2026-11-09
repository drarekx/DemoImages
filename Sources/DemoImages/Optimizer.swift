import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Encoder settings follow Squoosh (squoosh.app, analysed with REA from its
// Compress chunk): same codecs, same defaults, same resize pipeline (Lanczos3 in
// linear RGB with premultiplied alpha) and the same palette reduction (libimagequant).

/// Output formats.
enum Codec: String, CaseIterable, Identifiable, Codable {
    case webp, avif, jxl, jpeg, png, heic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .webp: return "WebP"
        case .avif: return "AVIF"
        case .jxl: return "JPEG XL"
        case .jpeg: return ExternalTool.mozjpeg.isInstalled ? "MozJPEG" : "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        }
    }

    var fileExtension: String {
        switch self {
        case .webp: return "webp"
        case .avif: return "avif"
        case .jxl: return "jxl"
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        }
    }

    var supportsLossless: Bool { [.webp, .avif, .jxl].contains(self) }
    var usesQuality: Bool { self != .png }

    /// Squoosh defaults: WebP/JXL/MozJPEG 75, AVIF 50.
    var defaultQuality: Double { self == .avif ? 50 : 75 }

    /// Effort (slower = smaller). nil when the encoder has no such setting.
    var effortRange: ClosedRange<Int>? {
        switch self {
        case .webp: return 0...6       // cwebp -m (lossy) / -z (lossless)
        case .avif: return 0...10      // avifenc speed = 10 - effort
        case .jxl: return 1...9        // cjxl -e
        case .png: return ExternalTool.oxipng.isInstalled ? 0...6 : nil  // oxipng -o
        case .jpeg, .heic: return nil
        }
    }

    var defaultEffort: Int {
        switch self {
        case .webp: return 4
        case .avif: return 4
        case .jxl: return 7
        case .png: return 2
        case .jpeg, .heic: return 0
        }
    }

    /// The tool this format needs, or nil if ImageIO can write it on its own.
    var requiredTool: ExternalTool? {
        switch self {
        case .webp: return .cwebp
        case .jxl: return .cjxl
        case .avif: return Self.imageIOCanWrite(.avifImage) ? nil : .avifenc
        case .jpeg, .png, .heic: return nil
        }
    }

    /// Optional tool that makes the result better or adds settings.
    var enhancingTool: ExternalTool? {
        switch self {
        case .avif: return .avifenc
        case .jpeg: return .mozjpeg
        case .png: return .oxipng
        default: return nil
        }
    }

    var isAvailable: Bool { requiredTool?.isInstalled ?? true }

    static func imageIOCanWrite(_ type: UTType) -> Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(type.identifier)
    }
}

enum OptimizeDestination: String, Codable, CaseIterable {
    /// Add the optimized file next to the original, in the same album.
    case copyInAlbum
    /// Swap the original for the optimized file (the original goes to the Trash).
    case replace
    /// Write the optimized files to a folder outside the library.
    case exportFolder
}

struct OptimizeOptions: Codable, Equatable {
    var codec: Codec = .webp
    var quality: Double = 75
    var effort: Int = 4
    var lossless = false
    var resize = false
    /// 0 = no limit.
    var maxWidth = 1920
    var maxHeight = 0
    /// PNG only: reduce to a palette with pngquant (Squoosh's "Reduce palette").
    var quantize = false
    var colors = 256
    var dither = 1.0
    var destination: OptimizeDestination = .copyInAlbum
    var onlyIfSmaller = true

    mutating func selectCodec(_ codec: Codec) {
        self.codec = codec
        quality = codec.defaultQuality
        effort = codec.defaultEffort
        if !codec.supportsLossless { lossless = false }
    }

    /// Settings that change the encoded bytes (destination doesn't).
    var encodingKey: String {
        "\(codec.rawValue)|\(Int(quality))|\(effort)|\(lossless)|\(resize)|\(maxWidth)|\(maxHeight)|\(quantize)|\(colors)|\(dither)"
    }
}

// MARK: - Encoder

enum ImageEncoder {
    enum EncodeError: LocalizedError {
        case unreadable, writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return tr("No se pudo leer la imagen.")
            case .writeFailed(let format): return tr("No se pudo escribir %@.", format)
            }
        }
    }

    /// Encodes `source` into `directory/<name>.<ext>` and returns the file.
    static func encode(_ source: URL, options: OptimizeOptions, in directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var image = try loadImage(source)
        if options.resize {
            image = resize(image, maxWidth: options.maxWidth, maxHeight: options.maxHeight)
        }
        try Task.checkCancellation()

        let codec = options.codec
        let name = source.deletingPathExtension().lastPathComponent
        let output = directory.appendingPathComponent(name).appendingPathExtension(codec.fileExtension)
        let input = directory.appendingPathComponent("input.png")
        let quality = String(Int(options.quality.rounded()))

        switch codec {
        case .webp:
            try write(image, as: .png, to: input)
            var args = options.lossless
                ? ["-lossless", "-z", "\(options.effort)", "-exact"]
                : ["-q", quality, "-m", "\(options.effort)", "-sns", "50", "-f", "60"]
            args += ["-mt", "-metadata", "none", input.path, "-o", output.path]
            try await ToolProcess.run(.cwebp, args)

        case .avif:
            if ExternalTool.avifenc.isInstalled {
                try write(image, as: .png, to: input)
                var args = ["-j", "all", "-s", "\(10 - options.effort)"]
                args += options.lossless ? ["-l"] : ["-q", quality, "-y", "420"]
                args += [input.path, output.path]
                try await ToolProcess.run(.avifenc, args)
            } else {
                try write(image, as: .avifImage, quality: options.lossless ? 1 : options.quality / 100, to: output)
            }

        case .jxl:
            try write(image, as: .png, to: input)
            var args = [input.path, output.path, "-e", "\(options.effort)"]
            args += options.lossless ? ["-d", "0"] : ["-q", quality]
            try await ToolProcess.run(.cjxl, args)

        case .jpeg:
            let flat = flatten(image)
            if ExternalTool.mozjpeg.isInstalled {
                let ppm = directory.appendingPathComponent("input.ppm")
                try writePPM(flat, to: ppm)
                try await ToolProcess.run(.mozjpeg, ["-quality", quality, "-optimize", "-progressive",
                                                     "-sample", "2x2", "-outfile", output.path, ppm.path])
            } else {
                try write(flat, as: .jpeg, quality: options.quality / 100, to: output)
            }

        case .png:
            var current = input
            try write(image, as: .png, to: current)
            if options.quantize {
                let quantized = directory.appendingPathComponent("quantized.png")
                try await ToolProcess.run(.pngquant, ["--force", "--strip", "--speed", "4",
                                                      "--floyd=\(String(format: "%.2f", options.dither))",
                                                      "--output", quantized.path, "\(max(2, min(256, options.colors)))",
                                                      current.path])
                current = quantized
            }
            if ExternalTool.oxipng.isInstalled {
                try await ToolProcess.run(.oxipng, ["-o", "\(options.effort)", "--strip", "safe",
                                                    "--out", output.path, current.path])
            } else {
                try FileManager.default.copyItem(at: current, to: output)
            }

        case .heic:
            try write(image, as: .heic, quality: options.quality / 100, to: output)
        }

        for temp in ["input.png", "input.ppm", "quantized.png"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(temp))
        }
        guard FileManager.default.fileExists(atPath: output.path) else { throw EncodeError.writeFailed(codec.title) }
        return output
    }

    /// Full-size decode with EXIF orientation applied; metadata is dropped.
    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { throw EncodeError.unreadable }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw EncodeError.unreadable
        }
        return image
    }

    /// Lanczos downscale to fit `maxWidth` × `maxHeight` (0 = unlimited). Never upscales.
    /// Core Image works in linear light with premultiplied alpha, like Squoosh's defaults.
    static func resize(_ image: CGImage, maxWidth: Int, maxHeight: Int) -> CGImage {
        let width = Double(image.width), height = Double(image.height)
        var scale = 1.0
        if maxWidth > 0 { scale = min(scale, Double(maxWidth) / width) }
        if maxHeight > 0 { scale = min(scale, Double(maxHeight) / height) }
        guard scale < 1 else { return image }

        let filter = CIFilter.lanczosScaleTransform()
        // Clamp so the kernel doesn't pull transparent pixels in at the edges.
        filter.inputImage = CIImage(cgImage: image).clampedToExtent()
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        let rect = CGRect(x: 0, y: 0,
                          width: max(1, (width * scale).rounded()),
                          height: max(1, (height * scale).rounded()))
        guard let output = filter.outputImage?.cropped(to: rect) else { return image }
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        return context.createCGImage(output, from: rect, format: .RGBA8,
                                     colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) ?? image
    }

    /// Composites over white (JPEG has no alpha).
    static func flatten(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    static func write(_ image: CGImage, as type: UTType, quality: Double? = nil, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw EncodeError.writeFailed(type.preferredFilenameExtension?.uppercased() ?? type.identifier)
        }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw EncodeError.writeFailed(type.preferredFilenameExtension?.uppercased() ?? type.identifier)
        }
    }

    /// Binary PPM (P6) in sRGB: the one input every cjpeg build reads.
    static func writePPM(_ image: CGImage, to url: URL) throws {
        let width = image.width, height = image.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw EncodeError.writeFailed("PPM") }
        var data = Data("P6\n\(width) \(height)\n255\n".utf8)
        data.reserveCapacity(data.count + width * height * 3)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = rgba[pixel * 4]
            rgb[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        data.append(contentsOf: rgb)
        try data.write(to: url)
    }
}

// MARK: - Batch runner

struct OptimizeResult: Identifiable {
    enum Status { case pending, running, done, failed }

    let item: ImageItem
    let source: URL
    var status: Status = .pending
    var output: URL?
    var outputBytes: Int64?
    var error: String?

    var id: UUID { item.id }

    var isSmaller: Bool { (outputBytes ?? .max) < item.bytes }
}

/// Encodes a batch into a temp folder so the user can compare before saving anything.
@MainActor
final class OptimizeRunner: ObservableObject {
    @Published private(set) var results: [OptimizeResult] = []
    @Published private(set) var running = false
    @Published private(set) var encodedKey: String?

    private var task: Task<Void, Never>?
    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(AppInfo.name)-\(UUID().uuidString)", isDirectory: true)

    var finished: Int { results.filter { $0.status == .done || $0.status == .failed }.count }
    var totalBefore: Int64 { results.reduce(0) { $0 + $1.item.bytes } }
    var totalAfter: Int64 { results.reduce(0) { $0 + ($1.outputBytes ?? $1.item.bytes) } }

    func start(_ items: [(ImageItem, URL)], options: OptimizeOptions) {
        cancel()
        try? FileManager.default.removeItem(at: workDirectory)
        results = items.map { OptimizeResult(item: $0.0, source: $0.1) }
        encodedKey = options.encodingKey
        running = true
        let jobs = results.enumerated().map { ($0.offset, $0.element.source, $0.element.id) }
        let base = workDirectory
        let limit = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))

        task = Task { [weak self] in
            await withTaskGroup(of: (Int, Result<URL, Error>).self) { group in
                var next = 0
                func enqueue(_ job: (Int, URL, UUID)) {
                    group.addTask {
                        let directory = base.appendingPathComponent(job.2.uuidString, isDirectory: true)
                        do {
                            return (job.0, .success(try await ImageEncoder.encode(job.1, options: options, in: directory)))
                        } catch {
                            return (job.0, .failure(error))
                        }
                    }
                }
                while next < min(limit, jobs.count) {
                    self?.mark(jobs[next].0, .running)
                    enqueue(jobs[next])
                    next += 1
                }
                for await (index, result) in group {
                    self?.finish(index, result)
                    if next < jobs.count, !Task.isCancelled {
                        self?.mark(jobs[next].0, .running)
                        enqueue(jobs[next])
                        next += 1
                    }
                }
            }
            self?.running = false
        }
    }

    private func mark(_ index: Int, _ status: OptimizeResult.Status) {
        guard results.indices.contains(index) else { return }
        results[index].status = status
    }

    private func finish(_ index: Int, _ result: Result<URL, Error>) {
        guard results.indices.contains(index) else { return }
        switch result {
        case .success(let url):
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            results[index].output = url
            results[index].outputBytes = Int64(bytes)
            results[index].status = .done
        case .failure(let error):
            results[index].error = error.localizedDescription
            results[index].status = .failed
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    func reset() {
        cancel()
        results = []
        encodedKey = nil
    }

    /// Deletes the encoded files. Call when the sheet closes.
    func cleanup() {
        reset()
        try? FileManager.default.removeItem(at: workDirectory)
    }
}

extension UTType {
    /// Not declared as a constant in the macOS 14 SDK.
    static let avifImage = UTType("public.avif") ?? UTType(importedAs: "public.avif")
}
