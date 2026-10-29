import CleanCore
import SwiftUI

struct ApplicationsView: View {
    @Environment(AppState.self) private var app
    @LocalState private var tab = Tab.uninstaller

    enum Tab: String, CaseIterable, Identifiable {
        case uninstaller = "Désinstalleur", leftovers = "Restes d'apps", installers = "Installeurs"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .applications, subtitle: "Désinstalle une app avec ses fichiers, retrouve les restes d'apps supprimées et les installeurs oubliés.") {
                Picker("Vue", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
            }
            switch tab {
            case .uninstaller:
                AccessBanner(message: "Sans l'accès complet au disque, les restes rangés dans les conteneurs d'apps ne sont pas trouvés.")
                UninstallerView(model: app.applications)
            case .leftovers:
                ResultsView(model: app.orphans, actionLabel: "Mettre à la Corbeille", emptyMessage: "Aucun reste d'app supprimée.",
                            idleMessage: "Cherche dans ~/Library les fichiers d'apps qui ne sont plus installées. Rien n'est coché d'office.")
            case .installers:
                ResultsView(model: app.installers, actionLabel: "Mettre à la Corbeille", emptyMessage: "Aucun installeur trouvé.",
                            idleMessage: "Cherche les .dmg, .pkg et .iso dans Téléchargements, Bureau et Documents.")
            }
        }
    }
}

struct UninstallerView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: ApplicationsModel
    @LocalState private var confirming: ConfirmItems?
    @LocalState private var reportBox: ReportBox?

    var body: some View {
        HSplitView {
            appList.frame(minWidth: 320, idealWidth: 380)
            detail.frame(minWidth: 360)
        }
        .task {
            if !model.loaded { await model.load(app.context()) }
        }
        .sheet(item: $confirming) { wrapper in
            ConfirmSheet(items: wrapper.items) { run() }
        }
        .sheet(item: $reportBox) { ReportSheet(box: $0) }
    }

    private var appList: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Rechercher", text: $model.search).textFieldStyle(.roundedBorder)
                Toggle("Inutilisées", isOn: $model.onlyUnused).toggleStyle(.checkbox)
                    .help("Pas ouvertes depuis \(ApplicationScanner.unusedAfterDays) jours, selon Spotlight")
                Button {
                    Task { await model.load(app.context()) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Recharger la liste")
                .disabled(model.isLoading)
            }
            .padding(10)
            if model.isLoading && model.apps.isEmpty {
                ProgressView("Lecture des applications...").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.visibleApps(), selection: Binding(get: { model.selectedAppID }, set: { id in
                    Task { await model.select(model.apps.first { $0.id == id }, context: app.context()) }
                })) { item in
                    HStack(spacing: 10) {
                        Image(nsImage: SystemActions.icon(for: item.url)).resizable().frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1)
                            Text(item.lastUsed.map { "Ouverte le \(Format.date($0))" } ?? "Jamais ouverte selon Spotlight")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let selected = model.selectedApp {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: SystemActions.icon(for: selected.url)).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.name).font(.title3.weight(.semibold))
                        Text([selected.bundleID, selected.version.map { "version \($0)" }, selected.isAppStore ? "App Store" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                Divider()
                if model.isLoadingItems {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.items) { item in
                        ItemRow(item: item, isSelected: model.selection.contains(item.id)) {
                            guard item.isSelectable else { return }
                            if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
                        }
                    }
                }
                Divider()
                HStack {
                    let size = model.selectedItems.reduce(0) { $0 + $1.size }
                    Text("\(model.selectedItems.count) sélectionné\(model.selectedItems.count > 1 ? "s" : "") · \(Format.bytes(size))")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Désinstaller") { confirming = ConfirmItems(items: model.selectedItems) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .disabled(model.selectedItems.isEmpty)
                }
                .padding(12)
            }
        } else {
            EmptyStateView(symbol: "square.grid.2x2", title: "Choisis une app",
                           message: "L'app et les fichiers qu'elle a laissés dans ta bibliothèque s'affichent ici. Les restes trouvés par le seul nom restent décochés.")
        }
    }

    private func run() {
        Task {
            let report = await model.uninstall(with: app.executor(allowFinderFallback: true), context: app.context())
            reportBox = ReportBox(report: report, permanent: false)
        }
    }
}
