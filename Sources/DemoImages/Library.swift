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
    /// The original this file was optimized from, in the same album.
    var sourceID: UUID? = nil
    /// How the optimizer made this file (nil for imported files).
    var optimization: OptimizationInfo? = nil

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
    case locationInsideLibrary
    case destinationNotEmpty(String)

    var errorDescription: String? {
        switch self {
        case .notAnImage(let name): return tr("%@ no es una imagen que se pueda leer.", name)
        case .missingAlbum: return tr("El álbum ya no existe.")
        case .locationInsideLibrary: return tr("La nueva ubicación no puede estar dentro de la biblioteca actual.")
        case .destinationNotEmpty(let path): return tr("En %@ ya hay archivos de otra biblioteca a medias. Elige otra carpeta.", path)
        }
    }
}

/// Albums and their images. Each album is a folder under `<root>/Albums/<album id>/`;
/// `<root>/library.json` keeps names, order and the measured size of every image.
/// The root defaults to `~/Library/Application Support/DemoImages` and can be moved
/// anywhere, e.g. iCloud Drive to share the library between Macs.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var albums: [Album] = []
    @Published private(set) var importing = false
    @Published private(set) var relocating = false
    /// Where the library lives.
    @Published private(set) var root: URL
    /// The root's parent folder is missing (unplugged disk, iCloud Drive turned off).
    @Published private(set) var unavailable = false

    /// Modification date of library.json when we last read or wrote it, to notice
    /// changes made by another Mac through iCloud.
    private var indexDate: Date?

    static let defaultRoot: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppInfo.name, isDirectory: true)

    /// `~/Library/Mobile Documents/com~apple~CloudDocs`, when iCloud Drive is on.
    nonisolated static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static let rootKey = "libraryPath"

    var albumsDirectory: URL { root.appendingPathComponent("Albums", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("library.json") }

    var totalBytes: Int64 { albums.reduce(0) { $0 + $1.totalBytes } }
    var imageCount: Int { albums.reduce(0) { $0 + $1.images.count } }
    var isInICloud: Bool { Self.isInICloud(root) }

    private init() {
        root = UserDefaults.standard.string(forKey: Self.rootKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.defaultRoot
    }

    // MARK: - Persistence
    //
    // With the library in iCloud Drive another Mac may write library.json too. Two rules
    // keep both Macs' work: entries are never dropped because their file is missing (iCloud
    // often delivers the index before the images), and a save merges with whatever the
    // other Mac wrote since our last read, using what this Mac changed in between.

    /// Entries this Mac added, deleted or changed since library.json was last read or written.
    /// Keys: `a:<album>` for albums, `i:<album>:<image>` for images.
    private var localAdded: Set<String> = []
    private var localDeleted: Set<String> = []
    private var localModified: Set<String> = []

    private static func key(_ album: UUID) -> String { "a:\(album.uuidString)" }
    private static func key(_ album: UUID, _ image: UUID) -> String { "i:\(album.uuidString):\(image.uuidString)" }

    func load() {
        albums = []
        indexDate = nil
        clearLocalChanges()
        let fm = FileManager.default
        unavailable = !fm.fileExists(atPath: root.deletingLastPathComponent().path)
        guard !unavailable else { return }
        try? fm.createDirectory(at: albumsDirectory, withIntermediateDirectories: true)
        switch readIndex() {
        case .missing:
            break
        case .read(let read, let date):
            albums = read
            indexDate = date
        case .unreadable(let error):
            NSLog("\(AppInfo.name): could not read library.json: \(error)")
            // Keep the unreadable index aside instead of overwriting it on the next save.
            let backup = indexURL.deletingPathExtension().appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: indexURL, to: backup)
        }
    }

    private var watchTimer: Timer?

    /// While the app is active and the library is in iCloud, checks every few seconds
    /// whether another Mac changed library.json (a cheap file-date check).
    func startWatching() {
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                let library = Library.shared
                guard NSApp.isActive, library.isInICloud else { return }
                library.reloadIfChangedExternally()
            }
        }
    }

    /// Re-reads library.json if something else (another Mac, via iCloud) changed it.
    func reloadIfChangedExternally() {
        guard !relocating, !importing, let date = modificationDate(indexURL), date != indexDate else { return }
        load()
    }

    private enum IndexRead {
        case missing
        case read([Album], Date?)
        case unreadable(Error)
    }

    /// Reads library.json through a file coordinator, so iCloud isn't writing it meanwhile.
    private func readIndex() -> IndexRead {
        let url = indexURL
        Self.requestDownload(url)
        var result = IndexRead.missing
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do {
                result = .read(try decoder.decode([Album].self, from: data), modificationDate(url))
            } catch {
                result = .unreadable(error)
            }
        }
        return result
    }

    private func save() {
        guard !unavailable else { return }
        // Someone else wrote the index since we last did: fold their changes in first.
        if let date = modificationDate(indexURL), date != indexDate, case .read(let disk, _) = readIndex() {
            albums = merge(local: albums, disk: disk)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try encoder.encode(albums)
            var writeError: Error?
            var coordinationError: NSError?
            NSFileCoordinator().coordinate(writingItemAt: indexURL, options: .forReplacing, error: &coordinationError) { url in
                do { try data.write(to: url, options: .atomic) } catch { writeError = error }
            }
            if let error = writeError ?? coordinationError { throw error }
            indexDate = modificationDate(indexURL)
            clearLocalChanges()
        } catch {
            NSLog("\(AppInfo.name): could not save library.json: \(error)")
        }
    }

    private func clearLocalChanges() {
        localAdded = []
        localDeleted = []
        localModified = []
    }

    /// Three-way merge of the index: what this Mac changed since its last read wins for
    /// those entries; everything else follows the copy on disk (the other Mac's changes,
    /// including its additions and deletions).
    private func merge(local: [Album], disk: [Album]) -> [Album] {
        let diskByID = Dictionary(disk.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(local.map(\.id))
        var result: [Album] = []
        for album in local {
            let albumKey = Self.key(album.id)
            guard let other = diskByID[album.id] else {
                // Not on disk: ours if we just made it, else the other Mac deleted it.
                if localAdded.contains(albumKey) { result.append(album) }
                continue
            }
            var merged = localModified.contains(albumKey) ? album : other
            merged.images = mergeImages(album: album.id, local: album.images, disk: other.images)
            result.append(merged)
        }
        for album in disk where !localIDs.contains(album.id) && !localDeleted.contains(Self.key(album.id)) {
            result.append(album)
        }
        return result
    }

    private func mergeImages(album: UUID, local: [ImageItem], disk: [ImageItem]) -> [ImageItem] {
        let diskByID = Dictionary(disk.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let localIDs = Set(local.map(\.id))
        var result: [ImageItem] = []
        for item in local {
            let key = Self.key(album, item.id)
            if let other = diskByID[item.id] {
                result.append(localModified.contains(key) ? item : other)
            } else if localAdded.contains(key) {
                result.append(item)
            }
        }
        for item in disk where !localIDs.contains(item.id) && !localDeleted.contains(Self.key(album, item.id)) {
            result.append(item)
        }
        return result
    }

    /// Entries whose file is not in the album folder, not even as an iCloud placeholder.
    var missingCount: Int {
        albums.reduce(0) { count, album in
            let folder = folder(of: album.id)
            return count + album.images.filter { !Self.fileExists(folder.appendingPathComponent($0.fileName)) }.count
        }
    }

    /// Removes entries whose file no longer exists (deleted from Finder). Manual only:
    /// with iCloud a file can simply not have arrived yet.
    func removeMissing() {
        for index in albums.indices {
            let album = albums[index]
            let folder = folder(of: album.id)
            for item in album.images where !Self.fileExists(folder.appendingPathComponent(item.fileName)) {
                localDeleted.insert(Self.key(album.id, item.id))
            }
            albums[index].images.removeAll { localDeleted.contains(Self.key(album.id, $0.id)) }
        }
        save()
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Location

    /// Where a library chosen in `folder` would live, and whether one is already there.
    /// Picking an unrelated, non-empty folder puts the library in a `DemoImages` subfolder.
    func target(for folder: URL) -> (url: URL, hasLibrary: Bool) {
        let fm = FileManager.default
        let hasLibrary = { (url: URL) in fm.fileExists(atPath: url.appendingPathComponent("library.json").path) }
        if hasLibrary(folder) { return (folder, true) }
        let sub = folder.appendingPathComponent(AppInfo.name, isDirectory: true)
        if hasLibrary(sub) { return (sub, true) }
        let contents = (try? fm.contentsOfDirectory(atPath: folder.path))?.filter { !$0.hasPrefix(".") } ?? []
        if folder.lastPathComponent == AppInfo.name || contents.isEmpty { return (folder, false) }
        return (sub, false)
    }

    /// Opens the library at `url` and leaves the current one where it is.
    func open(_ url: URL) {
        setRoot(url)
        load()
    }

    /// Moves the whole library (albums and index) to `target`.
    func move(to target: URL) async throws {
        let source = root.standardizedFileURL
        let destination = target.standardizedFileURL
        guard destination != source else { return }
        guard !destination.path.hasPrefix(source.path + "/") else { throw LibraryError.locationInsideLibrary }
        relocating = true
        defer { relocating = false }
        try await Task.detached(priority: .userInitiated) {
            try Self.moveContents(from: source, to: destination)
        }.value
        open(destination)
    }

    private func setRoot(_ url: URL) {
        root = url.standardizedFileURL
        if root == Self.defaultRoot.standardizedFileURL {
            UserDefaults.standard.removeObject(forKey: Self.rootKey)
        } else {
            UserDefaults.standard.set(root.path, forKey: Self.rootKey)
        }
    }

    /// Moves `Albums/` then `library.json`; if the index can't follow, the albums go back.
    nonisolated private static func moveContents(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let albums = ("Albums", source.appendingPathComponent("Albums"), destination.appendingPathComponent("Albums"))
        let index = ("library.json", source.appendingPathComponent("library.json"), destination.appendingPathComponent("library.json"))
        for (_, _, to) in [albums, index] where fm.fileExists(atPath: to.path) {
            throw LibraryError.destinationNotEmpty(destination.path)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        if fm.fileExists(atPath: albums.1.path) {
            try fm.moveItem(at: albums.1, to: albums.2)
        }
        if fm.fileExists(atPath: index.1.path) {
            do {
                try fm.moveItem(at: index.1, to: index.2)
            } catch {
                try? fm.moveItem(at: albums.2, to: albums.1)
                throw error
            }
        }
        // Remove the old folder if nothing else is left in it.
        let left = (try? fm.contentsOfDirectory(atPath: source.path))?.filter { $0 != ".DS_Store" } ?? []
        if left.isEmpty { try? fm.removeItem(at: source) }
    }

    nonisolated static func isInICloud(_ url: URL) -> Bool {
        guard let drive = iCloudDrive?.standardizedFileURL.path else { return false }
        return url.standardizedFileURL.path.hasPrefix(drive)
    }

    /// "iCloud Drive › DemoImages" or "~/Library/Application Support/DemoImages".
    nonisolated static func displayPath(_ url: URL) -> String {
        if let drive = iCloudDrive?.standardizedFileURL.path, isInICloud(url) {
            let rest = url.standardizedFileURL.path.dropFirst(drive.count)
                .split(separator: "/").joined(separator: " › ")
            return rest.isEmpty ? "iCloud Drive" : "iCloud Drive › \(rest)"
        }
        return (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// True for files present locally and for iCloud files not downloaded yet.
    nonisolated static func fileExists(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    /// Asks iCloud to download a file before it is read (no-op for local files).
    nonisolated static func requestDownload(_ url: URL) {
        guard isInICloud(url) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
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
        albumsDirectory.appendingPathComponent(albumID.uuidString, isDirectory: true)
    }

    func url(of item: ImageItem, in albumID: UUID) -> URL {
        folder(of: albumID).appendingPathComponent(item.fileName)
    }

    /// Optimized versions of an image, smallest first.
    func versions(of id: UUID, in albumID: UUID) -> [ImageItem] {
        (album(albumID)?.images ?? []).filter { $0.sourceID == id }.sorted { $0.bytes < $1.bytes }
    }

    /// The original an optimized version comes from, if it is still in the album.
    func original(of item: ImageItem, in albumID: UUID) -> ImageItem? {
        guard let sourceID = item.sourceID else { return nil }
        return album(albumID)?.images.first { $0.id == sourceID }
    }

    // MARK: - Albums

    @discardableResult
    func createAlbum(named name: String) -> Album {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = Album(name: trimmed.isEmpty ? tr("Álbum sin nombre") : trimmed)
        try? FileManager.default.createDirectory(at: folder(of: album.id), withIntermediateDirectories: true)
        albums.append(album)
        localAdded.insert(Self.key(album.id))
        save()
        return album
    }

    func renameAlbum(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = try? index(of: id) else { return }
        albums[index].name = trimmed
        localModified.insert(Self.key(id))
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
        localDeleted.insert(Self.key(id))
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
        localAdded.formUnion(result.items.map { Self.key(albumID, $0.id) })
        save()
        return (result.items.count, result.failed)
    }

    /// Adds one file (an optimizer result, a pasted image) to the album under `name`.
    @discardableResult
    func addFile(at source: URL, into albumID: UUID, name: String,
                 sourceID: UUID? = nil, optimization: OptimizationInfo? = nil) throws -> ImageItem {
        let index = try index(of: albumID)
        let folder = folder(of: albumID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(Self.uniqueName(name, in: folder))
        try FileManager.default.copyItem(at: source, to: destination)
        guard let item = Self.makeItem(for: destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw LibraryError.notAnImage(name)
        }
        var added = item
        added.sourceID = sourceID
        added.optimization = optimization
        albums[index].images.append(added)
        localAdded.insert(Self.key(albumID, added.id))
        save()
        return added
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
        localDeleted.formUnion(albums[index].images.filter { ids.contains($0.id) }.map { Self.key(albumID, $0.id) })
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
        // Copies get new ids; keep originals and their versions linked when both are copied.
        var newIDs: [UUID: UUID] = [:]
        let firstAdded = albums[target].images.count
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
            if !move {
                copy.id = UUID()
                newIDs[item.id] = copy.id
            }
            copy.fileName = name
            copy.added = Date()
            albums[target].images.append(copy)
            localAdded.insert(Self.key(targetID, copy.id))
        }
        for position in firstAdded..<albums[target].images.count {
            if let old = albums[target].images[position].sourceID, let new = newIDs[old] {
                albums[target].images[position].sourceID = new
                localModified.insert(Self.key(targetID, albums[target].images[position].id))
            }
        }
        if move {
            localDeleted.formUnion(moved.map { Self.key(sourceID, $0) })
            albums[source].images.removeAll { moved.contains($0.id) }
        }
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
                localDeleted.formUnion(done.map { Self.key(albumID, $0) })
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
    /// The item keeps its id, so versions made from it stay linked to it.
    func replace(_ id: UUID, in albumID: UUID, with source: URL, fileExtension: String,
                 optimization: OptimizationInfo? = nil) throws {
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
        item.sourceID = old.sourceID
        item.optimization = optimization ?? old.optimization
        albums[index].images[position] = item
        localModified.insert(Self.key(albumID, id))
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
        localModified.insert(Self.key(albumID, id))
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
