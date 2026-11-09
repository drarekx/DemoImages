import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case album(UUID)
    case settings
}

/// Main window: albums sidebar + the selected album's gallery (or settings).
struct MainView: View {
    @ObservedObject private var library = Library.shared
    @ObservedObject private var localizer = Localizer.shared
    @ObservedObject private var settings = Settings.shared
    @State private var selection: SidebarItem?
    @State private var newAlbumPrompt = false
    @State private var newAlbumName = ""

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection, newAlbum: promptNewAlbum)
            Rectangle().fill(Theme.line).frame(width: 1)
            Group {
                switch selection {
                case .album(let id) where library.album(id) != nil:
                    GalleryView(albumID: id).id(id)
                case .settings:
                    SettingsPane()
                default:
                    NoAlbumView(newAlbum: promptNewAlbum)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .id(localizer.language)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear(perform: restoreSelection)
        .onChange(of: selection) { _, value in
            if case .album(let id) = value { settings.lastAlbumID = id }
        }
        .onChange(of: library.root) { _, _ in
            // Another library was opened: its albums have other IDs.
            if case .album(let id) = selection, library.album(id) == nil {
                selection = library.albums.first.map { .album($0.id) }
            }
        }
        .onReceive(AppCommands.shared.subject) { command in
            switch command {
            case .newAlbum: promptNewAlbum()
            case .settings: selection = .settings
            case .open(let urls):
                // Files opened from Finder/Dock while no album is shown go into a new one.
                if case .album = selection { return }
                let album = library.albums.first ?? library.createAlbum(named: tr("Importadas"))
                selection = .album(album.id)
                Task { await library.importFiles(urls, into: album.id) }
            default: break
            }
        }
        .alert(tr("Nuevo álbum"), isPresented: $newAlbumPrompt) {
            TextField(tr("Nombre"), text: $newAlbumName)
            Button(tr("Crear")) {
                let album = library.createAlbum(named: newAlbumName)
                selection = .album(album.id)
            }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(tr("Ponle un nombre, por ejemplo «Avatares» o «Fondos 4K»."))
        }
    }

    private func promptNewAlbum() {
        newAlbumName = ""
        newAlbumPrompt = true
    }

    private func restoreSelection() {
        guard selection == nil else { return }
        if let id = settings.lastAlbumID, library.album(id) != nil {
            selection = .album(id)
        } else if let first = library.albums.first {
            selection = .album(first.id)
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Binding var selection: SidebarItem?
    let newAlbum: () -> Void
    @ObservedObject private var library = Library.shared
    @State private var renaming: Album?
    @State private var renameText = ""
    @State private var deleting: Album?
    @State private var dropTarget: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.accentFill)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "photo.stack").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    }
                Text(AppInfo.name).font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.top, 14)

            HStack {
                SectionLabel(tr("Álbumes"))
                Spacer()
                Button(action: newAlbum) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text2)
                .help(tr("Nuevo álbum…"))
                .accessibilityLabel(tr("Nuevo álbum…"))
            }
            .padding(.horizontal, 10)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(library.albums) { album in
                        albumRow(album)
                    }
                    if library.albums.isEmpty {
                        Text(tr("Aún no hay álbumes."))
                            .font(.system(size: 12)).foregroundStyle(Theme.text3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                navButton(tr("Ajustes"), "slider.horizontal.3", selected: selection == .settings) {
                    selection = .settings
                }
                StorageCard { selection = .settings }
                Text(tr("Versión %@", Updater.currentVersion))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .alert(tr("Renombrar álbum"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(tr("Nombre"), text: $renameText)
            Button(tr("Renombrar")) {
                if let renaming { library.renameAlbum(renaming.id, to: renameText) }
            }
            Button(tr("Cancelar"), role: .cancel) {}
        }
        .alert(tr("¿Eliminar el álbum «%@»?", deleting?.name ?? ""),
               isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(tr("Eliminar"), role: .destructive) {
                guard let deleting else { return }
                if selection == .album(deleting.id) { selection = nil }
                library.deleteAlbum(deleting.id)
                if selection == nil, let first = library.albums.first { selection = .album(first.id) }
            }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(tr("Sus %d imágenes irán a la papelera.", deleting?.images.count ?? 0))
        }
    }

    private func albumRow(_ album: Album) -> some View {
        let selected = selection == .album(album.id)
        let targeted = dropTarget == album.id
        return Button {
            selection = .album(album.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .frame(width: 16)
                    .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                Text(album.name).lineLimit(1)
                Spacer()
                Text("\(album.images.count)").monospacedText(size: 11).foregroundStyle(Theme.text3)
            }
            .fontWeight(selected ? .medium : .regular)
            .foregroundStyle(selected ? Theme.text : Theme.text2)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if targeted { RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accent, lineWidth: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: Binding(get: { targeted }, set: { dropTarget = $0 ? album.id : nil })) { providers in
            FileDrop.load(providers) { urls in
                Task { await library.importFiles(urls, into: album.id) }
            }
            return true
        }
        .contextMenu {
            Button(tr("Renombrar…")) {
                renameText = album.name
                renaming = album
            }
            Button(tr("Mostrar en Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([library.folder(of: album.id)])
            }
            Divider()
            Button(tr("Eliminar álbum…"), role: .destructive) { deleting = album }
        }
    }

    private func navButton(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 16)
                    .foregroundStyle(selected ? Theme.accentText : Theme.text2)
                Text(title)
                Spacer()
            }
            .fontWeight(selected ? .medium : .regular)
            .foregroundStyle(selected ? Theme.text : Theme.text2)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(selected ? Theme.navSelected : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Where the library is stored and how much it takes, under the sidebar.
private struct StorageCard: View {
    let change: () -> Void
    @ObservedObject private var library = Library.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: library.unavailable ? "exclamationmark.triangle"
                      : library.isInICloud ? "icloud" : "internaldrive")
                    .foregroundStyle(library.unavailable ? Theme.warn : Theme.accentText)
                    .frame(width: 16)
                Text(Library.displayPath(library.root))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            if library.unavailable {
                Text(tr("No se encuentra la carpeta."))
                    .font(.system(size: 11)).foregroundStyle(Theme.warn)
            } else if library.relocating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(tr("Moviendo…"))
                }
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
            } else {
                Text(tr("%d imágenes · %@", library.imageCount, Format.bytes(library.totalBytes)))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
            }
            HStack(spacing: 6) {
                Button(tr("Mostrar")) {
                    NSWorkspace.shared.activateFileViewerSelecting([library.root])
                }
                Button(tr("Cambiar…"), action: change)
            }
            .buttonStyle(AppButtonStyle(kind: .ghost, height: 24))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
        .help(library.root.path)
    }
}

private struct NoAlbumView: View {
    let newAlbum: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.text3)
            Text(tr("Crea un álbum para empezar")).font(.system(size: 18, weight: .semibold))
            Text(tr("Guarda aquí tus imágenes de prueba, ordenadas por álbumes, y optimízalas a WebP, AVIF y otros formatos."))
                .foregroundStyle(Theme.text2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button(action: newAlbum) {
                Label(tr("Nuevo álbum…"), systemImage: "plus")
            }
            .buttonStyle(.appPrimary)
        }
        .padding(40)
    }
}

/// Reads file URLs from drag-and-drop providers.
enum FileDrop {
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                if !urls.isEmpty { completion(urls) }
            }
        }
    }
}
