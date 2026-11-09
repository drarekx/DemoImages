import Foundation

/// Command-line encoders the optimizer drives. They are the same libraries Squoosh
/// compiles to WebAssembly (libwebp, libavif, libjxl, MozJPEG, OxiPNG, libimagequant).
/// None are bundled; install with Homebrew. Formats ImageIO can write (HEIC, AVIF on
/// recent macOS, plain JPEG/PNG) work without them.
enum ExternalTool: String, CaseIterable, Identifiable {
    case cwebp, avifenc, cjxl, mozjpeg, oxipng, pngquant

    var id: String { rawValue }

    /// Homebrew formula that provides it.
    var formula: String {
        switch self {
        case .cwebp: return "webp"
        case .avifenc: return "libavif"
        case .cjxl: return "jpeg-xl"
        case .mozjpeg: return "mozjpeg"
        case .oxipng: return "oxipng"
        case .pngquant: return "pngquant"
        }
    }

    var executableName: String { self == .mozjpeg ? "cjpeg" : rawValue }

    var purpose: String {
        switch self {
        case .cwebp: return "WebP"
        case .avifenc: return tr("AVIF (con control de esfuerzo)")
        case .cjxl: return "JPEG XL"
        case .mozjpeg: return tr("JPEG optimizado (MozJPEG)")
        case .oxipng: return tr("PNG sin pérdida (OxiPNG)")
        case .pngquant: return tr("Reducir paleta de PNG (pngquant)")
        }
    }

    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                                      NSHomeDirectory() + "/.local/bin"]

    var url: URL? {
        // MozJPEG is keg-only in Homebrew: its cjpeg never lands in bin/, and the cjpeg
        // that does (libjpeg-turbo) is a different encoder.
        if self == .mozjpeg {
            return ["/opt/homebrew/opt/mozjpeg/bin/cjpeg", "/usr/local/opt/mozjpeg/bin/cjpeg"]
                .map(URL.init(fileURLWithPath:))
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        // Apps launched from Finder get a minimal PATH, so look in the usual places first.
        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in Self.searchPaths + envPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(executableName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    var isInstalled: Bool { url != nil }

    static var missing: [ExternalTool] { allCases.filter { !$0.isInstalled } }

    static func installCommand(_ tools: [ExternalTool]) -> String {
        "brew install " + tools.map(\.formula).joined(separator: " ")
    }
}

enum ToolError: LocalizedError {
    case notInstalled(ExternalTool)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled(let tool): return tr("No se encuentra %@. Instálalo con: brew install %@", tool.executableName, tool.formula)
        case .failed(let message): return message
        case .cancelled: return tr("Cancelado.")
        }
    }
}

/// Runs a tool and waits for it. Cancelling the Swift task terminates the process.
final class ToolProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var output = Data()

    static func run(_ tool: ExternalTool, _ arguments: [String]) async throws {
        guard let executable = tool.url else { throw ToolError.notInstalled(tool) }
        let runner = ToolProcess()
        try await withTaskCancellationHandler {
            try await runner.start(executable: executable, arguments: arguments)
        } onCancel: {
            runner.process.terminate()
        }
    }

    private func start(executable: URL, arguments: [String]) async throws {
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self, !chunk.isEmpty else { return }
            self.lock.lock()
            self.output.append(chunk)
            if self.output.count > 8192 { self.output.removeFirst(self.output.count - 8192) }
            self.lock.unlock()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { [weak self] process in
                pipe.fileHandleForReading.readabilityHandler = nil
                if Task.isCancelled || process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: ToolError.cancelled)
                } else if process.terminationStatus != 0 {
                    let detail = self?.lastLines() ?? ""
                    continuation.resume(throwing: ToolError.failed(
                        tr("%@ terminó con error %d.\n%@", executable.lastPathComponent, Int(process.terminationStatus), detail)))
                } else {
                    continuation.resume()
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func lastLines() -> String {
        lock.lock(); defer { lock.unlock() }
        let text = String(decoding: output, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).suffix(4).joined(separator: "\n")
    }
}
