import AppKit
import SwiftUI

/// Optimize sheet: choose format and settings, encode to a temp folder, compare sizes
/// (and pixels), then save as copies, replace the originals or export.
struct OptimizeSheet: View {
    let albumID: UUID
    let items: [ImageItem]
    let close: () -> Void

    @ObservedObject private var library = Library.shared
    @ObservedObject private var settings = Settings.shared
    @StateObject private var runner = OptimizeRunner()
    @State private var comparing: UUID?
    @State private var message: String?
    /// Images and videos have different settings; a mixed batch does one kind at a time.
    @State private var videoChoice: Bool?

    private var images: [ImageItem] { items.filter { !$0.isVideo } }
    private var videos: [ImageItem] { items.filter(\.isVideo) }
    private var isVideo: Bool { videoChoice ?? images.isEmpty }

    private var options: OptimizeOptions { settings.optimize }
    private var videoOptions: VideoOptions { settings.optimizeVideo }
    private var stale: Bool {
        runner.encodedKey != nil && (runner.encodedKey != encodingKey || runner.results.count != targets.count)
    }

    // The settings in use, whichever kind is being optimized.
    private var encodingKey: String { isVideo ? videoOptions.encodingKey : options.encodingKey }
    private var codecID: String { isVideo ? videoOptions.codec.rawValue : options.codec.rawValue }
    private var codecTitle: String { isVideo ? videoOptions.codec.title : options.codec.title }
    private var fileExtension: String { isVideo ? videoOptions.codec.fileExtension : options.codec.fileExtension }
    private var codecAvailable: Bool { isVideo || options.codec.isAvailable }
    private var destination: OptimizeDestination { isVideo ? videoOptions.destination : options.destination }
    private var onlyIfSmaller: Bool { isVideo ? videoOptions.onlyIfSmaller : options.onlyIfSmaller }

    private func info(for source: ImageItem) -> OptimizationInfo {
        isVideo ? OptimizationInfo(video: videoOptions, source: source) : OptimizationInfo(options: options, source: source)
    }

    /// The original each image hangs from: optimizing a version links the result to its original.
    private func root(of item: ImageItem) -> ImageItem {
        library.original(of: item, in: albumID) ?? item
    }

    /// The images, or the videos, of the batch.
    private var pool: [ImageItem] { isVideo ? videos : images }

    /// Those that already have a version in the chosen format.
    private var alreadyOptimized: [ImageItem] {
        pool.filter { item in
            library.versions(of: root(of: item).id, in: albumID).contains { $0.optimization?.codecID == codecID }
        }
    }

    /// What gets encoded: the whole pool, or those without a version in this format yet.
    private var targets: [ImageItem] {
        guard settings.skipOptimized else { return pool }
        let skip = Set(alreadyOptimized.map(\.id))
        return pool.filter { !skip.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !images.isEmpty && !videos.isEmpty {
                        SegmentedControl(options: [(tr("Imágenes (%d)", images.count), false),
                                                   (tr("Vídeos (%d)", videos.count), true)],
                                         selection: Binding(get: { isVideo }, set: { choice in
                                             guard choice != isVideo else { return }
                                             videoChoice = choice
                                             comparing = nil
                                             runner.reset()
                                         }), expand: true)
                    }
                    if isVideo {
                        VideoSettingsForm(options: $settings.optimizeVideo)
                    } else {
                        OptimizeSettingsForm(options: $settings.optimize)
                    }
                }
                .padding(20)
            }
            .frame(width: 330)
            .background(Theme.sidebar)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                resultsHeader
                if !alreadyOptimized.isEmpty {
                    skipBar
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                if let id = comparing, let result = runner.results.first(where: { $0.id == id }), let output = result.output {
                    compare(result, output: output)
                } else {
                    resultsList
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                actions
            }
        }
        .frame(width: 980, height: 640)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .font(.system(size: 13))
        .preferredColorScheme(.dark)
        .onAppear {
            // A whole album can be hundreds of images, and one video can take minutes:
            // wait for "Try" instead of starting at once.
            if !isVideo && targets.count <= 12 { encode() }
        }
        .onDisappear { runner.cleanup() }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button(tr("Aceptar")) {}
        }
    }

    // MARK: - Results

    private var resultsHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isVideo ? tr("Optimizar %d vídeos", targets.count) : tr("Optimizar %d imágenes", targets.count))
                    .font(.system(size: 16, weight: .semibold))
                if runner.results.isEmpty || stale {
                    Text(stale ? tr("Los ajustes cambiaron: vuelve a probar para ver el resultado.") : tr("Pulsa «Probar» para ver cuánto ocupan."))
                        .font(.system(size: 12)).foregroundStyle(stale ? Theme.warn : Theme.text3)
                } else {
                    let before = runner.totalBefore, after = runner.totalAfter
                    Text("\(Format.bytes(before)) → \(Format.bytes(after))  \(Format.change(from: before, to: after))")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .foregroundStyle(after < before ? Theme.ok : Theme.danger)
                }
            }
            Spacer()
            if runner.running {
                ProgressView(value: Double(runner.finished), total: Double(max(1, runner.results.count)))
                    .frame(width: 120)
                Button(tr("Detener")) { runner.cancel() }
                    .buttonStyle(.appSecondary)
            } else {
                Button {
                    encode()
                } label: {
                    Label(tr("Probar"), systemImage: "play.fill")
                }
                .buttonStyle(.appSecondary)
                .disabled(!codecAvailable)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    /// "N already have a WebP version" with the switch to skip them.
    private var skipBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up").foregroundStyle(Theme.accentText)
            Text(tr("%d ya tienen una versión %@.", alreadyOptimized.count, codecTitle))
                .foregroundStyle(Theme.text2)
            Spacer()
            Toggle(tr("Omitirlas"), isOn: $settings.skipOptimized)
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accentFill)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.field)
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(runner.results) { result in
                    row(result)
                    Rectangle().fill(Theme.line).frame(height: 1)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .opacity(stale ? 0.5 : 1)
    }

    private func row(_ result: OptimizeResult) -> some View {
        HStack(spacing: 12) {
            Checkerboard(square: 5)
                .overlay { Thumbnail(url: result.source, maxPixel: ThumbnailSize.small).padding(2) }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(result.item.fileName).lineLimit(1).truncationMode(.middle)
                Text(([result.item.formatLabel, result.item.dimensions]
                      + (result.item.duration.map { [Format.duration($0)] } ?? [])).joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Spacer()
            switch result.status {
            case .pending:
                Text(tr("En cola")).font(.system(size: 12)).foregroundStyle(Theme.text3)
            case .running:
                ProgressView().controlSize(.small)
            case .failed:
                Text(result.error ?? tr("Error"))
                    .font(.system(size: 11)).foregroundStyle(Theme.danger)
                    .lineLimit(3).frame(maxWidth: 340, alignment: .trailing)
                    .textSelection(.enabled)
            case .done:
                let after = result.outputBytes ?? 0
                HStack(spacing: 10) {
                    Text(Format.bytes(result.item.bytes)).foregroundStyle(Theme.text3)
                    Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.text3)
                    Text(Format.bytes(after)).fontWeight(.semibold)
                    Text(Format.change(from: result.item.bytes, to: after))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(result.isSmaller ? Theme.ok : Theme.danger)
                        .frame(width: 58, alignment: .trailing)
                }
                .monospacedDigit()
                Button(tr("Comparar")) { comparing = result.id }
                    .buttonStyle(SmallButton.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func compare(_ result: OptimizeResult, output: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    comparing = nil
                } label: {
                    Label(tr("Volver a la lista"), systemImage: "chevron.left")
                }
                .buttonStyle(SmallButton.secondary)
                Text(result.item.fileName).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(tr("Arrastra la línea para comparar · rueda o pellizco para ampliar · arrastra para moverte"))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            CompareView(original: result.source, optimized: output,
                        originalLabel: tr("Original · %@", Format.bytes(result.item.bytes)),
                        optimizedLabel: "\(codecTitle) · \(Format.bytes(result.outputBytes ?? 0))")
                .contextMenu {
                    Button(tr("Copiar original")) { Clipboard.copy([result.source]) }
                    Button(tr("Copiar optimizada")) { Clipboard.copy([output]) }
                }
        }
        .padding(16)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Saving

    private var actions: some View {
        HStack(spacing: 10) {
            Text(destinationHint).font(.system(size: 11)).foregroundStyle(Theme.text3)
            Spacer()
            Button(tr("Cerrar"), action: close)
                .buttonStyle(.appGhost)
                .keyboardShortcut(.cancelAction)
            Button(saveTitle, action: save)
                .buttonStyle(.appPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(runner.running || stale || runner.results.allSatisfy { $0.status != .done })
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    private var saveTitle: String {
        switch destination {
        case .copyInAlbum: return tr("Guardar copias")
        case .replace: return tr("Reemplazar originales")
        case .exportFolder: return tr("Exportar…")
        }
    }

    private var destinationHint: String {
        onlyIfSmaller ? tr("Se omiten las que no ocupen menos que el original.") : ""
    }

    private func encode() {
        let targets = self.targets
        guard codecAvailable, !targets.isEmpty else {
            runner.reset()
            return
        }
        comparing = nil
        let files = targets.map { ($0, library.url(of: $0, in: albumID)) }
        if isVideo {
            // Video encoders already use every core: one or two at a time is plenty.
            let options = videoOptions
            runner.start(files, key: options.encodingKey, limit: 2) {
                try await VideoEncoder.encode($0, options: options, in: $1)
            }
        } else {
            let options = self.options
            runner.start(files, key: options.encodingKey) {
                try await ImageEncoder.encode($0, options: options, in: $1)
            }
        }
    }

    private func save() {
        let done = runner.results.filter { $0.status == .done && $0.output != nil }
        let accepted = done.filter { !onlyIfSmaller || $0.isSmaller }
        let destination = self.destination
        let skipped = done.count - accepted.count
        var errors: [String] = []
        var saved = 0

        var exportDirectory: URL?
        if destination == .exportFolder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = tr("Exportar aquí")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            exportDirectory = url
        }

        for result in accepted {
            guard let output = result.output else { continue }
            do {
                switch destination {
                case .copyInAlbum:
                    // Linked to the original, so it shows among that image's versions.
                    let original = root(of: result.item)
                    try library.addFile(at: output, into: albumID, name: output.lastPathComponent,
                                        sourceID: original.id,
                                        optimization: info(for: original))
                case .replace:
                    try library.replace(result.item.id, in: albumID, with: output, fileExtension: fileExtension,
                                        optimization: info(for: result.item))
                case .exportFolder:
                    guard let exportDirectory else { continue }
                    let name = Library.uniqueName(output.lastPathComponent, in: exportDirectory)
                    try FileManager.default.copyItem(at: output, to: exportDirectory.appendingPathComponent(name))
                }
                saved += 1
            } catch {
                errors.append("\(result.item.fileName): \(error.localizedDescription)")
            }
        }

        if let exportDirectory, saved > 0 {
            NSWorkspace.shared.activateFileViewerSelecting([exportDirectory])
        }
        if errors.isEmpty && skipped == 0 {
            close()
        } else {
            var text = tr("Guardadas: %d. Omitidas por no ocupar menos: %d.", saved, skipped)
            if !errors.isEmpty { text += "\n\n" + errors.prefix(6).joined(separator: "\n") }
            message = text
            if errors.isEmpty { runner.reset() }
        }
    }
}

// MARK: - Settings form

struct OptimizeSettingsForm: View {
    @Binding var options: OptimizeOptions

    var body: some View {
        let codec = options.codec
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(tr("Formato"))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    ForEach(Codec.allCases) { item in
                        codecButton(item)
                    }
                }
                if let tool = codec.requiredTool, !tool.isInstalled {
                    ToolHint(tools: [tool], text: tr("%@ necesita %@.", codec.title, tool.executableName))
                } else if let tool = codec.enhancingTool, !tool.isInstalled {
                    ToolHint(tools: [tool], text: tr("Con %@ se obtienen archivos más pequeños o más ajustes.", tool.executableName))
                }
            }

            if codec.supportsLossless {
                SwitchRow(title: tr("Sin pérdida"), detail: tr("Píxeles idénticos al original; archivos más grandes."), isOn: $options.lossless)
            }

            if codec.usesQuality && !options.lossless {
                sliderRow(tr("Calidad"), value: $options.quality, range: 0...100, step: 1,
                          label: "\(Int(options.quality))")
            }

            if let range = codec.effortRange {
                sliderRow(tr("Esfuerzo"), value: Binding(
                    get: { Double(options.effort) },
                    set: { options.effort = Int($0.rounded()) }),
                    range: Double(range.lowerBound)...Double(range.upperBound), step: 1,
                    label: "\(options.effort)",
                    detail: tr("Más esfuerzo: archivo más pequeño, pero tarda más."))
            }

            if codec == .png {
                VStack(alignment: .leading, spacing: 4) {
                    SwitchRow(title: tr("Reducir paleta"), detail: tr("Como «Reduce palette» de Squoosh (pngquant)."), isOn: $options.quantize)
                    if options.quantize {
                        if !ExternalTool.pngquant.isInstalled {
                            ToolHint(tools: [.pngquant], text: tr("Necesita pngquant."))
                        }
                        sliderRow(tr("Colores"), value: Binding(
                            get: { Double(options.colors) },
                            set: { options.colors = Int($0.rounded()) }),
                            range: 2...256, step: 1, label: "\(options.colors)")
                        sliderRow(tr("Tramado"), value: $options.dither, range: 0...1, step: 0.05,
                                  label: String(format: "%.2f", options.dither))
                    }
                }
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            VStack(alignment: .leading, spacing: 8) {
                SwitchRow(title: tr("Redimensionar"), detail: tr("Lanczos, sin agrandar nunca. 0 = sin límite."), isOn: $options.resize)
                if options.resize {
                    HStack(spacing: 10) {
                        numberField(tr("Ancho máx."), value: $options.maxWidth)
                        Text("×").foregroundStyle(Theme.text3)
                        numberField(tr("Alto máx."), value: $options.maxHeight)
                    }
                    HStack(spacing: 6) {
                        ForEach([640, 1280, 1920, 3840], id: \.self) { width in
                            Button("\(width)") {
                                options.maxWidth = width
                                options.maxHeight = 0
                            }
                            .buttonStyle(AppButtonStyle(kind: .ghost, height: 24))
                        }
                    }
                }
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            SaveSettings(destination: $options.destination, onlyIfSmaller: $options.onlyIfSmaller)

            Button(tr("Valores de Squoosh")) { options.selectCodec(options.codec) }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 26))
        }
    }

    private func codecButton(_ codec: Codec) -> some View {
        let selected = options.codec == codec
        return Button {
            options.selectCodec(codec)
        } label: {
            VStack(spacing: 2) {
                Text(codec.title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                if !codec.isAvailable {
                    Text(tr("falta herramienta")).font(.system(size: 9)).foregroundStyle(Theme.warn)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(selected ? Theme.accentSoft : Theme.field, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(selected ? Theme.accentBorder : Theme.line)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                           label: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label).monospacedText(size: 12).foregroundStyle(Theme.text2)
            }
            Slider(value: value, in: range, step: step).controlSize(.small)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func numberField(_ title: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.text3)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .monospacedDigit()
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.lineStrong) }
        }
    }
}

/// Video settings: codec and output size (macOS's export presets decide the bitrate).
struct VideoSettingsForm: View {
    @Binding var options: VideoOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(tr("Formato"))
                SegmentedControl(options: VideoCodec.allCases.map { ($0.title, $0) },
                                 selection: Binding(get: { options.codec }, set: { options.selectCodec($0) }),
                                 expand: true)
                Text(options.codec == .hevc ? tr("MP4 más pequeño. Lo reproducen Safari y los navegadores recientes.")
                                            : tr("MP4 compatible con todo, pero ocupa más."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(tr("Resolución"))
                SegmentedControl(options: VideoSize.available(for: options.codec).map { ($0.title, $0) },
                                 selection: $options.size, expand: true)
                Text(tr("Nunca se agranda. macOS elige la tasa de bits de cada resolución."))
                    .font(.system(size: 11)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle().fill(Theme.line).frame(height: 1)

            SaveSettings(destination: $options.destination, onlyIfSmaller: $options.onlyIfSmaller)
        }
    }
}

/// "On save": copy in the album, replace the original or export, and the size check.
struct SaveSettings: View {
    @Binding var destination: OptimizeDestination
    @Binding var onlyIfSmaller: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(tr("Al guardar"))
            SegmentedControl(options: [
                (tr("Copia"), OptimizeDestination.copyInAlbum),
                (tr("Reemplazar"), OptimizeDestination.replace),
                (tr("Carpeta"), OptimizeDestination.exportFolder),
            ], selection: $destination, expand: true)
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            SwitchRow(title: tr("Solo si ocupa menos"), isOn: $onlyIfSmaller)
        }
    }

    private var detail: String {
        switch destination {
        case .copyInAlbum: return tr("Añade la versión optimizada al álbum junto a la original.")
        case .replace: return tr("Cambia la original por la optimizada. La original va a la papelera.")
        case .exportFolder: return tr("Escribe las optimizadas en la carpeta que elijas; el álbum no cambia.")
        }
    }
}

/// "Needs X" note with the Homebrew command and a copy button.
struct ToolHint: View {
    let tools: [ExternalTool]
    let text: String

    var body: some View {
        let command = ExternalTool.installCommand(tools)
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(Theme.warn)
            HStack(spacing: 6) {
                Text(command).monospacedText(size: 11).textSelection(.enabled)
                Spacer()
                Button(tr("Copiar")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .buttonStyle(AppButtonStyle(kind: .ghost, height: 22))
            }
            .padding(8)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
