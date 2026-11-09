import AppKit
import SwiftUI

struct SettingsPane: View {
    @ObservedObject private var localizer = Localizer.shared
    @ObservedObject private var updater = Updater.shared
    @ObservedObject private var settings = Settings.shared
    /// Bumped by "Check again" so tool status is re-read after installing.
    @State private var toolsRefresh = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(tr("Ajustes")).font(.system(size: 22, weight: .semibold))
                    .padding(.top, 16)

                LibraryLocationCard()

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(tr("Idioma"))
                    SegmentedControl(options: AppLanguage.allCases.map { ($0.nativeName, $0) },
                                     selection: $localizer.choice)
                }
                .appCard()

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(tr("Actualizaciones"))
                    SwitchRow(title: tr("Buscar actualizaciones automáticamente"),
                              detail: tr("Al abrir la app y una vez al día, desde GitHub (%@).", AppInfo.repo),
                              isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                    HStack {
                        Text(tr("Versión %@", Updater.currentVersion)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button(updater.state == .idle ? tr("Buscar ahora") : tr("Buscando…")) {
                            Task { await updater.check(userInitiated: true) }
                        }
                        .buttonStyle(.appSecondary)
                        .disabled(updater.state != .idle)
                    }
                }
                .appCard()

                toolsCard.id(toolsRefresh)

            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private var toolsCard: some View {
        let missing = ExternalTool.missing
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(tr("Herramientas de optimización"))
                Spacer()
                Button(tr("Volver a comprobar")) { toolsRefresh += 1 }
                    .buttonStyle(AppButtonStyle(kind: .ghost, height: 24))
            }
            Text(tr("Los mismos codificadores que usa Squoosh. Se instalan con Homebrew; HEIC, JPEG y PNG funcionan sin ellas."))
                .font(.system(size: 12)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(ExternalTool.allCases) { tool in
                HStack(spacing: 10) {
                    Image(systemName: tool.isInstalled ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(tool.isInstalled ? Theme.ok : Theme.text3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tool.executableName).monospacedText(size: 12)
                        Text(tool.purpose).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Text(tool.url?.path ?? "brew install \(tool.formula)")
                        .monospacedText(size: 11).foregroundStyle(Theme.text3)
                        .lineLimit(1).truncationMode(.head)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
            if !missing.isEmpty {
                ToolHint(tools: missing, text: tr("Faltan %d herramientas.", missing.count))
            }
        }
        .appCard()
    }
}

/// Where the library lives: show it, move it (e.g. to iCloud Drive) or open another one.
private struct LibraryLocationCard: View {
    @ObservedObject private var library = Library.shared
    @State private var pendingMove: URL?
    @State private var pendingOpen: URL?
    @State private var error: String?

    private var isDefault: Bool { library.root.standardizedFileURL == Library.defaultRoot.standardizedFileURL }
    private var iCloudTarget: URL? { Library.iCloudDrive?.appendingPathComponent(AppInfo.name, isDirectory: true) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(tr("Dónde se guardan las imágenes"))
            HStack(spacing: 10) {
                Image(systemName: library.isInICloud ? "icloud" : "internaldrive")
                    .font(.system(size: 18)).foregroundStyle(Theme.accentText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Library.displayPath(library.root)).fontWeight(.medium)
                    Text(library.root.path).monospacedText(size: 11).foregroundStyle(Theme.text3)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(tr("%d imágenes · %@", library.imageCount, Format.bytes(library.totalBytes)))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.text2)
            }
            if library.unavailable {
                Label(tr("No se encuentra la carpeta. Conecta el disco o activa iCloud Drive, o elige otra ubicación."),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
            HStack(spacing: 8) {
                Button(tr("Mostrar en Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([library.root])
                }
                .buttonStyle(.appSecondary)
                if let iCloudTarget, !library.isInICloud {
                    Button {
                        choose(iCloudTarget)
                    } label: {
                        Label(tr("Usar iCloud Drive"), systemImage: "icloud")
                    }
                    .buttonStyle(.appSecondary)
                }
                Button(tr("Elegir carpeta…"), action: pickFolder)
                    .buttonStyle(.appSecondary)
                if !isDefault {
                    Button(tr("Ubicación por defecto")) { choose(Library.defaultRoot) }
                        .buttonStyle(.appGhost)
                }
                Spacer()
                if library.relocating {
                    ProgressView().controlSize(.small)
                    Text(tr("Moviendo…")).foregroundStyle(Theme.text2)
                }
            }
            .disabled(library.relocating)
            Text(tr("Al cambiar de ubicación se mueven los álbumes que ya tienes. En iCloud Drive, la biblioteca se comparte entre tus Mac."))
                .font(.system(size: 11)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .appCard()
        .alert(tr("¿Mover la biblioteca?"), isPresented: Binding(get: { pendingMove != nil }, set: { if !$0 { pendingMove = nil } })) {
            Button(tr("Mover")) {
                guard let target = pendingMove else { return }
                move(to: target)
            }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(tr("Se moverán %d imágenes (%@) a %@.", library.imageCount, Format.bytes(library.totalBytes),
                    Library.displayPath(pendingMove ?? library.root)))
        }
        .alert(tr("Esa carpeta ya tiene una biblioteca"), isPresented: Binding(get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } })) {
            Button(tr("Abrir esa biblioteca")) {
                if let target = pendingOpen { library.open(target) }
            }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(tr("Se usará la que hay allí. La actual se queda en %@.", Library.displayPath(library.root)))
        }
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(tr("Aceptar")) {}
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Library.iCloudDrive ?? library.root.deletingLastPathComponent()
        panel.prompt = tr("Elegir")
        panel.message = tr("Elige dónde guardar la biblioteca. Si eliges una carpeta con otros archivos, se creará dentro una carpeta %@.", AppInfo.name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choose(url)
    }

    private func choose(_ folder: URL) {
        let target = library.target(for: folder)
        guard target.url.standardizedFileURL != library.root.standardizedFileURL else { return }
        if target.hasLibrary {
            // Nothing to lose here: just switch.
            if library.albums.isEmpty { library.open(target.url) } else { pendingOpen = target.url }
        } else if library.albums.isEmpty {
            move(to: target.url)
        } else {
            pendingMove = target.url
        }
    }

    private func move(to target: URL) {
        Task {
            do {
                try await library.move(to: target)
            } catch {
                self.error = tr("No se pudo mover la biblioteca: %@", error.localizedDescription)
            }
        }
    }
}
