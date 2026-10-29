import CleanCore
import Foundation
import Observation

@MainActor
@Observable
final class ApplicationsModel {
    var apps: [InstalledApp] = []
    var isLoading = false
    var loaded = false
    var selectedAppID: InstalledApp.ID?
    var items: [CleanItem] = []
    var selection: Set<String> = []
    var isLoadingItems = false
    var onlyUnused = false
    var search = ""
    var lastReport: CleanupReport?

    func load(_ context: ScanContext) async {
        isLoading = true
        let apps = await Task.detached(priority: .userInitiated) { ApplicationScanner(context: context).installedApps() }.value
        self.apps = apps
        isLoading = false
        loaded = true
        if let id = selectedAppID, !apps.contains(where: { $0.id == id }) {
            selectedAppID = nil
            items = []
        }
    }

    func visibleApps() -> [InstalledApp] {
        apps.filter { app in
            (!onlyUnused || ApplicationScanner.isUnused(app))
                && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || (app.bundleID ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var selectedApp: InstalledApp? { apps.first { $0.id == selectedAppID } }

    func select(_ app: InstalledApp?, context: ScanContext) async {
        selectedAppID = app?.id
        items = []
        selection = []
        guard let app else { return }
        isLoadingItems = true
        let installed = apps
        let found = await Task.detached(priority: .userInitiated) {
            ApplicationScanner(context: context).uninstallItems(for: app, installed: installed)
        }.value
        guard selectedAppID == app.id else { return }
        items = found
        selection = Set(found.filter { $0.selectedByDefault && $0.isSelectable }.map(\.id))
        isLoadingItems = false
    }

    var selectedItems: [CleanItem] { items.filter { selection.contains($0.id) && $0.isSelectable } }

    /// The app goes first. If it cannot be moved, its files stay where they are.
    func uninstall(with executor: CleanupExecutor, context: ScanContext) async -> CleanupReport {
        let toRun = selectedItems
        let appPath = selectedApp?.url.path
        let report = await Task.detached(priority: .userInitiated) { () -> CleanupReport in
            let appItems = toRun.filter { $0.url?.path == appPath }
            let rest = toRun.filter { $0.url?.path != appPath }
            let first = executor.perform(appItems, module: "Applications")
            guard first.failed.isEmpty else { return first }
            return CleanupReport(outcomes: first.outcomes + executor.perform(rest, module: "Applications").outcomes)
        }.value
        lastReport = report
        let done = Set(report.succeeded.map(\.item.id))
        items.removeAll { done.contains($0.id) }
        selection.subtract(done)
        await load(context)
        return report
    }
}

@MainActor
@Observable
final class DiskMapModel {
    enum Root: String, CaseIterable, Identifiable {
        case home = "Dossier perso", disk = "Macintosh HD", custom = "Autre dossier"
        var id: String { rawValue }
    }

    var root: Root = .home
    var customFolder: URL?
    var tree: SpaceNode?
    var current: SpaceNode?
    var isScanning = false
    var scannedFiles = 0
    var selection: Set<String> = []
    var revision = 0
    private var progress: SpaceScanProgress?

    func rootURL(home: URL) -> URL {
        switch root {
        case .home: return home
        case .disk: return URL(fileURLWithPath: "/")
        case .custom: return customFolder ?? home
        }
    }

    func scan(_ context: ScanContext) async {
        progress?.cancel()
        let progress = SpaceScanProgress()
        self.progress = progress
        isScanning = true
        scannedFiles = 0
        selection = []
        let url = rootURL(home: context.environment.home)
        let poller = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                self.scannedFiles = progress.files
            }
        }
        let node = await Task.detached(priority: .userInitiated) { SpaceScanner(context: context).scan(url, progress: progress) }.value
        poller.cancel()
        guard !progress.isCancelled else { return }
        tree = node
        current = node
        isScanning = false
    }

    func cancel() {
        progress?.cancel()
        isScanning = false
    }

    func items(for nodes: [SpaceNode], policy: SafetyPolicy, environment: CleanEnvironment) -> [CleanItem] {
        nodes.map { node in
            policy.annotate(CleanItem(url: node.url, size: node.size, selectedByDefault: false))
                .blocked(SpaceScanner.selectionBlock(for: node.url, environment: environment))
        }
    }

    func selectedNodes() -> [SpaceNode] {
        (current?.children ?? []).filter { selection.contains($0.id) }
    }

    func applyRemoval(_ report: CleanupReport, nodes: [SpaceNode]) {
        let done = Set(report.succeeded.map { $0.item.urls.first?.path ?? "" })
        for node in nodes where done.contains(node.url.path) {
            SpaceScanner.remove(node)
        }
        selection = []
        revision += 1
    }
}

@MainActor
@Observable
final class MonitorModel {
    var snapshot = SystemSnapshot()
    private let monitor = SystemMonitor()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        snapshot = monitor.sample()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.snapshot = self.monitor.sample()
            }
        }
    }
}
