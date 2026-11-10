import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One album: header, actions, image grid with multi-selection, footer.
struct GalleryView: View {
    let albumID: UUID

    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared
    @State private var selection: Set<UUID> = []
    @State private var anchor: UUID?
    @State private var search = ""
    @State private var viewerIndex: Int?
    @State private var optimizing: [ImageItem]?
    @State private var dropTargeted = false
    @State private var confirmDelete: Set<UUID>?
    @State private var renaming: ImageItem?
    @State private var renameText = ""
    @State private var renamingAlbum = false
    @State private var albumName = ""
    @State private var message: String?

    private var album: Album? { library.album(albumID) }

    /// Optimized versions whose original is still in the album, grouped by original id.
    private var versionsByOriginal: [UUID: [ImageItem]] {
        guard let album else { return [:] }
        let ids = Set(album.images.map(\.id))
        return Dictionary(grouping: album.images.filter { $0.sourceID.map(ids.contains) ?? false }, by: { $0.sourceID! })
    }

    /// Images that are not a version of another image in the album.
    private var originals: [ImageItem] {
        guard let album else { return [] }
        let ids = Set(album.images.map(\.id))
        return album.images.filter { !($0.sourceID.map(ids.contains) ?? false) }
    }

    /// Filtered and sorted images, in display order. With grouping on, versions live
    /// inside their original (badge on the tile, list in the viewer).
    private var items: [ImageItem] {
        guard let album else { return [] }
        let shown = settings.groupVersions ? originals : album.images
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? shown : shown.filter {
            $0.fileName.lowercased().contains(query) || $0.formatLabel.lowercased() == query
        }
        let ascending: [ImageItem]
        switch settings.sort {
        case .added: ascending = filtered.sorted { $0.added < $1.added }
        case .name: ascending = filtered.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .size: ascending = filtered.sorted { $0.bytes < $1.bytes }
        case .dimensions: ascending = filtered.sorted { $0.width * $0.height < $1.width * $1.height }
        }
        return settings.sortDescending ? ascending.reversed() : ascending
    }

    private var hasVideos: Bool { album?.images.contains(where: \.isVideo) ?? false }

    private var selectedItems: [ImageItem] { items.filter { selection.contains($0.id) } }

    var body: some View {
        let items = self.items
        ZStack {
            VStack(spacing: 0) {
                header
                toolbar(items)
                Rectangle().fill(Theme.line).frame(height: 1)
                grid(items)
                Rectangle().fill(Theme.line).frame(height: 1)
                footer(items)
            }
            if let index = viewerIndex, items.indices.contains(index) {
                ViewerView(albumID: albumID, items: items, index: Binding(
                    get: { viewerIndex ?? 0 },
                    set: { viewerIndex = $0 }),
                    close: { viewerIndex = nil },
                    optimize: { optimizing = [$0] })
                .transition(.opacity)
            }
        }
        .onReceive(AppCommands.shared.subject) { handle($0) }
        .background {
            // Space opens the selected image, like Quick Look in the Finder.
            KeyCatcher { event in
                guard event.keyCode == KeyCatcher.space else { return false }
                // A held key must not open and close the viewer over and over.
                if event.isARepeat { return true }
                guard viewerIndex == nil, optimizing == nil, let index = selectedIndex(in: items) else { return false }
                viewerIndex = index
                return true
            }
        }
        .sheet(item: Binding(get: { optimizing.map(OptimizeBatch.init) }, set: { optimizing = $0?.items })) { batch in
            OptimizeSheet(albumID: albumID, items: batch.items) { optimizing = nil }
        }
        .alert(tr("Renombrar imagen"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(tr("Nombre"), text: $renameText)
            Button(tr("Renombrar")) {
                guard let renaming else { return }
                attempt { try library.renameImage(renaming.id, in: albumID, to: renameText) }
            }
            Button(tr("Cancelar"), role: .cancel) {}
        }
        .alert(tr("Renombrar álbum"), isPresented: $renamingAlbum) {
            TextField(tr("Nombre"), text: $albumName)
            Button(tr("Renombrar")) { library.renameAlbum(albumID, to: albumName) }
            Button(tr("Cancelar"), role: .cancel) {}
        }
        .alert(tr("¿Mover %d imágenes a la papelera?", confirmDelete?.count ?? 0),
               isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(tr("Mover a la papelera"), role: .destructive) {
                guard let ids = confirmDelete else { return }
                library.removeImages(ids, from: albumID)
                selection.subtract(ids)
            }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(tr("Se pueden recuperar desde la papelera del Finder."))
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(tr("Aceptar")) {}
        }
    }

    // MARK: - Header and toolbar

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(album?.name ?? "")
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        albumName = album?.name ?? ""
                        renamingAlbum = true
                    }
                    .help(tr("Doble clic para renombrar"))
                let (count, size) = (album?.images.count ?? 0, Format.bytes(album?.totalBytes ?? 0))
                Text(hasVideos ? tr("%d elementos · %@", count, size) : tr("%d imágenes · %@", count, size))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            Spacer()
            AppTextField(placeholder: tr("Buscar por nombre o formato"), text: $search, icon: "magnifyingglass")
                .frame(width: 240)
            Button {
                optimizing = originals
            } label: {
                Label(tr("Optimizar álbum…"), systemImage: "wand.and.stars")
            }
            .buttonStyle(.appSecondary)
            .disabled(originals.isEmpty)
            .help(tr("Optimiza todas las imágenes originales del álbum"))
            Button(action: chooseFilesToImport) {
                Label(tr("Añadir imágenes"), systemImage: "plus")
            }
            .buttonStyle(.appPrimary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 14)
    }

    private func toolbar(_ items: [ImageItem]) -> some View {
        let hasSelection = !selection.isEmpty
        let otherAlbums = library.albums.filter { $0.id != albumID }
        return HStack(spacing: 8) {
            Button(hasSelection ? tr("Ninguna") : tr("Seleccionar todo")) {
                if hasSelection { selection = [] } else { selection = Set(items.map(\.id)) }
            }
            .buttonStyle(SmallButton.secondary)
            .disabled(items.isEmpty)

            Rectangle().fill(Theme.line).frame(width: 1, height: 20).padding(.horizontal, 4)

            Button {
                optimizing = selectedItems
            } label: {
                Label(tr("Optimizar…"), systemImage: "wand.and.stars")
            }
            .buttonStyle(SmallButton.secondary)
            .disabled(!hasSelection)

            Menu {
                Section(tr("Carpeta")) {
                    Button(tr("Copiar a carpeta…")) { export(withVersions(selection), move: false) }
                    Button(tr("Mover a carpeta…")) { export(withVersions(selection), move: true) }
                }
                if !otherAlbums.isEmpty {
                    Section(tr("Copiar a álbum")) {
                        ForEach(otherAlbums) { other in
                            Button(other.name) { transfer(withVersions(selection), to: other.id, move: false) }
                        }
                    }
                    Section(tr("Mover a álbum")) {
                        ForEach(otherAlbums) { other in
                            Button(other.name) { transfer(withVersions(selection), to: other.id, move: true) }
                        }
                    }
                }
            } label: {
                Label(tr("Copiar o mover"), systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.lineStrong) }
            .disabled(!hasSelection)
            .opacity(hasSelection ? 1 : 0.4)

            Button {
                confirmDelete = withVersions(selection)
            } label: {
                Label(tr("Eliminar"), systemImage: "trash")
            }
            .buttonStyle(SmallButton.danger)
            .disabled(!hasSelection)

            Spacer()

            Menu {
                Picker(tr("Ordenar por"), selection: $settings.sort) {
                    ForEach(GallerySort.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle(tr("Descendente"), isOn: $settings.sortDescending)
                Toggle(tr("Agrupar versiones optimizadas"), isOn: $settings.groupVersions)
            } label: {
                Label(settings.sort.title, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Image(systemName: "square.grid.3x3").font(.system(size: 11)).foregroundStyle(Theme.text3)
            Slider(value: $settings.tileSize, in: 110...320)
                .frame(width: 110)
                .controlSize(.small)
            Image(systemName: "square.grid.2x2").font(.system(size: 13)).foregroundStyle(Theme.text3)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    // MARK: - Grid

    @ViewBuilder
    private func grid(_ items: [ImageItem]) -> some View {
        let size = settings.tileSize
        ZStack {
            if album?.images.isEmpty ?? true {
                emptyState
            } else if items.isEmpty {
                Text(tr("Ninguna imagen coincide con «%@».", search)).foregroundStyle(Theme.text3)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: size, maximum: size * 1.35), spacing: 16)],
                              alignment: .leading, spacing: 18) {
                        let versions = versionsByOriginal
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            tile(item, index: index, items: items, versions: versions[item.id] ?? [])
                        }
                    }
                    .padding(24)
                }
                .background {
                    // Clicking empty space clears the selection.
                    Color.clear.contentShape(Rectangle()).onTapGesture { selection = [] }
                }
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(Theme.accentSoft.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        Label(tr("Suelta para añadir al álbum"), systemImage: "square.and.arrow.down")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .padding(16)
                    .allowsHitTesting(false)
            }
            if library.importing {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(tr("Importando…"))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Theme.card, in: Capsule())
                    .overlay { Capsule().strokeBorder(Theme.line) }
                    .padding(.bottom, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            FileDrop.load(providers) { urls in importURLs(urls) }
            return true
        }
    }

    private func tile(_ item: ImageItem, index: Int, items: [ImageItem], versions: [ImageItem]) -> some View {
        let url = library.url(of: item, in: albumID)
        let selected = selection.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Checkerboard()
                    .overlay { Thumbnail(url: url, version: item.bytes).padding(6) }
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(selected ? Theme.accent : Theme.line, lineWidth: selected ? 3 : 1)
                    }
                    .overlay(alignment: .bottomLeading) {
                        Text(item.formatLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            .padding(8)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let duration = item.duration {
                            Label(Format.duration(duration), systemImage: "play.fill")
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                                .padding(8)
                        }
                    }
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Theme.accentFill)
                        .padding(8)
                }
            }
            Text(item.fileName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1).truncationMode(.middle)
            Text("\(item.dimensions) · \(Format.bytes(item.bytes))")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(Theme.text3)
            VersionBadge(item: item, versions: settings.groupVersions ? versions : [],
                         original: library.original(of: item, in: albumID))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { viewerIndex = index }
        .simultaneousGesture(TapGesture().onEnded { click(item, items: items) })
        .onDrag {
            // Drag out to Finder, a browser upload field, Figma…
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu { contextMenu(for: item, index: index) }
        .help(item.fileName)
    }

    @ViewBuilder
    private func contextMenu(for item: ImageItem, index: Int) -> some View {
        // Actions apply to the whole selection if the item is part of it.
        let ids = selection.contains(item.id) ? selection : [item.id]
        let targets = self.items.filter { ids.contains($0.id) }
        let otherAlbums = library.albums.filter { $0.id != albumID }
        Button(versionsByOriginal[item.id] == nil ? tr("Ver") : tr("Ver con sus versiones")) { viewerIndex = index }
        Button(tr("Mostrar en Finder")) {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map { library.url(of: $0, in: albumID) })
        }
        Button(tr("Copiar")) { copyToPasteboard(ids) }
        if ids.count == 1 {
            Button(tr("Renombrar…")) {
                renameText = item.name
                renaming = item
            }
        }
        Divider()
        Button(tr("Optimizar…")) { optimizing = targets }
        Button(tr("Copiar a carpeta…")) { export(withVersions(ids), move: false) }
        Button(tr("Mover a carpeta…")) { export(withVersions(ids), move: true) }
        if !otherAlbums.isEmpty {
            Menu(tr("Mover a álbum")) {
                ForEach(otherAlbums) { other in
                    Button(other.name) { transfer(withVersions(ids), to: other.id, move: true) }
                }
            }
            Menu(tr("Copiar a álbum")) {
                ForEach(otherAlbums) { other in
                    Button(other.name) { transfer(withVersions(ids), to: other.id, move: false) }
                }
            }
        }
        Divider()
        Button(tr("Mover a la papelera"), role: .destructive) { confirmDelete = withVersions(ids) }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 38, weight: .light)).foregroundStyle(Theme.text3)
            Text(tr("Arrastra imágenes, vídeos o carpetas aquí")).font(.system(size: 16, weight: .semibold))
            Text(tr("También puedes pegarlas con ⌘V o usar el botón «Añadir imágenes»."))
                .foregroundStyle(Theme.text2)
            Button(tr("Añadir imágenes"), action: chooseFilesToImport)
                .buttonStyle(.appSecondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func footer(_ items: [ImageItem]) -> some View {
        let selected = selectedItems
        return HStack {
            if selected.isEmpty {
                Text(hasVideos ? tr("%d elementos", items.count) : tr("%d imágenes", items.count))
            } else {
                Text(tr("%d seleccionadas · %@", selected.count, Format.bytes(selected.reduce(0) { $0 + $1.bytes })))
            }
            Spacer()
            Text(tr("Doble clic o Espacio para ver · arrastra una imagen fuera para usarla en otra app"))
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text3)
        .padding(.horizontal, 24)
        .frame(height: 30)
    }

    /// With grouping on, acting on an original also acts on its versions (they move,
    /// copy and go to the Trash together).
    private func withVersions(_ ids: Set<UUID>) -> Set<UUID> {
        guard settings.groupVersions else { return ids }
        let versions = versionsByOriginal
        return ids.union(ids.flatMap { versions[$0]?.map(\.id) ?? [] })
    }

    // MARK: - Selection

    private func click(_ item: ImageItem, items: [ImageItem]) {
        // Leave the search field, so Space and ⌘A act on the grid again.
        NSApp.keyWindow?.makeFirstResponder(nil)
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
            anchor = item.id
        } else if flags.contains(.shift), let anchor,
                  let from = items.firstIndex(where: { $0.id == anchor }),
                  let to = items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(items[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [item.id]
            anchor = item.id
        }
    }

    /// The selected image to open: the last one clicked, or the first of the selection.
    private func selectedIndex(in items: [ImageItem]) -> Int? {
        if let anchor, selection.contains(anchor), let index = items.firstIndex(where: { $0.id == anchor }) {
            return index
        }
        return items.firstIndex { selection.contains($0.id) }
    }

    // MARK: - Commands

    private func handle(_ command: AppCommand) {
        guard viewerIndex == nil || command == .importImages else {
            if case .copy = command, let index = viewerIndex, items.indices.contains(index) {
                copyToPasteboard([items[index].id])
            }
            return
        }
        switch command {
        case .selectAll: selection = Set(items.map(\.id))
        case .delete: if !selection.isEmpty { confirmDelete = withVersions(selection) }
        case .copy: if !selection.isEmpty { copyToPasteboard(selection) }
        case .paste: pasteFromPasteboard()
        case .importImages: chooseFilesToImport()
        case .open(let urls): importURLs(urls)
        default: break
        }
    }

    private func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .movie, .folder]
        panel.prompt = tr("Añadir")
        panel.message = tr("Elige imágenes, vídeos o carpetas.")
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    private func importURLs(_ urls: [URL]) {
        Task {
            let result = await library.importFiles(urls, into: albumID)
            if !result.failed.isEmpty {
                let names = result.failed.prefix(8).joined(separator: "\n")
                message = tr("No se pudieron añadir %d archivos:\n%@", result.failed.count, names)
            }
        }
    }

    private func export(_ ids: Set<UUID>, move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? tr("Mover aquí") : tr("Copiar aquí")
        panel.message = tr("%d imágenes", ids.count)
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        attempt {
            try library.export(ids, from: albumID, to: directory, move: move)
            if move { selection.subtract(ids) }
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }

    private func transfer(_ ids: Set<UUID>, to target: UUID, move: Bool) {
        attempt {
            try library.transfer(ids, from: albumID, to: target, move: move)
            if move { selection.subtract(ids) }
        }
    }

    private func copyToPasteboard(_ ids: Set<UUID>) {
        let urls = (album?.images ?? []).filter { ids.contains($0.id) }.map { library.url(of: $0, in: albumID) }
        guard !urls.isEmpty else { return }
        Clipboard.copy(urls)
    }

    /// ⌘V: image files copied in Finder, or image data (a screenshot copied with ⌃⇧⌘4…).
    private func pasteFromPasteboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            importURLs(urls)
            return
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let name = tr("Pegada %@", formatter.string(from: Date())) + ".png"
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("\(AppInfo.name)-paste-\(UUID().uuidString).png")
        attempt {
            try png.write(to: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            try library.addFile(at: temp, into: albumID, name: name)
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do { try work() } catch { message = error.localizedDescription }
    }
}

/// Under a tile: "3 versions · best −72 %" on an original, or how much a version saved.
struct VersionBadge: View {
    let item: ImageItem
    let versions: [ImageItem]
    let original: ImageItem?

    var body: some View {
        if let best = versions.min(by: { $0.bytes < $1.bytes }) {
            badge(symbol: "square.stack.3d.up.fill",
                  text: tr("%d versiones · mejor %@", versions.count, Format.change(from: item.bytes, to: best.bytes)),
                  good: best.bytes < item.bytes)
        } else if let info = item.optimization {
            // A version: compare with its original (or the size it had, if the original is gone).
            let before = original?.bytes ?? info.sourceBytes
            badge(symbol: "wand.and.stars",
                  text: "\(info.title) · \(Format.change(from: before, to: item.bytes))",
                  good: item.bytes < before)
        }
    }

    private func badge(symbol: String, text: String, good: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .medium)).monospacedDigit()
        .foregroundStyle(good ? Theme.ok : Theme.warn)
    }
}

/// Catches plain key presses in its window while no text is being edited and no sheet
/// is open (SwiftUI's `onKeyPress` needs focus, which the grid never has). The handler
/// returns true to swallow the key. Uses a local event monitor, like `ScrollZoomCatcher`.
struct KeyCatcher: NSViewRepresentable {
    static let space: UInt16 = 49

    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stop()
    }

    final class CatcherView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil,
                      !(window.firstResponder is NSText),
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                      self.onKey?(event) == true else { return event }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// Identifiable wrapper so a list of images can drive `.sheet(item:)`.
struct OptimizeBatch: Identifiable {
    let items: [ImageItem]
    var id: String { items.map(\.id.uuidString).joined() }
}

/// Smaller (28 pt) toolbar buttons.
enum SmallButton {
    static let secondary = AppButtonStyle(kind: .secondary, height: 28)
    static let danger = AppButtonStyle(kind: .danger, height: 28)
}

extension AppCommand: Equatable {
    static func == (lhs: AppCommand, rhs: AppCommand) -> Bool {
        switch (lhs, rhs) {
        case (.newAlbum, .newAlbum), (.importImages, .importImages), (.selectAll, .selectAll),
             (.delete, .delete), (.copy, .copy), (.paste, .paste), (.settings, .settings):
            return true
        case let (.open(a), .open(b)):
            return a == b
        default:
            return false
        }
    }
}
