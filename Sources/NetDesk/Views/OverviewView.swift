import CleanCore
import SwiftUI

/// One scan across modules, one click to clean the safe part.
struct OverviewView: View {
    @Environment(AppState.self) private var app
    @LocalState private var isScanning = false
    @LocalState private var confirming: ConfirmItems?
    @LocalState private var reportBox: ReportBox?

    var body: some View {
        VStack(spacing: 0) {
            ModuleHeader(module: .overview, subtitle: "Analyse rapide de tout le Mac. Le nettoyage en un clic ne touche qu'aux caches, journaux et réglages cassés.") {
                EmptyView()
            }
            AccessBanner(message: "Accorde l'accès complet au disque à \(Product.name) pour une analyse complète.")
            ScrollView {
                VStack(spacing: 20) {
                    hero
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        tile(.cleanup, value: app.junk.hasResults ? Format.bytes(app.junk.selectedSize) : "-", caption: "cochés dans Nettoyage")
                        tile(.trash, value: app.trash.hasResults ? Format.bytes(app.trash.totalSize) : "-", caption: "dans les corbeilles")
                        tile(.applications, value: app.applications.loaded ? "\(app.applications.apps.filter { ApplicationScanner.isUnused($0) }.count)" : "-",
                             caption: "apps inutilisées depuis \(ApplicationScanner.unusedAfterDays) jours")
                        tile(.performance, value: app.performance.hasResults ? "\(activeBackgroundCount)" : "-", caption: "éléments actifs au démarrage")
                        tile(.clutter, value: app.large.hasResults ? "\(app.large.allItems.count)" : "-", caption: "fichiers de plus de 50 Mo")
                        tile(.privacy, value: app.privacy.hasResults ? "\(app.privacy.allItems.filter(\.isSelectable).count)" : "-", caption: "traces effaçables")
                    }
                }
                .padding(20)
            }
        }
        .sheet(item: $confirming) { wrapper in
            ConfirmSheet(items: wrapper.items) { run(wrapper.items) }
        }
        .sheet(item: $reportBox) { ReportSheet(box: $0) }
    }

    /// The quick scan only cleans the ticked items of these Cleanup groups, never backups, AI models or the Trash.
    private static let safeGroups: Set<String> = ["caches", "logs", "developer", "preferences"]

    private var safeItems: [CleanItem] {
        app.junk.groups.filter { Self.safeGroups.contains($0.id) }.flatMap(\.items)
            .filter { app.junk.selection.contains($0.id) && $0.isSelectable }
    }

    private var safeSize: Int64 { safeItems.reduce(0) { $0 + $1.size } }

    private var activeBackgroundCount: Int {
        app.performance.groups.filter { $0.id != "maintenance" }.flatMap(\.items).filter { $0.subtitle?.contains("activé") == true && $0.subtitle?.contains("désactivé") == false }.count
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(Theme.accentSoft).frame(width: 150, height: 150)
                if isScanning {
                    ProgressView().controlSize(.large)
                } else {
                    VStack(spacing: 4) {
                        Text(app.junk.hasResults ? Format.bytes(safeSize) : "Prêt")
                            .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(app.junk.hasResults ? "à nettoyer" : "pour une analyse").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 12) {
                Button(app.junk.hasResults ? "Réanalyser" : "Analyser") { Task { await scanAll() } }
                    .controlSize(.large)
                    .disabled(isScanning)
                Button("Nettoyer") { confirming = ConfirmItems(items: safeItems) }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .disabled(isScanning || safeItems.isEmpty)
            }
            if app.junk.hasResults {
                Text("Caches, journaux et réglages cassés cochés dans Nettoyage. Le détail et le choix fin sont là-bas.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private func tile(_ module: Module, value: String, caption: String) -> some View {
        Button { app.selection = module } label: {
            HStack(spacing: 12) {
                Image(systemName: module.symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title).font(.headline)
                    Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Ouvre le module \(module.title)")
    }

    private func scanAll() async {
        isScanning = true
        let context = app.context()
        async let junk: Void = app.junk.scan(context)
        async let trash: Void = app.trash.scan(context)
        async let apps: Void = app.applications.load(context)
        async let performance: Void = app.performance.scan(context)
        async let large: Void = app.large.scan(context)
        async let privacy: Void = app.privacy.scan(context)
        _ = await (junk, trash, apps, performance, large, privacy)
        isScanning = false
    }

    private func run(_ items: [CleanItem]) {
        Task {
            let report = await app.junk.perform(with: app.executor(), items: items)
            reportBox = ReportBox(report: report, permanent: false)
        }
    }
}
