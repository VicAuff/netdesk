import AppKit
import CleanCore
import SwiftUI

struct JournalView: View {
    @Environment(AppState.self) private var app
    @LocalState private var entries: [JournalEntry] = []
    @LocalState private var restored: Set<UUID> = []
    @LocalState private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .journal, subtitle: "Tout ce que \(Product.name) a fait. Un élément encore dans la Corbeille se remet en place d'un clic.") {
                Button("Afficher le fichier") { SystemActions.reveal(app.environment.journalFile) }
                    .disabled(entries.isEmpty)
            }
            if entries.isEmpty {
                EmptyStateView(symbol: "clock.arrow.circlepath", title: "Journal vide", message: "Les actions apparaîtront ici.")
            } else {
                List(entries.filter { $0.kind != .restored }) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: symbol(entry.kind)).foregroundStyle(entry.kind == .deleted ? Theme.danger : Theme.accent).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1).truncationMode(.middle)
                            Text("\(entry.module) · \(label(entry.kind)) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(entry.originalPath).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if entry.size > 0 { Text(Format.bytes(entry.size)).monospacedDigit().foregroundStyle(.secondary) }
                        if restored.contains(entry.id) {
                            Text("Remis en place").font(.caption).foregroundStyle(.secondary)
                        } else if app.journal.canRestore(entry) {
                            Button("Remettre en place") { restore(entry) }
                        }
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .alert("Impossible de remettre en place", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func reload() {
        entries = app.journal.entries()
        restored = app.journal.restoredIDs()
    }

    private func restore(_ entry: JournalEntry) {
        do {
            try app.journal.restore(entry)
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }

    private func symbol(_ kind: JournalEntry.Kind) -> String {
        switch kind {
        case .trashed: return "trash"
        case .deleted: return "xmark.bin"
        case .revoked: return "hand.raised.slash"
        case .loginItemRemoved: return "power"
        case .restored: return "arrow.uturn.backward"
        }
    }

    private func label(_ kind: JournalEntry.Kind) -> String {
        switch kind {
        case .trashed: return "mis à la Corbeille"
        case .deleted: return "supprimé définitivement"
        case .revoked: return "autorisation retirée"
        case .loginItemRemoved: return "retiré de l'ouverture"
        case .restored: return "remis en place"
        }
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .settings, subtitle: "Accès au disque et dossiers que \(Product.name) ne touchera jamais.") {
                EmptyView()
            }
            Form {
                Section("Accès complet au disque") {
                    HStack {
                        Label(app.hasFullDiskAccess ? "Accordé" : "Non accordé",
                              systemImage: app.hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                            .foregroundStyle(app.hasFullDiskAccess ? Color.green : Theme.warning)
                        Spacer()
                        Button("Ouvrir les réglages") { SystemActions.openFullDiskAccessSettings() }
                        Button("Vérifier") { app.refreshAccess() }
                    }
                    Text("Ajoute \(Product.name) dans Réglages Système > Confidentialité et sécurité > Accès complet au disque, puis relance l'app.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Dossiers exclus") {
                    ForEach(app.policy.exclusions) { exclusion in
                        HStack {
                            Image(systemName: exclusion.isBuiltIn ? "lock.fill" : "folder.badge.minus").foregroundStyle(.secondary).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(exclusion.path).lineLimit(1).truncationMode(.middle)
                                Text(exclusion.label).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !exclusion.isBuiltIn {
                                Button("Retirer") { app.userExclusions.removeAll { SafetyPolicy.canonicalPath($0) == exclusion.path } }
                            }
                        }
                    }
                    Button("Ajouter un dossier...") { addExclusion() }
                    Text("Les exclusions verrouillées sont inscrites dans le code. S'y ajoutent tout ce que protège macOS (SIP) et les dossiers de base comme ta bibliothèque.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Règles") {
                    Label("Tout part à la Corbeille, après une confirmation.", systemImage: "trash")
                    Label("Seul le module Corbeilles supprime définitivement, après une confirmation.", systemImage: "exclamationmark.octagon")
                    Label("Jamais de droits administrateur, rien en arrière-plan, rien au démarrage. Seule exception : macOS demande ton mot de passe pour désinstaller une app qui appartient au système.", systemImage: "lock.shield")
                }
            }
            .formStyle(.grouped)
        }
    }

    private func addExclusion() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclure"
        guard panel.runModal() == .OK else { return }
        app.userExclusions.append(contentsOf: panel.urls.map(\.path))
    }
}
