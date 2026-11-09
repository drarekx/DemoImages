import Foundation

enum GallerySort: String, CaseIterable, Identifiable {
    case added, name, size, dimensions
    var id: String { rawValue }

    var title: String {
        switch self {
        case .added: return tr("Fecha de entrada")
        case .name: return tr("Nombre")
        case .size: return tr("Tamaño de archivo")
        case .dimensions: return tr("Dimensiones")
        }
    }
}

/// User preferences, persisted in UserDefaults (`com.egluu.demoimages`).
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    @Published var optimize: OptimizeOptions { didSet { save(optimize, "optimizeOptions") } }
    @Published var sort: GallerySort { didSet { defaults.set(sort.rawValue, forKey: "gallerySort") } }
    @Published var sortDescending: Bool { didSet { defaults.set(sortDescending, forKey: "sortDescending") } }
    /// Grid tile width in points.
    @Published var tileSize: Double { didSet { defaults.set(tileSize, forKey: "tileSize") } }
    @Published var lastAlbumID: UUID? { didSet { defaults.set(lastAlbumID?.uuidString, forKey: "lastAlbumID") } }
    /// Show optimized versions inside their original instead of as separate tiles.
    @Published var groupVersions: Bool { didSet { defaults.set(groupVersions, forKey: "groupVersions") } }
    /// Optimizer: leave out images that already have a version in the chosen format.
    @Published var skipOptimized: Bool { didSet { defaults.set(skipOptimized, forKey: "skipOptimized") } }

    private init() {
        defaults.register(defaults: ["tileSize": 180.0, "sortDescending": true,
                                     "groupVersions": true, "skipOptimized": true])
        optimize = defaults.data(forKey: "optimizeOptions")
            .flatMap { try? JSONDecoder().decode(OptimizeOptions.self, from: $0) } ?? OptimizeOptions()
        sort = GallerySort(rawValue: defaults.string(forKey: "gallerySort") ?? "") ?? .added
        sortDescending = defaults.bool(forKey: "sortDescending")
        tileSize = defaults.double(forKey: "tileSize")
        lastAlbumID = defaults.string(forKey: "lastAlbumID").flatMap(UUID.init(uuidString:))
        groupVersions = defaults.bool(forKey: "groupVersions")
        skipOptimized = defaults.bool(forKey: "skipOptimized")
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
