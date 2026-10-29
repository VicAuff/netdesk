import Foundation

public struct BackgroundItem: Sendable, Hashable {
    public var name: String?
    public var developer: String?
    public var type: String = ""
    public var enabled = false
    public var identifier: String?
    public var url: String?
    public var executablePath: String?
    public var bundleID: String?
}

/// Reads the text of `sfltool dumpbtm`, the list behind Settings > General > Login Items.
public enum BTMParser {
    public static func parse(_ text: String, uid: uid_t) -> [BackgroundItem] {
        var inSection = false
        var items: [BackgroundItem] = []
        var current: BackgroundItem?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Records for UID") {
                if let item = current { items.append(item) }
                current = nil
                let uidText = line.dropFirst("Records for UID".count).split(separator: ":").first?.trimmingCharacters(in: .whitespaces)
                inSection = uidText == String(uid)
                continue
            }
            guard inSection else { continue }
            if line.hasPrefix("#"), line.hasSuffix(":"), Int(line.dropFirst().dropLast()) != nil {
                if let item = current { items.append(item) }
                current = BackgroundItem()
                continue
            }
            guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value: String? = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == "(null)" || value?.isEmpty == true { value = nil }
            switch key {
            case "Name": current?.name = value
            case "Developer Name": current?.developer = value
            case "Type": current?.type = value.map { $0.components(separatedBy: " (").first ?? $0 } ?? ""
            case "Disposition":
                let flags = value?.split(separator: "]").first?.dropFirst().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
                current?.enabled = flags.contains("enabled")
            case "Identifier": current?.identifier = value
            case "URL": current?.url = value
            case "Executable Path": current?.executablePath = value
            case "Bundle Identifier": current?.bundleID = value
            default: break
            }
        }
        if inSection, let item = current { items.append(item) }
        return items.filter { $0.type != "developer" && ($0.name != nil || $0.url != nil) }
    }
}

/// Performance module: background items, login items, maintenance.
public struct PerformanceScanner: Sendable {
    let context: ScanContext
    let runner: CommandRunning
    var env: CleanEnvironment { context.environment }

    public init(context: ScanContext, runner: CommandRunning = ProcessRunner()) {
        self.context = context
        self.runner = runner
    }

    public func scan(btmText: String? = nil) -> [CleanGroup] {
        let text = btmText ?? runner.run("/usr/bin/sfltool", ["dumpbtm"]).output
        let items = BTMParser.parse(text, uid: env.userID)
        return [loginGroup(items), backgroundGroup(items), maintenanceGroup()].map { group in
            var group = group
            group.items = context.policy.annotate(group.items)
            return group
        }
    }

    func localPath(_ url: String?) -> String? {
        guard var path = url else { return nil }
        if path.hasPrefix("file://"), let parsed = URL(string: path) { path = parsed.path }
        // sfltool writes the home as /Users/<uid>.
        let uidHome = "/Users/\(env.userID)/"
        if path.hasPrefix(uidHome) { path = env.home.path + "/" + path.dropFirst(uidHome.count) }
        return path
    }

    static func isProtected(_ text: String) -> Bool {
        text.lowercased().contains("syncthing")
    }

    func loginGroup(_ items: [BackgroundItem]) -> CleanGroup {
        let rows = items.filter { $0.type == "app" || $0.type == "login item" }.map { item -> CleanItem in
            let name = item.name ?? item.bundleID ?? "?"
            let path = localPath(item.url)
            return CleanItem(id: "login-\(item.identifier ?? name)", urls: [], title: name,
                             subtitle: [item.developer, item.enabled ? "activé" : "désactivé"].compactMap { $0 }.joined(separator: " · "),
                             size: 0, action: .removeLoginItem(name: name), selectedByDefault: false,
                             blockedReason: item.enabled ? nil : "Déjà désactivé",
                             warning: path.map { "Ouvre \(($0 as NSString).lastPathComponent) à la connexion" })
        }
        return CleanGroup(id: "login", title: "Ouverture à la connexion", explanation: "Apps lancées à l'ouverture de session.",
                          symbol: "power", items: rows,
                          notice: "Si une app refuse, désactive-la dans Réglages Système > Général > Ouverture.")
    }

    func backgroundGroup(_ items: [BackgroundItem]) -> CleanGroup {
        var rows: [CleanItem] = []
        var seenPaths = Set<String>()
        let userAgents = SafetyPolicy.canonicalPath(env.path("Library/LaunchAgents").path).lowercased()
        for item in items where item.type != "app" && item.type != "login item" {
            let name = item.name ?? item.identifier ?? "?"
            let path = localPath(item.url)
            if let path { seenPaths.insert(SafetyPolicy.canonicalPath(path).lowercased()) }
            let subtitle = [item.developer, item.enabled ? "activé" : "désactivé", item.executablePath].compactMap { $0 }.joined(separator: " · ")
            let plistLabel = path.flatMap { $0.hasSuffix(".plist") ? Self.label(of: URL(fileURLWithPath: $0)) : nil } ?? ""
            if Self.isProtected(name) || Self.isProtected(item.identifier ?? "") || Self.isProtected(path ?? "") || Self.isProtected(plistLabel) {
                rows.append(CleanItem(id: "bg-\(item.identifier ?? name)", urls: [], title: name, subtitle: subtitle, size: 0, action: .none,
                                      selectedByDefault: false, blockedReason: "Synchronisation Syncthing, protégée"))
                continue
            }
            if let path, path.hasSuffix(".plist"),
               (SafetyPolicy.canonicalPath(path) as NSString).deletingLastPathComponent.lowercased() == userAgents {
                let url = URL(fileURLWithPath: path)
                rows.append(CleanItem(id: "bg-\(path)", urls: [url], title: name, subtitle: subtitle, size: FileSizer.allocatedSize(of: url),
                                      action: .unloadAndTrash(label: Self.label(of: url)), selectedByDefault: false))
            } else if let path, path.hasPrefix("/Library/") {
                rows.append(CleanItem(id: "bg-\(path)", urls: [], title: name, subtitle: subtitle, size: 0, action: .none,
                                      selectedByDefault: false, blockedReason: "Installé pour tout le Mac, demande les droits administrateur"))
            } else {
                rows.append(CleanItem(id: "bg-\(item.identifier ?? name)", urls: [], title: name, subtitle: subtitle, size: 0, action: .none,
                                      selectedByDefault: false, blockedReason: "Géré par son app : Réglages Système > Général > Ouverture"))
            }
        }
        // Agents present on disk but absent from the list above.
        for url in FileSizer.children(of: env.path("Library/LaunchAgents")) ?? [] where url.pathExtension == "plist" {
            guard !seenPaths.contains(SafetyPolicy.canonicalPath(url.path).lowercased()) else { continue }
            let label = Self.label(of: url)
            let protected = Self.isProtected(label)
            rows.append(CleanItem(id: "bg-\(url.path)", urls: [url], title: label, subtitle: "~/Library/LaunchAgents", size: FileSizer.allocatedSize(of: url),
                                  action: protected ? .none : .unloadAndTrash(label: label), selectedByDefault: false,
                                  blockedReason: protected ? "Synchronisation Syncthing, protégée" : nil))
        }
        return CleanGroup(id: "background", title: "Éléments en arrière-plan", explanation: "Agents et services lancés en arrière-plan. Retirer un agent l'arrête et met son fichier à la Corbeille.",
                          symbol: "gearshape.arrow.triangle.2.circlepath", items: rows)
    }

    static func label(of plist: URL) -> String {
        (NSDictionary(contentsOf: plist)?["Label"] as? String) ?? plist.deletingPathExtension().lastPathComponent
    }

    func maintenanceGroup() -> CleanGroup {
        var rows: [CleanItem] = []
        var notice: String?
        if FileSizer.exists(env.path("Library/Mail")) {
            if let versions = FileSizer.children(of: env.path("Library/Mail")) {
                let files = versions.filter { $0.lastPathComponent.hasPrefix("V") }.flatMap { version -> [URL] in
                    let data = version.appendingPathComponent("MailData")
                    return (FileSizer.children(of: data) ?? []).filter { $0.lastPathComponent.hasPrefix("Envelope Index") }
                }
                if !files.isEmpty {
                    let running = context.isRunning("com.apple.mail")
                    rows.append(CleanItem(id: "maintenance-mail", urls: files, title: "Accélérer Mail",
                                          subtitle: "Mail reconstruit son index au prochain lancement", size: FileSizer.allocatedSize(of: files),
                                          selectedByDefault: false, blockedReason: running ? "Ferme Mail d'abord" : nil,
                                          warning: "La reconstruction peut prendre plusieurs minutes").requiring("com.apple.mail"))
                }
            } else {
                notice = "Accès complet au disque requis pour accélérer Mail."
            }
        }
        let adminOnly = ["Libérer la RAM", "Vider le cache DNS", "Réindexer Spotlight", "Lancer les scripts de maintenance",
                         "Réparer les autorisations du disque", "Alléger les instantanés Time Machine", "Libérer l'espace purgeable"]
        rows += adminOnly.map {
            CleanItem(id: "maintenance-\($0)", urls: [], title: $0, size: 0, action: .none, selectedByDefault: false,
                      blockedReason: "Demande les droits administrateur, désactivé dans \(Product.name)")
        }
        return CleanGroup(id: "maintenance", title: "Tâches de maintenance", explanation: "Entretien du système.",
                          symbol: "wrench.and.screwdriver", items: rows, notice: notice)
    }
}
