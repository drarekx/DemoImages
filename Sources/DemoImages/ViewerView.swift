import AppKit
import SwiftUI

/// Full-window image viewer over the gallery. ← / → to browse images, ↑ / ↓ to go
/// through the open image's versions, C to compare, Esc or Space to close.
struct ViewerView: View {
    let albumID: UUID
    let items: [ImageItem]
    @Binding var index: Int
    let close: () -> Void
    let optimize: (ImageItem) -> Void

    @ObservedObject private var library = Library.shared
    @State private var image: NSImage?
    @State private var actualSize = false
    /// The version shown (nil = the image opened from the grid).
    @State private var shownID: UUID?
    @State private var comparing = false
    @FocusState private var focused: Bool

    private var item: ImageItem? { items.indices.contains(index) ? items[index] : nil }

    /// The original of the open image (itself, unless it is a version).
    private var root: ImageItem? {
        guard let item else { return nil }
        return library.original(of: item, in: albumID) ?? item
    }

    /// Original first, then its versions, smallest first.
    private var group: [ImageItem] {
        guard let root else { return [] }
        return [root] + library.versions(of: root.id, in: albumID)
    }

    private var shown: ItemAndURL? {
        guard let item else { return nil }
        let current = group.first { $0.id == (shownID ?? item.id) } ?? item
        return ItemAndURL(item: current, url: library.url(of: current, in: albumID))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            if let shown, let root {
                VStack(spacing: 0) {
                    topBar(shown.item, root: root)
                    HStack(spacing: 0) {
                        ZStack {
                            if comparing && shown.item.id != root.id {
                                CompareView(original: library.url(of: root, in: albumID), optimized: shown.url,
                                            originalLabel: tr("Original · %@", Format.bytes(root.bytes)),
                                            optimizedLabel: "\(shown.item.formatLabel) · \(Format.bytes(shown.item.bytes))")
                                    .contextMenu {
                                        Button(tr("Copiar original")) { Clipboard.copy([library.url(of: root, in: albumID)]) }
                                        Button(tr("Copiar optimizada")) { Clipboard.copy([shown.url]) }
                                    }
                                    .padding(.horizontal, 70)
                                    .padding(.bottom, 24)
                            } else {
                                content(shown)
                            }
                            HStack {
                                arrow("chevron.left", enabled: index > 0) { step(-1) }
                                Spacer()
                                arrow("chevron.right", enabled: index < items.count - 1) { step(1) }
                            }
                            .padding(.horizontal, 16)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        VersionsPanel(albumID: albumID, root: root, group: group, shownID: shown.item.id,
                                      comparing: $comparing, select: { shownID = $0 },
                                      optimize: { optimize(root) })
                    }
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.upArrow) { stepVersion(-1); return .handled }
        .onKeyPress(.downArrow) { stepVersion(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress("0") { actualSize.toggle(); return .handled }
        .onKeyPress("c") { comparing.toggle(); return .handled }
        .task(id: shown.map { "\($0.item.id)|\($0.item.fileName)" }) { await load() }
    }

    /// Says plainly which file is on screen: format, original or version, size, saving, settings.
    private func topBar(_ item: ImageItem, root: ImageItem) -> some View {
        let isVersion = item.id != root.id
        let versionCount = group.count - 1
        return HStack(spacing: 12) {
            Text(item.formatLabel)
                .font(.system(size: 15, weight: .bold)).monospaced()
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(isVersion ? Theme.accentFill : Theme.control, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(isVersion ? .clear : Theme.lineStrong) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(isVersion ? tr("Versión optimizada") : tr("Original"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isVersion ? Theme.accentText : Theme.text2)
                    Text(item.fileName).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Text("\(item.dimensions) px · \(Format.bytes(item.bytes))").foregroundStyle(Theme.text)
                    if isVersion {
                        Text(tr("%@ que el original (%@)", Format.change(from: root.bytes, to: item.bytes), Format.bytes(root.bytes)))
                            .fontWeight(.semibold)
                            .foregroundStyle(item.bytes < root.bytes ? Theme.ok : Theme.warn)
                        if let info = item.optimization {
                            Text("· \(info.summary)").foregroundStyle(Theme.text3)
                        }
                    } else if versionCount > 0 {
                        Text(tr("· %d versiones optimizadas", versionCount)).foregroundStyle(Theme.text3)
                    }
                    Text("· \(index + 1)/\(items.count)").foregroundStyle(Theme.text3)
                }
                .font(.system(size: 12)).monospacedDigit().lineLimit(1)
            }
            Spacer()
            SegmentedControl(options: [(tr("Ajustar"), false), ("100 %", true)], selection: $actualSize)
                .help(tr("Tecla 0"))
            IconButton(symbol: "folder", label: tr("Mostrar en Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([library.url(of: item, in: albumID)])
            }
            IconButton(symbol: "doc.on.doc", label: tr("Copiar")) {
                Clipboard.copy([library.url(of: item, in: albumID)])
            }
            IconButton(symbol: "xmark", label: tr("Cerrar"), kind: .secondary, action: close)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func content(_ shown: ItemAndURL) -> some View {
        let item = shown.item
        if let image {
            // Drag the image out (browser upload, Finder…): it carries the file on screen.
            if actualSize {
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(item.width) / scale, height: CGFloat(item.height) / scale)
                        .background(Checkerboard())
                        .onDrag { NSItemProvider(contentsOf: shown.url) ?? NSItemProvider() }
                        .contextMenu { fileMenu(shown.url) }
                }
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .background(Checkerboard())
                    .onDrag { NSItemProvider(contentsOf: shown.url) ?? NSItemProvider() }
                    .contextMenu { fileMenu(shown.url) }
                    .padding(.horizontal, 70)
                    .padding(.bottom, 24)
            }
        } else {
            ProgressView()
        }
    }

    @ViewBuilder
    private func fileMenu(_ url: URL) -> some View {
        Button(tr("Copiar")) { Clipboard.copy([url]) }
        Button(tr("Mostrar en Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.5), in: Circle())
                .overlay { Circle().strokeBorder(Theme.lineStrong) }
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        shownID = nil
        comparing = false
        index = next
    }

    private func stepVersion(_ delta: Int) {
        let group = self.group
        guard let current = shown?.item.id, let position = group.firstIndex(where: { $0.id == current }) else { return }
        let next = position + delta
        guard group.indices.contains(next) else { return }
        shownID = group[next].id
    }

    private func load() async {
        guard let shown else { return }
        let url = shown.url
        image = ThumbnailCache.shared.cached(url, maxPixel: ThumbnailSize.grid)
        let full = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if self.shown?.item.id == shown.item.id { image = full ?? image }
    }
}

private struct ItemAndURL {
    let item: ImageItem
    let url: URL
}

/// Right-hand panel: the original and its optimized versions, with sizes and savings.
private struct VersionsPanel: View {
    let albumID: UUID
    let root: ImageItem
    let group: [ImageItem]
    let shownID: UUID
    @Binding var comparing: Bool
    let select: (UUID) -> Void
    let optimize: () -> Void

    @ObservedObject private var library = Library.shared

    var body: some View {
        let versions = Array(group.dropFirst())
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(tr("Versiones"))
                Spacer()
                Text("\(versions.count)").monospacedText(size: 11).foregroundStyle(Theme.text3)
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(group) { version in
                        row(version, isOriginal: version.id == root.id)
                    }
                }
            }
            if versions.isEmpty {
                Text(tr("Aún no hay versiones optimizadas de esta imagen."))
                    .font(.system(size: 12)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let best = versions.min(by: { $0.bytes < $1.bytes }) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Mejor versión")).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    Text("\(best.formatLabel) · \(Format.bytes(best.bytes)) · \(Format.change(from: root.bytes, to: best.bytes))")
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(best.bytes < root.bytes ? Theme.ok : Theme.warn)
                    Text(tr("Ahorra %@", Format.bytes(max(0, root.bytes - best.bytes))))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
            }
            if shownID != root.id {
                Toggle(tr("Comparar con el original (C)"), isOn: $comparing)
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accentFill)
            }
            Button(action: optimize) {
                Label(tr("Optimizar…"), systemImage: "wand.and.stars")
            }
            .buttonStyle(AppButtonStyle(kind: .secondary, height: 30, fullWidth: true))
            Text(tr("↑ ↓ cambian de versión · arrastra una fila o la imagen fuera de la app para subirla o guardarla"))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar.opacity(0.92))
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 1) }
    }

    private func row(_ version: ImageItem, isOriginal: Bool) -> some View {
        let selected = version.id == shownID
        return Button {
            select(version.id)
        } label: {
            HStack(spacing: 10) {
                Checkerboard(square: 5)
                    .overlay { Thumbnail(url: library.url(of: version, in: albumID), maxPixel: ThumbnailSize.small, version: version.bytes).padding(2) }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(isOriginal ? tr("Original") : version.formatLabel).fontWeight(.semibold)
                        if isOriginal {
                            Text(version.formatLabel).foregroundStyle(Theme.text3)
                        }
                        Spacer(minLength: 0)
                        if !isOriginal {
                            Text(Format.change(from: root.bytes, to: version.bytes))
                                .fontWeight(.semibold)
                                .foregroundStyle(version.bytes < root.bytes ? Theme.ok : Theme.warn)
                        }
                    }
                    .font(.system(size: 12)).monospacedDigit()
                    Text("\(Format.bytes(version.bytes)) · \(version.dimensions)")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text2)
                    if let info = version.optimization {
                        Text(info.summary).font(.system(size: 10)).foregroundStyle(Theme.text3).lineLimit(2)
                    }
                }
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .help(tr("Arrastra para usarla en otra app"))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accentBorder : Theme.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Drag a version out (browser upload, Finder…) without leaving the viewer.
        .onDrag { NSItemProvider(contentsOf: library.url(of: version, in: albumID)) ?? NSItemProvider() }
        .contextMenu {
            Button(tr("Copiar")) { Clipboard.copy([library.url(of: version, in: albumID)]) }
            Button(tr("Mostrar en Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([library.url(of: version, in: albumID)])
            }
        }
        .help(version.fileName)
    }
}

/// Before/after split view, like Squoosh: drag the divider to compare, zoom towards
/// the pointer with the mouse wheel or a pinch, pan by dragging the image or with two
/// fingers, double-click to toggle between fit and real pixels (1:1).
struct CompareView: View {
    let original: URL
    let optimized: URL
    let originalLabel: String
    let optimizedLabel: String

    @State private var split: CGFloat = 0.5
    @State private var before: NSImage?
    @State private var after: NSImage?
    /// 1 = image fitted to the view.
    @State private var scale: CGFloat = 1
    /// Pan, in view points.
    @State private var offset: CGSize = .zero
    @State private var drag: DragMode?

    private enum DragMode {
        case divider
        case pan(from: CGSize)
    }

    private static let maxScale: CGFloat = 32

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Checkerboard()
                ZStack {
                    imageLayer(after)
                    imageLayer(before)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: size.width * split)
                        }
                }
                .clipped()

                Rectangle().fill(.white).frame(width: 2)
                    .position(x: size.width * split, y: size.height / 2)
                    .shadow(radius: 2)
                Circle().fill(.white).frame(width: 30, height: 30)
                    .overlay { Image(systemName: "arrow.left.and.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.black) }
                    .shadow(radius: 3)
                    .position(x: size.width * split, y: size.height / 2)

                VStack {
                    HStack {
                        badge(originalLabel)
                        Spacer()
                        badge(optimizedLabel)
                    }
                    Spacer()
                    zoomBar(size)
                }
                .padding(10)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                toggleZoom(at: value.location, in: size)
            })
            .background {
                // Wheel and pinch reach SwiftUI as nothing; catch them for this area only.
                ScrollZoomCatcher { event in
                    handle(event, in: size)
                }
            }
            .onChange(of: size) { _, _ in clampOffset(size) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
        .task(id: optimized) {
            let (a, b) = (original, optimized)
            before = await Task.detached { NSImage(contentsOf: a) }.value
            after = await Task.detached { NSImage(contentsOf: b) }.value
        }
    }

    // MARK: - Drawing

    @ViewBuilder
    private func imageLayer(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                // Enlarged pixels stay sharp so compression artifacts are visible.
                .interpolation(scale >= 2 ? .none : .high)
                .scaledToFit()
                .scaleEffect(scale)
                .offset(offset)
        } else {
            ProgressView()
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
    }

    private func zoomBar(_ size: CGSize) -> some View {
        HStack(spacing: 2) {
            zoomButton("minus", tr("Alejar")) { zoom(by: 1 / 1.5, at: center(size), in: size) }
            Text(zoomLabel(size))
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .frame(minWidth: 52)
            zoomButton("plus", tr("Acercar")) { zoom(by: 1.5, at: center(size), in: size) }
            Rectangle().fill(.white.opacity(0.2)).frame(width: 1, height: 16).padding(.horizontal, 4)
            Button(tr("Ajustar")) { reset() }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 28)
            Button("1:1") { setScale(realPixelScale(size), at: center(size), in: size) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                .padding(.horizontal, 8)
                .frame(height: 28)
                .help(tr("Píxeles reales"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .background(.black.opacity(0.7), in: Capsule())
    }

    private func zoomButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Gestures

    /// Dragging the divider moves it; dragging anywhere else pans.
    private func dragGesture(_ size: CGSize) -> some Gesture {
        // A few points of travel, so a double-click doesn't move the divider.
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if drag == nil {
                    let nearDivider = abs(value.startLocation.x - size.width * split) < 22
                    drag = nearDivider || scale <= 1 ? .divider : .pan(from: offset)
                }
                switch drag {
                case .divider:
                    split = min(1, max(0, value.location.x / max(1, size.width)))
                case .pan(let from):
                    offset = CGSize(width: from.width + value.translation.width,
                                    height: from.height + value.translation.height)
                    clampOffset(size)
                case nil:
                    break
                }
            }
            .onEnded { _ in drag = nil }
    }

    private func handle(_ event: ScrollZoomCatcher.Event, in size: CGSize) {
        switch event {
        case .magnify(let amount, let location):
            zoom(by: 1 + amount, at: location, in: size)
        case .scroll(let dx, let dy, let precise, let location):
            if precise {
                // Trackpad: two fingers pan (only when zoomed in).
                guard scale > 1 else { return }
                offset = CGSize(width: offset.width + dx, height: offset.height + dy)
                clampOffset(size)
            } else {
                // Mouse wheel: zoom towards the pointer.
                zoom(by: pow(1.2, max(-5, min(5, dy))), at: location, in: size)
            }
        }
    }

    private func toggleZoom(at point: CGPoint, in size: CGSize) {
        if scale > 1.01 {
            reset()
        } else {
            setScale(max(2, realPixelScale(size)), at: point, in: size)
        }
    }

    // MARK: - Zoom maths

    private func center(_ size: CGSize) -> CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    private func zoom(by factor: CGFloat, at point: CGPoint, in size: CGSize) {
        setScale(scale * factor, at: point, in: size)
    }

    /// Changes the scale keeping the image point under `point` where it is.
    private func setScale(_ newScale: CGFloat, at point: CGPoint, in size: CGSize) {
        let target = min(Self.maxScale, max(1, newScale))
        guard target != scale else { return }
        let c = center(size)
        let ratio = target / scale
        offset = CGSize(width: (point.x - c.x) - (point.x - c.x - offset.width) * ratio,
                        height: (point.y - c.y) - (point.y - c.y - offset.height) * ratio)
        scale = target
        if scale <= 1 { offset = .zero }
        clampOffset(size)
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.15)) {
            scale = 1
            offset = .zero
        }
    }

    /// Keeps at least part of the image in view.
    private func clampOffset(_ size: CGSize) {
        let maxX = size.width * (scale - 1) / 2 + size.width * 0.25
        let maxY = size.height * (scale - 1) / 2 + size.height * 0.25
        offset = CGSize(width: min(maxX, max(-maxX, offset.width)),
                        height: min(maxY, max(-maxY, offset.height)))
        if scale <= 1 { offset = .zero }
    }

    /// Size of the original in pixels.
    private var pixelSize: CGSize? {
        guard let image = before ?? after else { return nil }
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }

    /// Screen pixels per image pixel when fitted.
    private func fitFactor(_ size: CGSize) -> CGFloat {
        guard let pixels = pixelSize, pixels.width > 0, pixels.height > 0 else { return 1 }
        let backing = NSScreen.main?.backingScaleFactor ?? 2
        return min(size.width / pixels.width, size.height / pixels.height) * backing
    }

    /// The scale at which one image pixel is one screen pixel.
    private func realPixelScale(_ size: CGSize) -> CGFloat {
        1 / max(0.0001, fitFactor(size))
    }

    /// "100 %" = real pixels.
    private func zoomLabel(_ size: CGSize) -> String {
        "\(Int((fitFactor(size) * scale * 100).rounded())) %"
    }
}

/// Catches mouse-wheel, trackpad-scroll and pinch events over its area (SwiftUI has no
/// scroll-wheel gesture on macOS). Uses a local event monitor so it never steals clicks.
struct ScrollZoomCatcher: NSViewRepresentable {
    enum Event {
        /// Location in the view, top-left origin.
        case scroll(dx: CGFloat, dy: CGFloat, precise: Bool, location: CGPoint)
        case magnify(amount: CGFloat, location: CGPoint)
    }

    let onEvent: (Event) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onEvent = onEvent
    }

    static func dismantleNSView(_ view: CatcherView, coordinator: ()) {
        view.stop()
    }

    final class CatcherView: NSView {
        var onEvent: ((Event) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(point) else { return event }
                switch event.type {
                case .magnify:
                    self.onEvent?(.magnify(amount: event.magnification, location: point))
                case .scrollWheel:
                    self.onEvent?(.scroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                          precise: event.hasPreciseScrollingDeltas, location: point))
                default:
                    return event
                }
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        // Clicks go through to SwiftUI.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
