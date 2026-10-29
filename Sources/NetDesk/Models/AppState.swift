import AppKit
import CleanCore
import Foundation
import Observation

enum Module: String, CaseIterable, Identifiable, Hashable {
    case overview, cleanup, trash, privacy, performance, applications, clutter, diskMap, monitor, screenCleaning, journal, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Analyse express"
        case .cleanup: return "Nettoyage"
        case .trash: return "Corbeilles"
        case .privacy: return "Confidentialité"
        case .performance: return "Performance"
        case .applications: return "Applications"
        case .clutter: return "Fichiers à trier"
        case .diskMap: return "Carte du disque"
        case .monitor: return "Moniteur"
        case .screenCleaning: return "Nettoyage d'écran"
        case .journal: return "Journal"
        case .settings: return "Réglages"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "sparkles"
        case .cleanup: return "archivebox"
        case .trash: return "trash"
        case .privacy: return "hand.raised"
        case .performance: return "gauge.with.dots.needle.67percent"
        case .applications: return "square.grid.2x2"
        case .clutter: return "doc.on.doc"
        case .diskMap: return "circle.circle"
        case .monitor: return "waveform.path.ecg"
        case .screenCleaning: return "display"
        case .journal: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }

    static let sections: [(String, [Module])] = [
        ("", [.overview]),
        ("Nettoyer", [.cleanup, .trash]),
        ("Protéger", [.privacy]),
        ("Accélérer", [.performance, .applications]),
        ("Fichiers", [.clutter, .diskMap]),
        ("Outils", [.monitor, .screenCleaning]),
        (Product.name, [.journal, .settings]),
    ]
}

@MainActor
@Observable
final class AppState {
    let environment = CleanEnvironment.current
    let journal: Journal
    var selection: Module? = .overview
    var hasFullDiskAccess = false
    var userExclusions: [String] {
        didSet {
            UserDefaults.standard.set(userExclusions, forKey: "userExclusions")
            policy = SafetyPolicy(environment: environment, userExclusions: userExclusions)
        }
    }
    private(set) var policy: SafetyPolicy

    let junk: ScanModel
    let trash: ScanModel
    let privacy: ScanModel
    let performance: ScanModel
    let large: ScanModel
    let duplicates: ScanModel
    let downloads: ScanModel
    let installers: ScanModel
    let orphans: ScanModel
    let applications: ApplicationsModel
    let diskMap: DiskMapModel
    let monitor = MonitorModel()

    init() {
        let exclusions = UserDefaults.standard.stringArray(forKey: "userExclusions") ?? []
        userExclusions = exclusions
        policy = SafetyPolicy(environment: environment, userExclusions: exclusions)
        journal = Journal(file: environment.journalFile)

        junk = ScanModel(id: "junk", moduleName: "Nettoyage") { JunkScanner(context: $0).scan() }
        trash = ScanModel(id: "trash", moduleName: "Corbeilles") { TrashBinScanner(context: $0).scan() }
        privacy = ScanModel(id: "privacy", moduleName: "Confidentialité") { PrivacyScanner(context: $0).scan() }
        performance = ScanModel(id: "performance", moduleName: "Performance") { PerformanceScanner(context: $0).scan() }
        large = ScanModel(id: "large", moduleName: "Gros fichiers") { LargeFileScanner(context: $0).scan() }
        duplicates = ScanModel(id: "duplicates", moduleName: "Doublons") { DuplicateScanner(context: $0).scan() }
        downloads = ScanModel(id: "downloads", moduleName: "Téléchargements") { DownloadsScanner(context: $0).scan() }
        installers = ScanModel(id: "installers", moduleName: "Installeurs") {
            InstallerScanner(context: $0, mountedImages: InstallerScanner.currentlyMountedImages()).scan()
        }
        orphans = ScanModel(id: "orphans", moduleName: "Restes d'apps") { context in
            let scanner = ApplicationScanner(context: context)
            return scanner.orphanLeftovers(installed: scanner.installedApps())
        }
        applications = ApplicationsModel()
        diskMap = DiskMapModel()
        refreshAccess()
    }

    func refreshAccess() {
        hasFullDiskAccess = FullDiskAccess.isGranted(in: environment)
    }

    func context() -> ScanContext {
        ScanContext(environment: environment, policy: policy, runningBundleIDs: SystemActions.runningBundleIDs())
    }

    /// The Finder fallback (password asked by macOS) is only offered by the Uninstaller, for apps owned by the system.
    func executor(allowFinderFallback: Bool = false) -> CleanupExecutor {
        CleanupExecutor(environment: environment, policy: policy, trash: SystemTrash(), journal: journal,
                        recycler: allowFinderFallback ? SystemActions.recycler : nil, loginItemRemover: SystemActions.removeLoginItem,
                        isRunning: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty })
    }
}
