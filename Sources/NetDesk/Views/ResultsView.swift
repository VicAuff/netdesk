import CleanCore
import SwiftUI

/// Scan button, grouped list with checkboxes, then confirmation dialog before anything happens.
struct ResultsView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: ScanModel
    var actionLabel = "Nettoyer"
    var emptyTitle = "Rien à signaler"
    var emptyMessage = "Aucun élément trouvé."
    var idleMessage = "Lance l'analyse pour voir ce qui peut être nettoyé."
    var permanent = false
    var showsSize = true

    @LocalState private var confirming: ConfirmItems?
    @LocalState private var reportBox: ReportBox?

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            footer
        }
        .sheet(item: $confirming) { wrapper in
            ConfirmSheet(items: wrapper.items) { run(wrapper.items) }
        }
        .sheet(item: $reportBox) { ReportSheet(box: $0) }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            EmptyStateView(symbol: "magnifyingglass", title: "Pas encore analysé", message: idleMessage)
        case .scanning:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Analyse en cours...").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready, .working:
            if model.groups.allSatisfy({ $0.items.isEmpty && $0.notice == nil }) {
                EmptyStateView(symbol: "checkmark.seal", title: emptyTitle, message: emptyMessage)
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(model.groups) { group in
                Section(isExpanded: Binding(get: { !model.collapsed.contains(group.id) },
                                            set: { if $0 { model.collapsed.remove(group.id) } else { model.collapsed.insert(group.id) } })) {
                    if let notice = group.notice {
                        Label(notice, systemImage: "lock.shield").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(group.items) { item in
                        ItemRow(item: item, isSelected: model.isSelected(item)) { model.toggle(item) }
                    }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.phase == .working)
    }

    private func groupHeader(_ group: CleanGroup) -> some View {
        HStack(spacing: 8) {
            if !group.bulkSelectableItems.isEmpty {
                GroupCheckbox(state: model.state(of: group)) { model.toggle(group) }
            }
            Image(systemName: group.symbol).foregroundStyle(Theme.accent).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.title).font(.headline).foregroundStyle(.primary)
                Text(group.explanation).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if showsSize && group.totalSize > 0 {
                Text("\(Format.bytes(model.selectedSize(in: group))) / \(Format.bytes(group.totalSize))")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            } else if !group.items.isEmpty {
                Text("\(group.items.count)").font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.hasResults {
                let count = model.selectedItems.count
                Text(count == 0 ? "Rien de sélectionné" : "\(count) sélectionné\(count > 1 ? "s" : "")" + (showsSize ? " · \(Format.bytes(model.selectedSize))" : ""))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.phase == .working {
                ProgressView().controlSize(.small)
            }
            Button(model.hasResults ? "Réanalyser" : "Analyser") {
                Task { await model.scan(app.context()) }
            }
            .disabled(model.phase == .scanning || model.phase == .working)
            Button(actionLabel) { confirming = ConfirmItems(items: model.selectedItems) }
                .buttonStyle(.borderedProminent)
                .tint(permanent ? Theme.danger : Theme.accent)
                .disabled(model.selectedItems.isEmpty || model.phase != .ready)
                .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func run(_ items: [CleanItem]) {
        Task {
            let report = await model.perform(with: app.executor(), items: items)
            reportBox = ReportBox(report: report, permanent: permanent)
            if permanent { await model.scan(app.context()) }
        }
    }
}

struct ConfirmItems: Identifiable {
    let id = UUID()
    let items: [CleanItem]
}
