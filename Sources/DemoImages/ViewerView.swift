import AppKit
import SwiftUI

/// Full-window image viewer over the gallery. ← / → to browse, Esc or Space to close.
struct ViewerView: View {
    let albumID: UUID
    let items: [ImageItem]
    @Binding var index: Int
    let close: () -> Void
    let optimize: (ImageItem) -> Void

    @ObservedObject private var library = Library.shared
    @State private var image: NSImage?
    @State private var actualSize = false
    @FocusState private var focused: Bool

    private var item: ImageItem? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            if let item {
                VStack(spacing: 0) {
                    topBar(item)
                    ZStack {
                        content(item)
                        HStack {
                            arrow("chevron.left", enabled: index > 0) { step(-1) }
                            Spacer()
                            arrow("chevron.right", enabled: index < items.count - 1) { step(1) }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress("0") { actualSize.toggle(); return .handled }
        .task(id: item.map { "\($0.id)|\($0.fileName)" }) { await load() }
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
            Button {
                optimize(item)
            } label: {
                Label(tr("Optimizar…"), systemImage: "wand.and.stars")
            }
            .buttonStyle(.appSecondary)
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
        index = next
    }

    private func load() async {
        guard let item else { return }
        let url = library.url(of: item, in: albumID)
        image = ThumbnailCache.shared.cached(url, maxPixel: ThumbnailSize.grid)
        let full = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        if self.item?.id == item.id { image = full ?? image }
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
