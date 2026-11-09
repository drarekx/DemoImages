import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One image stored in an album.
struct ImageItem: Codable, Identifiable, Hashable {
    var id = UUID()
    /// File name inside the album's folder.
    var fileName: String
    var added = Date()
    var bytes: Int64
    var width: Int
    var height: Int
    /// Uniform type identifier detected by ImageIO (e.g. `public.png`).
    var typeID: String

    var name: String { (fileName as NSString).deletingPathExtension }

    /// "PNG", "WEBP"…
    var formatLabel: String {
        let ext = UTType(typeID)?.preferredFilenameExtension ?? (fileName as NSString).pathExtension
        switch ext.lowercased() {
        case "jpeg": return "JPG"
        default: return ext.uppercased()
        }
    }

    var dimensions: String { "\(width)×\(height)" }
}

struct Album: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var created = Date()
    var images: [ImageItem] = []

    var totalBytes: Int64 { images.reduce(0) { $0 + $1.bytes } }
}

enum LibraryError: LocalizedError {
    case notAnImage(String)
    case missingAlbum

    var errorDescription: String? {
        switch self {
        case .notAnImage(let name): return tr("%@ no es una imagen que se pueda leer.", name)
        case .missingAlbum: return tr("El álbum ya no existe.")
        }
    }
}

/// Albums and their images. Each album is a folder under
/// `~/Library/Application Support/DemoImages/Albums/<album id>/`; `library.json` keeps
/// names, order and the measured size of every image.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var albums: [Album] = []
    @Published private(set) var importing = false

    static let root: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.name, isDirectory: true)
    static var albumsDirectory: URL { root.appendingPathComponent("Albums", isDirectory: true) }
    private var indexURL: URL { Self.root.appendingPathComponent("library.json") }

    // MARK: - Persistence

    func load() {
        try? FileManager.default.createDirectory(at: Self.albumsDirectory, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            albums = try decoder.decode([Album].self, from: data)
        } catch {
            NSLog("\(AppInfo.name): could not read library.json: \(error)")
            // Keep the unreadable index aside instead of overwriting it on the next save.
            let backup = indexURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: indexURL, to: backup)
        }
        // Drop entries whose file was deleted from Finder.
        var changed = false
        for index in albums.indices {
            let folder = folder(of: albums[index].id)
            let before = albums[index].images.count
            albums[index].images.removeAll {
                !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path)
            }
            changed = changed || albums[index].images.count != before
        }
        if changed { save() }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
            try encoder.encode(albums).write(to: indexURL, options: .atomic)
        } catch {
            NSLog("\(AppInfo.name): could not save library.json: \(error)")
        }
    }

    // MARK: - Lookup

    func album(_ id: UUID?) -> Album? {
        guard let id else { return nil }
        return albums.first { $0.id == id }
    }

    private func index(of albumID: UUID) throws -> Int {
        guard let index = albums.firstIndex(where: { $0.id == albumID }) else { throw LibraryError.missingAlbum }
        return index
    }

    func folder(of albumID: UUID) -> URL {
        Self.albumsDirectory.appendingPathComponent(albumID.uuidString, isDirectory: true)
    }

    func url(of item: ImageItem, in albumID: UUID) -> URL {
        folder(of: albumID).appendingPathComponent(item.fileName)
    }

    // MARK: - Albums

    @discardableResult
    func createAlbum(named name: String) -> Album {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = Album(name: trimmed.isEmpty ? tr("Álbum sin nombre") : trimmed)
        try? FileManager.default.createDirectory(at: folder(of: album.id), withIntermediateDirectories: true)
        albums.append(album)
        save()
        return album
    }

    func renameAlbum(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = try? index(of: id) else { return }
        albums[index].name = trimmed
        save()
    }

    /// The album folder goes to the Trash, so it can be recovered.
    func deleteAlbum(_ id: UUID) {
        guard let index = try? index(of: id) else { return }
        let folder = folder(of: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
        }
        albums.remove(at: index)
        save()
    }

    // MARK: - Import

    /// Copies files (and images found inside dropped folders) into the album.
    /// Returns how many were added and the names that could not be read.
    @discardableResult
    func importFiles(_ urls: [URL], into albumID: UUID) async -> (added: Int, failed: [String]) {
        guard album(albumID) != nil else { return (0, []) }
        importing = true
        defer { importing = false }
        let folder = folder(of: albumID)
        let result = await Task.detached(priority: .userInitiated) {
            Self.copyImages(Self.expand(urls), to: folder)
        }.value
        guard let index = try? index(of: albumID) else { return (0, result.failed) }
        albums[index].images += result.items
        save()
        return (result.items.count, result.failed)
    }

    /// Adds one file (an optimizer result, a pasted image) to the album under `name`.
    @discardableResult
    func addFile(at source: URL, into albumID: UUID, name: String) throws -> ImageItem {
        let index = try index(of: albumID)
        let folder = folder(of: albumID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(Self.uniqueName(name, in: folder))
        try FileManager.default.copyItem(at: source, to: destination)
        guard let item = Self.makeItem(for: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw LibraryError.notAnImage(name)
        }
        albums[index].images.append(item)
        save()
        return item
    }

    /// Image files to import: the files themselves and, for folders, every image inside.
    nonisolated private static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let file = enumerator?.nextObject() as? URL {
                    if isImageFile(file) { files.append(file) }
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    nonisolated static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    nonisolated private static func copyImages(_ files: [URL], to folder: URL) -> (items: [ImageItem], failed: [String]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var items: [ImageItem] = []
        var failed: [String] = []
        for file in files {
            // Check before copying so non-images never land in the album.
            guard readImageInfo(file) != nil else {
                failed.append(file.lastPathComponent)
                continue
            }
            let destination = folder.appendingPathComponent(uniqueName(file.lastPathComponent, in: folder))
            do {
                try FileManager.default.copyItem(at: file, to: destination)
                if let item = makeItem(for: destination) {
                    items.append(item)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    failed.append(file.lastPathComponent)
                }
            } catch {
                failed.append(file.lastPathComponent)
            }
        }
        return (items, failed)
    }

    // MARK: - Image operations

    /// Moves the images to the Trash.
    func removeImages(_ ids: Set<UUID>, from albumID: UUID) {
        guard let index = try? index(of: albumID) else { return }
        let folder = folder(of: albumID)
        for item in albums[index].images where ids.contains(item.id) {
            let url = folder.appendingPathComponent(item.fileName)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            ThumbnailCache.shared.invalidate(url)
        }
        albums[index].images.removeAll { ids.contains($0.id) }
        save()
    }

    /// Copies or moves images to another album.
    func transfer(_ ids: Set<UUID>, from sourceID: UUID, to targetID: UUID, move: Bool) throws {
        guard sourceID != targetID else { return }
        let source = try index(of: sourceID)
        let target = try index(of: targetID)
        let sourceFolder = folder(of: sourceID)
        let targetFolder = folder(of: targetID)
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        var moved: Set<UUID> = []
        for item in albums[source].images where ids.contains(item.id) {
            let from = sourceFolder.appendingPathComponent(item.fileName)
            let name = Self.uniqueName(item.fileName, in: targetFolder)
            let to = targetFolder.appendingPathComponent(name)
            if move {
                try FileManager.default.moveItem(at: from, to: to)
                ThumbnailCache.shared.invalidate(from)
                moved.insert(item.id)
            } else {
                try FileManager.default.copyItem(at: from, to: to)
            }
            var copy = item
            if !move { copy.id = UUID() }
            copy.fileName = name
            copy.added = Date()
            albums[target].images.append(copy)
        }
        if move { albums[source].images.removeAll { moved.contains($0.id) } }
        save()
    }

    /// Copies or moves images to a folder outside the library. Returns how many were written.
    @discardableResult
    func export(_ ids: Set<UUID>, from albumID: UUID, to directory: URL, move: Bool) throws -> Int {
        let index = try index(of: albumID)
        let folder = folder(of: albumID)
        var done: Set<UUID> = []
        defer {
            if move && !done.isEmpty {
                albums[index].images.removeAll { done.contains($0.id) }
                save()
            }
        }
        for item in albums[index].images where ids.contains(item.id) {
            let from = folder.appendingPathComponent(item.fileName)
            let to = directory.appendingPathComponent(Self.uniqueName(item.fileName, in: directory))
            if move {
                try FileManager.default.moveItem(at: from, to: to)
                ThumbnailCache.shared.invalidate(from)
            } else {
                try FileManager.default.copyItem(at: from, to: to)
            }
            done.insert(item.id)
        }
        return done.count
    }

    /// Replaces an image's file (optimizer "replace" mode). The old file goes to the Trash.
    func replace(_ id: UUID, in albumID: UUID, with source: URL, fileExtension: String) throws {
        let index = try index(of: albumID)
        guard let position = albums[index].images.firstIndex(where: { $0.id == id }) else { return }
        let folder = folder(of: albumID)
        let old = albums[index].images[position]
        let oldURL = folder.appendingPathComponent(old.fileName)
        try FileManager.default.trashItem(at: oldURL, resultingItemURL: nil)
        ThumbnailCache.shared.invalidate(oldURL)
        let name = Self.uniqueName(old.name + "." + fileExtension, in: folder)
        let newURL = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: newURL)
        ThumbnailCache.shared.invalidate(newURL)
        guard var item = Self.makeItem(for: newURL) else { throw LibraryError.notAnImage(name) }
        item.id = old.id
        item.added = old.added
        albums[index].images[position] = item
        save()
    }

    func renameImage(_ id: UUID, in albumID: UUID, to newName: String) throws {
        let index = try index(of: albumID)
        guard let position = albums[index].images.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let item = albums[index].images[position]
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        let folder = folder(of: albumID)
        let ext = (item.fileName as NSString).pathExtension
        let name = Self.uniqueName(ext.isEmpty ? trimmed : "\(trimmed).\(ext)", in: folder)
        let oldURL = folder.appendingPathComponent(item.fileName)
        try FileManager.default.moveItem(at: oldURL, to: folder.appendingPathComponent(name))
        ThumbnailCache.shared.invalidate(oldURL)
        albums[index].images[position].fileName = name
        save()
    }

    // MARK: - Helpers

    /// `photo.png`, then `photo 2.png`, `photo 3.png`… if taken.
    nonisolated static func uniqueName(_ name: String, in folder: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent(name).path) else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !fm.fileExists(atPath: folder.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    nonisolated static func makeItem(for url: URL) -> ImageItem? {
        guard let info = readImageInfo(url) else { return nil }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ImageItem(fileName: url.lastPathComponent, bytes: Int64(bytes),
                         width: info.width, height: info.height, typeID: info.typeID)
    }

    /// Pixel size (after EXIF rotation) and type, read from the header only.
    nonisolated static func readImageInfo(_ url: URL) -> (width: Int, height: Int, typeID: String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? (height, width, type) : (width, height, type)
    }
}

enum Format {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "−42 %" / "+8 %"
    static func change(from before: Int64, to after: Int64) -> String {
        guard before > 0 else { return "" }
        let percent = (Double(after) - Double(before)) / Double(before) * 100
        let sign = percent < 0 ? "−" : "+"
        return "\(sign)\(Int(abs(percent).rounded())) %"
    }
}
