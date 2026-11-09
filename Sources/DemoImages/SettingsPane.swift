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

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(tr("Biblioteca"))
                    Text(Library.root.path).monospacedText(size: 11).foregroundStyle(Theme.text2).textSelection(.enabled)
                    Button(tr("Mostrar en Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([Library.root])
                    }
                    .buttonStyle(.appSecondary)
                }
                .appCard()
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
