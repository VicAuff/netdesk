import CleanCore
import SwiftUI

struct CleanupView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .cleanup, subtitle: "Caches, journaux, déchets de développement, pièces jointes Mail, sauvegardes iPhone et modèles IA.") {
                EmptyView()
            }
            AccessBanner(message: "Sans l'accès complet au disque, Mail et certaines sauvegardes restent invisibles.")
            ResultsView(model: app.junk, actionLabel: "Mettre à la Corbeille",
                        emptyMessage: "Pas de déchets trouvés.",
                        idleMessage: "Les caches et journaux sont cochés par défaut. Les éléments sensibles restent décochés.")
        }
    }
}

struct TrashBinsView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .trash, subtitle: "Vide la Corbeille du Mac et celles des disques branchés. C'est la seule suppression définitive de l'app.") {
                EmptyView()
            }
            AccessBanner(message: "macOS ne laisse lire la Corbeille qu'avec l'accès complet au disque.")
            ResultsView(model: app.trash, actionLabel: "Vider", emptyTitle: "Corbeilles vides",
                        emptyMessage: "Il n'y a rien à vider.", idleMessage: "Analyse les corbeilles pour voir ce qu'elles contiennent.",
                        permanent: true)
        }
    }
}

struct PrivacyView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .privacy, subtitle: "Historique, cookies et saisie des navigateurs, éléments récents, autorisations des apps. Rien n'est coché d'office.") {
                EmptyView()
            }
            AccessBanner(message: "Safari, les éléments récents et les autorisations demandent l'accès complet au disque.")
            ResultsView(model: app.privacy, actionLabel: "Effacer la sélection",
                        idleMessage: "Ferme les navigateurs concernés avant d'effacer leurs traces.", showsSize: false)
        }
    }
}

struct PerformanceView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .performance, subtitle: "Apps lancées à la connexion, agents en arrière-plan et entretien. Syncthing est protégé.") {
                Button("Réglages Ouverture") { SystemActions.openLoginItemsSettings() }
            }
            ResultsView(model: app.performance, actionLabel: "Retirer la sélection",
                        idleMessage: "Liste ce qui démarre avec ta session et tourne en arrière-plan.", showsSize: false)
        }
    }
}

struct ClutterView: View {
    @Environment(AppState.self) private var app
    @LocalState private var tab = Tab.large

    enum Tab: String, CaseIterable, Identifiable {
        case large = "Gros fichiers", duplicates = "Doublons", downloads = "Téléchargements"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .clutter, subtitle: "Gros fichiers, doublons et téléchargements de ton dossier perso, hors dossiers exclus.") {
                Picker("Vue", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
            }
            switch tab {
            case .large:
                ResultsView(model: app.large, actionLabel: "Mettre à la Corbeille", emptyMessage: "Aucun fichier de plus de 50 Mo.",
                            idleMessage: "Cherche les fichiers de plus de 50 Mo. Rien n'est coché d'office.")
            case .duplicates:
                ResultsView(model: app.duplicates, actionLabel: "Mettre à la Corbeille", emptyMessage: "Aucun doublon trouvé.",
                            idleMessage: "Compare le contenu des fichiers. L'exemplaire le plus ancien reste décoché.")
            case .downloads:
                ResultsView(model: app.downloads, actionLabel: "Mettre à la Corbeille", emptyMessage: "Le dossier Téléchargements est vide.",
                            idleMessage: "Trie les téléchargements selon l'app qui les a récupérés.")
            }
        }
    }
}
