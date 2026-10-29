import CoreServices
import Foundation
import SQLite3

/// Protection > Privacy: browser traces, recent items, app permissions.
/// Browser files go to the Trash, so the browser recreates them empty and nothing is lost for good.
public struct PrivacyScanner: Sendable {
    let context: ScanContext
    var env: CleanEnvironment { context.environment }

    public init(context: ScanContext) {
        self.context = context
    }

    struct Chromium {
        let name: String
        let bundleID: String
        let folder: String
    }

    static let chromiumBrowsers = [
        Chromium(name: "Google Chrome", bundleID: "com.google.Chrome", folder: "Library/Application Support/Google/Chrome"),
        Chromium(name: "Brave", bundleID: "com.brave.Browser", folder: "Library/Application Support/BraveSoftware/Brave-Browser"),
        Chromium(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", folder: "Library/Application Support/Microsoft Edge"),
        Chromium(name: "Arc", bundleID: "company.thebrowser.Browser", folder: "Library/Application Support/Arc/User Data"),
        Chromium(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", folder: "Library/Application Support/Vivaldi"),
        Chromium(name: "Chromium", bundleID: "org.chromium.Chromium", folder: "Library/Application Support/Chromium"),
    ]

    public func scan() -> [CleanGroup] {
        var groups: [CleanGroup] = []
        groups.append(contentsOf: Self.chromiumBrowsers.compactMap(chromiumGroup))
        if let safari = safariGroup() { groups.append(safari) }
        if let firefox = firefoxGroup() { groups.append(firefox) }
        groups.append(recentItemsGroup())
        groups.append(permissionsGroup())
        groups.append(CleanGroup(id: "wifi", title: "Réseaux Wi-Fi mémorisés", explanation: "Oublier un réseau demande les droits administrateur.",
                                 symbol: "wifi", items: [], notice: "Non pris en charge : \(Product.name) ne demande jamais les droits administrateur."))
        return groups.map { group in
            var group = group
            group.items = context.policy.annotate(group.items)
            return group
        }
    }

    // MARK: - Browsers

    func browserItem(id: String, title: String, files: [URL], browser: String, bundleID: String, selected: Bool = false,
                     warning: String? = nil, sensitive: Bool = false) -> CleanItem? {
        let existing = files.filter(FileSizer.exists)
        guard !existing.isEmpty else { return nil }
        let running = context.isRunning(bundleID)
        let item = CleanItem(id: id, urls: existing, title: title, subtitle: browser, size: FileSizer.allocatedSize(of: existing),
                             selectedByDefault: selected && !running, blockedReason: running ? "Ferme \(browser) d'abord" : nil, warning: warning)
            .requiring(bundleID)
        return sensitive ? item.sensitive() : item
    }

    /// Syncthing always, plus the apps listed in the personal protections.

    func chromiumGroup(_ browser: Chromium) -> CleanGroup? {
        let base = env.path(browser.folder)
        guard let children = FileSizer.children(of: base) else { return nil }
        let profiles = children.filter { url in
            let name = url.lastPathComponent
            return (name == "Default" || name.hasPrefix("Profile ")) && FileSizer.exists(url.appendingPathComponent("Preferences"))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var items: [CleanItem] = []
        for profile in profiles {
            let label = profiles.count > 1 ? " (\(profile.lastPathComponent))" : ""
            let p = { (names: [String]) in names.map { profile.appendingPathComponent($0) } }
            let prefix = "\(browser.bundleID)-\(profile.lastPathComponent)"
            items += [
                browserItem(id: "\(prefix)-history", title: "Historique" + label,
                            files: p(["History", "History-journal", "Visited Links", "Top Sites", "Top Sites-journal"]),
                            browser: browser.name, bundleID: browser.bundleID),
                browserItem(id: "\(prefix)-cookies", title: "Cookies" + label,
                            files: p(["Cookies", "Cookies-journal", "Network/Cookies", "Network/Cookies-journal"]),
                            browser: browser.name, bundleID: browser.bundleID, warning: "Te déconnecte des sites"),
                browserItem(id: "\(prefix)-autofill", title: "Saisie automatique" + label, files: p(["Web Data", "Web Data-journal"]),
                            browser: browser.name, bundleID: browser.bundleID, warning: "Efface aussi les cartes et moteurs de recherche ajoutés", sensitive: true),
                browserItem(id: "\(prefix)-storage", title: "Stockage local des sites" + label, files: p(["Local Storage", "Session Storage"]),
                            browser: browser.name, bundleID: browser.bundleID),
                browserItem(id: "\(prefix)-passwords", title: "Mots de passe enregistrés" + label,
                            files: p(["Login Data", "Login Data-journal", "Login Data For Account", "Login Data For Account-journal"]),
                            browser: browser.name, bundleID: browser.bundleID, warning: "Mots de passe perdus s'ils ne sont pas synchronisés ailleurs", sensitive: true),
            ].compactMap { $0 }
        }
        guard !items.isEmpty else { return nil }
        return CleanGroup(id: browser.bundleID, title: browser.name, explanation: "Traces de navigation, mises à la Corbeille. Le navigateur repart à vide.",
                          symbol: "globe", items: items)
    }

    func safariGroup() -> CleanGroup? {
        let id = "com.apple.Safari"
        guard FileSizer.exists(env.path("Library/Safari")) || FileSizer.exists(env.path("Library/Containers/com.apple.Safari")) else { return nil }
        let safari = { (names: [String]) in names.map { self.env.path("Library/Safari/" + $0) } }
        let container = { (names: [String]) in names.map { self.env.path("Library/Containers/com.apple.Safari/Data/Library/" + $0) } }
        let items = [
            browserItem(id: "safari-history", title: "Historique",
                        files: safari(["History.db", "History.db-wal", "History.db-shm", "History.db-lock", "RecentlyClosedTabs.plist"]),
                        browser: "Safari", bundleID: id, warning: "Safari peut le resynchroniser depuis iCloud"),
            browserItem(id: "safari-downloads", title: "Liste des téléchargements", files: safari(["Downloads.plist"]), browser: "Safari", bundleID: id),
            browserItem(id: "safari-cookies", title: "Cookies", files: container(["Cookies/Cookies.binarycookies"]),
                        browser: "Safari", bundleID: id, warning: "Te déconnecte des sites"),
            browserItem(id: "safari-storage", title: "Stockage local des sites",
                        files: safari(["LocalStorage"]) + container(["WebKit/WebsiteData/LocalStorage", "WebKit/WebsiteData/Default"]),
                        browser: "Safari", bundleID: id),
        ].compactMap { $0 }
        let readable = FileSizer.children(of: env.path("Library/Safari")) != nil
        guard !items.isEmpty || !readable else { return nil }
        return CleanGroup(id: id, title: "Safari", explanation: "Traces de navigation, mises à la Corbeille. Safari repart à vide.",
                          symbol: "safari", items: items, notice: readable ? nil : "Accès complet au disque requis pour lire les données de Safari.")
    }

    func firefoxGroup() -> CleanGroup? {
        let id = "org.mozilla.firefox"
        guard let profiles = FileSizer.children(of: env.path("Library/Application Support/Firefox/Profiles")) else { return nil }
        var items: [CleanItem] = []
        for profile in profiles where FileSizer.exists(profile.appendingPathComponent("prefs.js")) {
            let label = profiles.count > 1 ? " (\(profile.lastPathComponent))" : ""
            let p = { (names: [String]) in names.map { profile.appendingPathComponent($0) } }
            let prefix = "firefox-\(profile.lastPathComponent)"
            items += [
                browserItem(id: "\(prefix)-cookies", title: "Cookies" + label, files: p(["cookies.sqlite", "cookies.sqlite-wal"]),
                            browser: "Firefox", bundleID: id, warning: "Te déconnecte des sites"),
                browserItem(id: "\(prefix)-autofill", title: "Saisie automatique" + label, files: p(["formhistory.sqlite"]), browser: "Firefox", bundleID: id, sensitive: true),
                browserItem(id: "\(prefix)-storage", title: "Stockage local des sites" + label, files: p(["webappsstore.sqlite"]), browser: "Firefox", bundleID: id),
                browserItem(id: "\(prefix)-passwords", title: "Mots de passe enregistrés" + label, files: p(["logins.json", "logins-backup.json"]),
                            browser: "Firefox", bundleID: id, warning: "Mots de passe perdus s'ils ne sont pas synchronisés ailleurs", sensitive: true),
            ].compactMap { $0 }
        }
        guard !items.isEmpty else { return nil }
        return CleanGroup(id: id, title: "Firefox", explanation: "L'historique de Firefox partage son fichier avec les favoris, il n'est donc pas proposé.",
                          symbol: "flame", items: items)
    }

    // MARK: - Recent items

    func recentItemsGroup() -> CleanGroup {
        let folder = env.path("Library/Application Support/com.apple.sharedfilelist")
        guard let children = FileSizer.children(of: folder) else {
            return CleanGroup(id: "recents", title: "Éléments récents", explanation: "Listes des apps, documents et serveurs récents.",
                              symbol: "clock.arrow.circlepath", items: [], notice: "Dossier illisible sans l'accès complet au disque.")
        }
        let kinds: [(String, String)] = [("RecentApplications", "Applications récentes"), ("RecentDocuments", "Documents récents"),
                                         ("RecentServers", "Serveurs récents"), ("RecentHosts", "Ordinateurs récents")]
        var items: [CleanItem] = kinds.compactMap { prefix, title in
            let files = children.filter { $0.lastPathComponent.hasPrefix("com.apple.LSSharedFileList.\(prefix).sfl") }
            guard !files.isEmpty else { return nil }
            return CleanItem(id: "recents-\(prefix)", urls: files, title: title, subtitle: "Menu Pomme > Éléments récents",
                             size: FileSizer.allocatedSize(of: files), selectedByDefault: false)
        }
        if let perApp = FileSizer.children(of: folder.appendingPathComponent("com.apple.LSSharedFileList.ApplicationRecentDocuments")),
           !perApp.isEmpty {
            items.append(CleanItem(id: "recents-perapp", urls: perApp, title: "Documents récents de chaque app",
                                   subtitle: "\(perApp.count) listes", size: FileSizer.allocatedSize(of: perApp), selectedByDefault: false))
        }
        return CleanGroup(id: "recents", title: "Éléments récents", explanation: "Listes des apps, documents et serveurs ouverts récemment.",
                          symbol: "clock.arrow.circlepath", items: items)
    }

    // MARK: - App permissions

    static let serviceLabels: [String: String] = [
        "kTCCServiceCamera": "Caméra", "kTCCServiceMicrophone": "Micro", "kTCCServiceScreenCapture": "Enregistrement de l'écran",
        "kTCCServiceAccessibility": "Accessibilité", "kTCCServiceListenEvent": "Surveillance de la saisie",
        "kTCCServiceSystemPolicyAllFiles": "Accès complet au disque", "kTCCServiceAppleEvents": "Automatisation",
        "kTCCServiceAddressBook": "Contacts", "kTCCServiceCalendar": "Calendriers", "kTCCServiceReminders": "Rappels",
        "kTCCServicePhotos": "Photos", "kTCCServiceSystemPolicyDesktopFolder": "Dossier Bureau",
        "kTCCServiceSystemPolicyDocumentsFolder": "Dossier Documents", "kTCCServiceSystemPolicyDownloadsFolder": "Dossier Téléchargements",
        "kTCCServiceBluetoothAlways": "Bluetooth", "kTCCServicePostEvent": "Contrôle du clavier et de la souris",
        "kTCCServiceSystemPolicyAppData": "Données des autres apps", "kTCCServiceMediaLibrary": "Musique et vidéos",
        "kTCCServiceSystemPolicyRemovableVolumes": "Volumes amovibles", "kTCCServiceSystemPolicyNetworkVolumes": "Volumes réseau",
        "kTCCServiceSpeechRecognition": "Reconnaissance vocale", "kTCCServiceDeveloperTool": "Outils de développement",
    ]

    func permissionsGroup() -> CleanGroup {
        let databases = [env.path("Library/Application Support/com.apple.TCC/TCC.db"),
                         URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")]
        var rows: [(service: String, client: String)] = []
        var readable = false
        for database in databases where database.path.hasPrefix(env.home.path) || env.isRealSystem {
            if let found = Self.grantedPermissions(in: database) {
                readable = true
                rows.append(contentsOf: found)
            }
        }
        guard readable else {
            return CleanGroup(id: "permissions", title: "Autorisations des apps", explanation: "Caméra, micro, accessibilité, accès au disque...",
                              symbol: "hand.raised", items: [], notice: "Accès complet au disque requis pour lire les autorisations.")
        }
        let ownID = Bundle.main.bundleIdentifier ?? Product.name
        let protectedClients = ["syncthing"] + context.policy.protectedApps
        var seen = Set<String>()
        let items: [CleanItem] = rows.compactMap { row in
            let key = "\(row.service)|\(row.client)"
            guard seen.insert(key).inserted else { return nil }
            let service = row.service.replacingOccurrences(of: "kTCCService", with: "")
            let label = Self.serviceLabels[row.service] ?? service
            let appName = Self.displayName(forClient: row.client)
            let lowered = row.client.lowercased()
            let blocked = row.client == ownID ? "\(Product.name) en a besoin"
                : protectedClients.contains(where: { lowered.contains($0) }) ? "App protégée dans tes réglages" : nil
            return CleanItem(id: "tcc-\(key)", urls: [], title: "\(appName) : \(label)", subtitle: row.client, size: 0,
                             action: .revokePermission(service: service, client: row.client), selectedByDefault: false,
                             blockedReason: blocked, warning: "L'app redemandera l'autorisation à sa prochaine utilisation").sensitive()
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return CleanGroup(id: "permissions", title: "Autorisations des apps", explanation: "Retirer une autorisation la remet à zéro : l'app la redemandera.",
                          symbol: "hand.raised", items: items)
    }

    static func grantedPermissions(in database: URL) -> [(service: String, client: String)]? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT service, client FROM access WHERE auth_value = 2", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        var rows: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let service = sqlite3_column_text(statement, 0), let client = sqlite3_column_text(statement, 1) else { continue }
            rows.append((String(cString: service), String(cString: client)))
        }
        return rows
    }

    static func displayName(forClient client: String) -> String {
        if client.hasPrefix("/") { return (client as NSString).lastPathComponent }
        if let url = (LSCopyApplicationURLsForBundleIdentifier(client as CFString, nil)?.takeRetainedValue() as? [URL])?.first {
            return url.deletingPathExtension().lastPathComponent
        }
        return client
    }
}
