import Foundation

/// What a scan needs to know about the machine, captured once on the main thread.
public struct ScanContext: Sendable {
    public let environment: CleanEnvironment
    public let policy: SafetyPolicy
    public let runningBundleIDs: Set<String>

    public init(environment: CleanEnvironment, policy: SafetyPolicy, runningBundleIDs: Set<String> = []) {
        self.environment = environment
        self.policy = policy
        self.runningBundleIDs = runningBundleIDs
    }

    func isRunning(_ bundleID: String) -> Bool {
        runningBundleIDs.contains { $0.caseInsensitiveCompare(bundleID) == .orderedSame }
    }
}

/// Cleanup module: caches, logs, developer junk, broken preferences, Mail downloads, iPhone backups, local AI models.
public struct JunkScanner: Sendable {
    let context: ScanContext
    var env: CleanEnvironment { context.environment }

    /// Linked to iCloud: left alone like iCloud Drive itself.
    static let skippedCaches: Set<String> = ["com.apple.bird", "cloudkit", "com.apple.cloudd", "com.apple.clouddocs", "familycircle", Product.name.lowercased()]
    /// Tools installed under Caches: listed but not ticked, since deleting them means reinstalling.
    static let toolCachePrefixes = ["ms-playwright", "puppeteer", "camoufox"]
    /// Cache folders not named after the bundle ID of the app that fills them.
    static let cacheOwners = ["google": "com.google.Chrome", "bravesoftware": "com.brave.Browser", "microsoft edge": "com.microsoft.edgemac",
                              "firefox": "org.mozilla.firefox", "steam": "com.valvesoftware.steam", "slack": "com.tinyspeck.slackmacgap"]

    /// The app whose cache this is, when it can be told: a known folder name or a folder named like a bundle ID.
    static func owner(ofCache name: String) -> String? {
        if let known = cacheOwners[name.lowercased()] { return known }
        let parts = name.split(separator: ".")
        return parts.count >= 3 && !name.hasSuffix(".plist") ? name : nil
    }

    public init(context: ScanContext) {
        self.context = context
    }

    public func scan() -> [CleanGroup] {
        [userCaches(), userLogs(), developerJunk(), brokenPreferences(), mailDownloads(), iosBackups(), aiModels()]
            .compactMap { $0 }
            .map { group in
                var group = group
                group.items = context.policy.annotate(group.items).sorted { $0.size > $1.size }
                return group
            }
    }

    func userCaches() -> CleanGroup? {
        let folder = env.path("Library/Caches")
        guard let children = FileSizer.children(of: folder) else {
            return CleanGroup(id: "caches", title: "Caches utilisateur", explanation: "Fichiers temporaires recréés par les apps.",
                              symbol: "archivebox", items: [], notice: "Dossier illisible sans l'accès complet au disque.")
        }
        let items: [CleanItem] = children.compactMap { url in
            let name = url.lastPathComponent
            if Self.skippedCaches.contains(name.lowercased()) || name == ".DS_Store" { return nil }
            let size = FileSizer.allocatedSize(of: url)
            guard size > 0 else { return nil }
            if Self.toolCachePrefixes.contains(where: { name.lowercased().hasPrefix($0) }) {
                return CleanItem(url: url, subtitle: "Outil installé ici, à réinstaller s'il part", size: size,
                                 selectedByDefault: false, warning: "Contient des navigateurs ou outils téléchargés")
            }
            if Self.isBrowserProfile(url) {
                return CleanItem(url: url, subtitle: "Profil de navigateur", size: size, selectedByDefault: false,
                                 warning: "Contient des sessions et cookies, le supprimer te déconnecte")
            }
            let owner = Self.owner(ofCache: name)
            if let owner, context.isRunning(owner) {
                return CleanItem(url: url, subtitle: "App ouverte", size: size, selectedByDefault: false,
                                 warning: "L'app est ouverte, ferme-la d'abord pour un nettoyage propre").requiring(owner)
            }
            if name.lowercased().hasPrefix("com.apple.") {
                // macOS services keep running in the background: their caches are left unticked.
                return CleanItem(url: url, subtitle: "Service de macOS", size: size, selectedByDefault: false).requiring(owner)
            }
            return CleanItem(url: url, size: size, selectedByDefault: true).requiring(owner)
        }
        return CleanGroup(id: "caches", title: "Caches utilisateur", explanation: "Fichiers temporaires que les apps recréent au besoin.",
                          symbol: "archivebox", items: items)
    }

    /// A Chromium user-data folder parked in Caches (Playwright, automation tools).
    static func isBrowserProfile(_ url: URL) -> Bool {
        FileSizer.exists(url.appendingPathComponent("Local State"))
            || FileSizer.exists(url.appendingPathComponent("Default/Preferences"))
            || FileSizer.exists(url.appendingPathComponent("Default/Cookies"))
    }

    func userLogs() -> CleanGroup? {
        let folder = env.path("Library/Logs")
        guard let children = FileSizer.children(of: folder) else { return nil }
        let items: [CleanItem] = children.compactMap { url in
            let name = url.lastPathComponent
            if name == Product.name || name == ".DS_Store" { return nil }
            let size = FileSizer.allocatedSize(of: url)
            guard size > 0 else { return nil }
            return CleanItem(url: url, size: size, date: FileSizer.modificationDate(url), selectedByDefault: true)
        }
        return CleanGroup(id: "logs", title: "Journaux utilisateur", explanation: "Journaux et rapports de plantage des apps.",
                          symbol: "doc.text", items: items)
    }

    func developerJunk() -> CleanGroup? {
        var items: [CleanItem] = []
        func addChildren(_ relative: String, _ label: String, selected: Bool) {
            guard let children = FileSizer.children(of: env.path(relative)) else { return }
            for url in children where url.lastPathComponent != ".DS_Store" {
                let size = FileSizer.allocatedSize(of: url)
                guard size > 0 else { continue }
                items.append(CleanItem(url: url, subtitle: label, size: size, date: FileSizer.modificationDate(url), selectedByDefault: selected))
            }
        }
        func addFolder(_ relative: String, _ label: String, selected: Bool) {
            let url = env.path(relative)
            guard FileSizer.exists(url) else { return }
            let size = FileSizer.allocatedSize(of: url)
            guard size > 0 else { return }
            items.append(CleanItem(url: url, title: label, subtitle: relative, size: size, selectedByDefault: selected))
        }
        addChildren("Library/Developer/Xcode/DerivedData", "Données dérivées Xcode", selected: true)
        addChildren("Library/Developer/Xcode/iOS DeviceSupport", "Symboles d'appareils iOS", selected: true)
        addChildren("Library/Developer/Xcode/Archives", "Archives Xcode", selected: false)
        addFolder("Library/Developer/CoreSimulator/Caches", "Caches du simulateur", selected: true)
        addFolder(".npm/_cacache", "Cache npm", selected: true)
        guard !items.isEmpty else { return nil }
        return CleanGroup(id: "developer", title: "Déchets de développement", explanation: "Données dérivées, symboles et caches d'outils de développement.",
                          symbol: "hammer", items: items)
    }

    func brokenPreferences() -> CleanGroup? {
        var items: [CleanItem] = []
        for relative in ["Library/Preferences", "Library/Preferences/ByHost"] {
            guard let children = FileSizer.children(of: env.path(relative)) else { continue }
            for url in children where url.pathExtension == "plist" {
                guard let data = try? Data(contentsOf: url) else { continue }
                let isBroken = data.isEmpty || (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
                if isBroken {
                    items.append(CleanItem(url: url, subtitle: "Fichier de réglages illisible", size: FileSizer.allocatedSize(of: url),
                                           date: FileSizer.modificationDate(url), selectedByDefault: true))
                }
            }
        }
        guard !items.isEmpty else { return nil }
        return CleanGroup(id: "preferences", title: "Préférences cassées", explanation: "Fichiers de réglages corrompus que l'app recréera.",
                          symbol: "gearshape.2", items: items)
    }

    func mailDownloads() -> CleanGroup? {
        let folder = env.path("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
        guard FileSizer.exists(env.path("Library/Containers/com.apple.mail")) else { return nil }
        guard let children = FileSizer.children(of: folder) else {
            return CleanGroup(id: "mail", title: "Pièces jointes Mail", explanation: "Copies des pièces jointes ouvertes depuis Mail.",
                              symbol: "paperclip", items: [], notice: "Accès complet au disque requis pour lire les données de Mail.")
        }
        let items = children.filter { $0.lastPathComponent != ".DS_Store" }.map { url in
            CleanItem(url: url, subtitle: "Copie ouverte depuis Mail", size: FileSizer.allocatedSize(of: url),
                      date: FileSizer.modificationDate(url), selectedByDefault: false,
                      warning: "Une pièce jointe modifiée après ouverture n'existe qu'ici")
        }.filter { $0.size > 0 }
        guard !items.isEmpty else { return nil }
        return CleanGroup(id: "mail", title: "Pièces jointes Mail", explanation: "Copies des pièces jointes ouvertes depuis Mail. Les originaux restent dans les mails.",
                          symbol: "paperclip", items: items)
    }

    func iosBackups() -> CleanGroup? {
        let folder = env.path("Library/Application Support/MobileSync/Backup")
        guard FileSizer.exists(folder) else { return nil }
        guard let children = FileSizer.children(of: folder) else {
            return CleanGroup(id: "ios", title: "Sauvegardes iPhone et iPad", explanation: "Sauvegardes locales faites par le Finder.",
                              symbol: "iphone", items: [], notice: "Accès complet au disque requis pour lister les sauvegardes.")
        }
        let backups = children.filter { $0.lastPathComponent != ".DS_Store" }.map { url -> CleanItem in
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Info.plist"))
            let device = info?["Device Name"] as? String ?? url.lastPathComponent
            let date = info?["Last Backup Date"] as? Date
            return CleanItem(url: url, title: device, subtitle: "Sauvegarde du \(Format.date(date))", size: FileSizer.allocatedSize(of: url),
                             date: date, selectedByDefault: false, warning: "Donnée unique si c'est la dernière sauvegarde de l'appareil").sensitive()
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        guard !backups.isEmpty else { return nil }
        return CleanGroup(id: "ios", title: "Sauvegardes iPhone et iPad", explanation: "Sauvegardes locales faites par le Finder. La plus récente est la plus précieuse.",
                          symbol: "iphone", items: backups)
    }

    func aiModels() -> CleanGroup? {
        let candidates: [(String, String)] = [
            (".ollama/models", "Modèles Ollama"),
            (".cache/huggingface", "Cache Hugging Face"),
            (".lmstudio/models", "Modèles LM Studio"),
            (".cache/lm-studio", "Cache LM Studio"),
            (".cache/torch", "Cache PyTorch"),
            ("Library/Application Support/nomic.ai/GPT4All", "Modèles GPT4All"),
        ]
        let items: [CleanItem] = candidates.compactMap { relative, label in
            let url = env.path(relative)
            guard FileSizer.exists(url) else { return nil }
            let size = FileSizer.allocatedSize(of: url)
            guard size > 0 else { return nil }
            return CleanItem(url: url, title: label, subtitle: "~/" + relative, size: size, selectedByDefault: false,
                             warning: "Plusieurs Go à retélécharger, un projet peut en dépendre").sensitive()
        }
        guard !items.isEmpty else { return nil }
        return CleanGroup(id: "ai", title: "Modèles d'IA locaux", explanation: "Modèles d'IA locaux téléchargés par des outils.",
                          symbol: "cpu", items: items)
    }
}
