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
                    topBar(shown.item)
                    HStack(spacing: 0) {
                        ZStack {
                            if comparing && shown.item.id != root.id {
                                CompareView(original: library.url(of: root, in: albumID), optimized: shown.url,
                                            originalLabel: tr("Original · %@", Format.bytes(root.bytes)),
                                            optimizedLabel: "\(shown.item.formatLabel) · \(Format.bytes(shown.item.bytes))")
                                    .padding(.horizontal, 70)
                                    .padding(.bottom, 24)
                            } else {
                                content(shown.item)
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

    private func topBar(_ item: ImageItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text("\(item.formatLabel) · \(item.dimensions) px · \(Format.bytes(item.bytes)) · \(index + 1)/\(items.count)")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.text3)
            }
            Spacer()
            SegmentedControl(options: [(tr("Ajustar"), false), ("100 %", true)], selection: $actualSize)
                .help(tr("Tecla 0"))
            IconButton(symbol: "folder", label: tr("Mostrar en Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([library.url(of: item, in: albumID)])
            }
            IconButton(symbol: "doc.on.doc", label: tr("Copiar")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([library.url(of: item, in: albumID) as NSURL])
            }
            IconButton(symbol: "xmark", label: tr("Cerrar"), kind: .secondary, action: close)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func content(_ item: ImageItem) -> some View {
        if let image {
            if actualSize {
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: CGFloat(item.width) / scale, height: CGFloat(item.height) / scale)
                        .background(Checkerboard())
                }
            } else {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .background(Checkerboard())
                    .padding(.horizontal, 70)
                    .padding(.bottom, 24)
            }
        } else {
            ProgressView()
        }
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
            Text(tr("↑ ↓ cambian de versión"))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
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
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.accentBorder : Theme.line) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(version.fileName)
    }
}

/// Before/after split view: drag the divider to compare.
struct CompareView: View {
    let original: URL
    let optimized: URL
    let originalLabel: String
    let optimizedLabel: String

    @State private var split: CGFloat = 0.5
    @State private var before: NSImage?
    @State private var after: NSImage?
    @State private var zoom = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Checkerboard()
                ZStack {
                    imageView(after)
                    imageView(before)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: size.width * split)
                        }
                }
                .scaleEffect(zoom ? 3 : 1, anchor: .center)
                .clipped()

                Rectangle().fill(.white).frame(width: 2)
                    .position(x: size.width * split, y: size.height / 2)
                    .shadow(radius: 2)
                Circle().fill(.white).frame(width: 26, height: 26)
                    .overlay { Image(systemName: "arrow.left.and.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black) }
                    .position(x: size.width * split, y: size.height / 2)

                VStack {
                    HStack {
                        badge(originalLabel)
                        Spacer()
                        badge(optimizedLabel)
                    }
                    Spacer()
                }
                .padding(10)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                split = min(1, max(0, value.location.x / max(1, size.width)))
            })
            .onTapGesture(count: 2) { zoom.toggle() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line) }
        .task(id: optimized) {
            let (a, b) = (original, optimized)
            before = await Task.detached { NSImage(contentsOf: a) }.value
            after = await Task.detached { NSImage(contentsOf: b) }.value
        }
    }

    @ViewBuilder
    private func imageView(_ image: NSImage?) -> some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
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
}
