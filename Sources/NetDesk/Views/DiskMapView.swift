import AppKit
import Charts
import CleanCore
import SwiftUI

struct DiskMapView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: DiskMapModel
    @LocalState private var confirming: ConfirmItems?
    @LocalState private var reportBox: ReportBox?
    @LocalState private var pendingNodes: [SpaceNode] = []

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .diskMap, subtitle: "Carte de ce qui prend de la place. Seuls tes propres fichiers se mettent à la Corbeille d'ici.") {
                HStack {
                    Picker("Analyser", selection: $model.root) {
                        ForEach(DiskMapModel.Root.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 220)
                    .onChange(of: model.root) { _, newValue in
                        if newValue == .custom { chooseFolder() }
                    }
                    if model.isScanning {
                        Button("Arrêter") { model.cancel() }
                    } else {
                        Button(model.tree == nil ? "Analyser" : "Réanalyser") { Task { await model.scan(app.context()) } }
                            .buttonStyle(.borderedProminent).tint(Theme.accent)
                    }
                }
            }
            AccessBanner(message: "Sans l'accès complet au disque, certains dossiers apparaissent comme illisibles.")
            content
        }
        .sheet(item: $confirming) { wrapper in
            ConfirmSheet(items: wrapper.items) { run(wrapper.items) }
        }
        .sheet(item: $reportBox) { ReportSheet(box: $0) }
    }

    @ViewBuilder private var content: some View {
        if model.isScanning {
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("\(model.scannedFiles.formatted()) fichiers lus").monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let current = model.current {
            VStack(spacing: 0) {
                breadcrumb(current)
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    chart(current).frame(width: 300).padding(16)
                    Divider()
                    childList(current)
                }
                Divider()
                footer
            }
            .id(model.revision)
        } else {
            EmptyStateView(symbol: "circle.circle", title: "Pas encore analysé",
                           message: "Choisis ton dossier perso ou tout le disque. Les dossiers cloud ne sont pas parcourus.")
        }
    }

    private func breadcrumb(_ node: SpaceNode) -> some View {
        var chain: [SpaceNode] = []
        var cursor: SpaceNode? = node
        while let item = cursor {
            chain.insert(item, at: 0)
            cursor = item.parent
        }
        return HStack(spacing: 4) {
            Button {
                if let parent = node.parent { open(parent) }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(node.parent == nil)
            .accessibilityLabel("Dossier parent")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(chain.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                        Button(item.name) { open(item) }.buttonStyle(.plain)
                            .foregroundStyle(index == chain.count - 1 ? Color.primary : Color.secondary)
                    }
                }
            }
            Spacer()
            Text(Format.bytes(node.size)).font(.headline).monospacedDigit()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    private struct Slice: Identifiable {
        let id: String
        let name: String
        let size: Int64
    }

    private func slices(_ node: SpaceNode) -> [Slice] {
        let top = node.children.prefix(7).map { Slice(id: $0.id, name: $0.name, size: $0.size) }
        let rest = node.size - top.reduce(0) { $0 + $1.size }
        return rest > 0 ? top + [Slice(id: "autres", name: "Le reste", size: rest)] : top
    }

    private func chart(_ node: SpaceNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart(slices(node)) { slice in
                SectorMark(angle: .value("Taille", slice.size), innerRadius: .ratio(0.55), angularInset: 1.2)
                    .foregroundStyle(by: .value("Dossier", slice.name))
                    .cornerRadius(3)
            }
            .chartLegend(.hidden)
            .frame(height: 220)
            .overlay {
                VStack(spacing: 2) {
                    Text(Format.bytes(node.size)).font(.headline).monospacedDigit()
                    Text(node.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(width: 110)
            }
            .accessibilityLabel("Répartition de \(node.name)")
            Chart(slices(node)) { slice in
                BarMark(x: .value("Taille", slice.size))
                    .foregroundStyle(by: .value("Dossier", slice.name))
            }
            .chartXAxis(.hidden)
            .chartLegend(position: .bottom, alignment: .leading, spacing: 6)
            .frame(height: 110)
        }
    }

    private func childList(_ node: SpaceNode) -> some View {
        let maxSize = max(node.children.first?.size ?? 1, 1)
        let items = Dictionary(uniqueKeysWithValues: model.items(for: node.children, policy: app.policy, environment: app.environment).map { ($0.url?.path ?? "", $0) })
        return List {
            ForEach(node.children) { child in
                let item = items[child.url.path]
                HStack(spacing: 10) {
                    if let item, item.isSelectable {
                        Toggle("", isOn: Binding(get: { model.selection.contains(child.id) },
                                                 set: { if $0 { model.selection.insert(child.id) } else { model.selection.remove(child.id) } }))
                            .toggleStyle(.checkbox).labelsHidden()
                            .accessibilityLabel("Sélectionner \(child.name)")
                    } else {
                        Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 16).help(item?.blockedReason ?? "")
                    }
                    Image(nsImage: SystemActions.icon(for: child.url)).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(child.name).lineLimit(1).truncationMode(.middle)
                        GeometryReader { proxy in
                            Capsule().fill(Theme.accent.opacity(0.75))
                                .frame(width: max(2, proxy.size.width * CGFloat(Double(child.size) / Double(maxSize))))
                        }
                        .frame(height: 5)
                        if let reason = child.skippedReason ?? (child.isReadable ? nil : "Illisible sans l'accès complet au disque") {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text(Format.bytes(child.size)).monospacedDigit().foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                    if child.isDirectory && !child.children.isEmpty {
                        Button { open(child) } label: { Image(systemName: "chevron.right") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Ouvrir \(child.name)")
                    } else {
                        Color.clear.frame(width: 12)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if child.isDirectory && !child.children.isEmpty { open(child) } }
                .contextMenu { Button("Afficher dans le Finder") { SystemActions.reveal(child.url) } }
            }
            if node.smallFilesCount > 0 {
                HStack {
                    Image(systemName: "doc.on.doc").foregroundStyle(.secondary).frame(width: 16)
                    Text("\(node.smallFilesCount) petits fichiers").foregroundStyle(.secondary)
                    Spacer()
                    Text(Format.bytes(node.smallFilesSize)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            let nodes = model.selectedNodes()
            Text(nodes.isEmpty ? "Coche des éléments pour les mettre à la Corbeille" : "\(nodes.count) sélectionné\(nodes.count > 1 ? "s" : "") · \(Format.bytes(nodes.reduce(0) { $0 + $1.size }))")
                .monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            Button("Mettre à la Corbeille") {
                pendingNodes = nodes
                confirming = ConfirmItems(items: model.items(for: nodes, policy: app.policy, environment: app.environment).filter(\.isSelectable))
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .disabled(nodes.isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func open(_ node: SpaceNode) {
        model.current = node
        model.selection = []
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Analyser"
        if panel.runModal() == .OK, let url = panel.url {
            model.customFolder = url
        } else if model.customFolder == nil {
            model.root = .home
        }
    }

    private func run(_ items: [CleanItem]) {
        let nodes = pendingNodes
        Task {
            let executor = app.executor()
            let report = await Task.detached { executor.perform(items, module: "Carte du disque") }.value
            model.applyRemoval(report, nodes: nodes)
            reportBox = ReportBox(report: report, permanent: false)
        }
    }
}
