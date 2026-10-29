import AppKit
import CleanCore
import SwiftUI

enum Theme {
    static let accent = Color(red: 0.05, green: 0.55, blue: 0.58)
    static let accentSoft = Color(red: 0.05, green: 0.55, blue: 0.58).opacity(0.12)
    static let warning = Color.orange
    static let danger = Color.red
}

struct ModuleHeader<Trailing: View>: View {
    let module: Module
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: module.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(module.title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

struct AccessBanner: View {
    @Environment(AppState.self) private var app
    let message: String

    var body: some View {
        if !app.hasFullDiskAccess {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield").foregroundStyle(Theme.warning)
                Text(message).font(.callout).lineLimit(2)
                Spacer()
                Button("Ouvrir les réglages") { SystemActions.openFullDiskAccessSettings() }
                Button("Vérifier") { app.refreshAccess() }
            }
            .padding(10)
            .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
    }
}

struct GroupCheckbox: View {
    let state: ScanModel.GroupState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state == .all ? "checkmark.square.fill" : state == .some ? "minus.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(state == .none ? Color.secondary : Theme.accent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .all ? "Tout désélectionner" : "Tout sélectionner")
    }
}

struct ItemRow: View {
    let item: CleanItem
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if item.isSelectable {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in toggle() }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Sélectionner \(item.title)")
            } else {
                Image(systemName: item.action == .none && item.blockedReason == nil ? "info.circle" : "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .help(item.blockedReason ?? "")
            }
            if let url = item.url {
                Image(nsImage: SystemActions.icon(for: url)).resizable().frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let reason = item.blockedReason {
                    Label(reason, systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                } else if let warning = item.warning {
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            Spacer(minLength: 8)
            if item.size > 0 {
                Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .contextMenu {
            if let url = item.url {
                Button("Afficher dans le Finder") { SystemActions.reveal(url) }
            }
        }
    }
}

/// The confirmation dialog shown before any action.
struct ConfirmSheet: View {
    let items: [CleanItem]
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var isPermanent: Bool { items.contains { $0.action == .deletePermanently } }
    private var trashCount: Int { items.filter { if case .trash = $0.action { return true }; if case .unloadAndTrash = $0.action { return true }; return false }.count }
    private var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    private var warnings: [CleanItem] { items.filter { $0.warning != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: isPermanent ? "exclamationmark.octagon.fill" : "trash")
                    .font(.system(size: 28))
                    .foregroundStyle(isPermanent ? Theme.danger : Theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            List(items) { item in
                HStack {
                    if let url = item.url {
                        Image(nsImage: SystemActions.icon(for: url)).resizable().frame(width: 16, height: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        // The full path, so a folder name alone cannot hide where it lives.
                        if let path = item.url?.path {
                            Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if let warning = item.warning {
                            Text(warning).font(.caption).foregroundStyle(Theme.warning)
                        }
                    }
                    Spacer()
                    if item.size > 0 { Text(Format.bytes(item.size)).monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            if !warnings.isEmpty {
                Label("\(warnings.count) élément\(warnings.count > 1 ? "s" : "") avec un avertissement, relis la liste.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if isPermanent {
                    // No keyboard shortcut: a permanent deletion takes a deliberate click.
                    Button(confirmLabel, role: .destructive) {
                        dismiss()
                        onConfirm()
                    }
                    .tint(Theme.danger)
                } else {
                    Button(confirmLabel) {
                        dismiss()
                        onConfirm()
                    }
                    .keyboardShortcut(.defaultAction)
                    .tint(Theme.accent)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var title: String {
        let count = "\(items.count) élément\(items.count > 1 ? "s" : "")"
        if isPermanent { return "Supprimer définitivement \(count) ?" }
        if trashCount == items.count { return "Mettre \(count) à la Corbeille ?" }
        return "Appliquer l'action à \(count) ?"
    }

    private var detail: String {
        if isPermanent { return "\(Format.bytes(totalSize)) seront effacés. Cette action ne peut pas être annulée." }
        var parts: [String] = []
        if trashCount > 0 { parts.append("\(Format.bytes(totalSize)) partent à la Corbeille, récupérables tant qu'elle n'est pas vidée.") }
        if trashCount < items.count { parts.append("Les autorisations et éléments de connexion retirés seront réinitialisés.") }
        return parts.joined(separator: " ")
    }

    private var confirmLabel: String {
        if isPermanent { return "Supprimer définitivement" }
        return trashCount == items.count ? "Mettre à la Corbeille" : "Appliquer"
    }
}

struct ReportBox: Identifiable {
    let id = UUID()
    let report: CleanupReport
    let permanent: Bool
}

struct ReportSheet: View {
    let box: ReportBox
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: box.report.failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(box.report.failed.isEmpty ? Color.green : Theme.warning)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !box.report.failed.isEmpty {
                List(box.report.failed) { outcome in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(outcome.item.title).lineLimit(1).truncationMode(.middle)
                        Text(outcome.message ?? "Échec").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
                .listStyle(.bordered(alternatesRowBackgrounds: true))
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var headline: String {
        let done = box.report.succeeded.count
        return "\(done) élément\(done > 1 ? "s" : "") traité\(done > 1 ? "s" : "")"
            + (box.report.failed.isEmpty ? "" : ", \(box.report.failed.count) en échec")
    }

    private var detail: String {
        let size = Format.bytes(box.report.processedSize)
        if box.permanent { return "\(size) libérés." }
        if box.report.processedSize > 0 { return "\(size) à la Corbeille. L'espace revient quand tu la vides (module Corbeilles)." }
        return "Tout est consigné dans le Journal."
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
