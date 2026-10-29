import Foundation

public enum SafetyVerdict: Equatable, Sendable {
    case allowed
    case denied(String)

    public var isAllowed: Bool { self == .allowed }
    public var reason: String? {
        if case .denied(let reason) = self { return reason }
        return nil
    }
}

/// Hard-coded exclusions, plus the personal ones of this Mac. Every action re-checks the item here right before touching it.
public struct SafetyPolicy: Sendable {
    public struct Exclusion: Sendable, Hashable, Identifiable {
        public let path: String
        public let label: String
        public let isBuiltIn: Bool
        public var id: String { path }
    }

    public let exclusions: [Exclusion]
    /// Bundle ID prefixes from the personal protections.
    public let protectedApps: [String]
    private let lowercasedExclusions: [(path: String, label: String)]
    private let protectedFolders: Set<String>

    static let builtInRelative: [(String, String)] = [
        ("Library/Mobile Documents", "iCloud Drive"),
        ("Library/CloudStorage", "Google Drive et stockages cloud"),
        ("Google Drive", "Google Drive"),
        ("Library/Application Support/Google/DriveFS", "Google Drive, fichiers en attente d'envoi"),
        ("Library/Application Support/Syncthing", "identité et base de Syncthing"),
        ("Library/Keychains", "trousseaux et mots de passe"),
        ("Library/Logs/\(Product.name)", "journal de \(Product.name)"),
        ("Library/Application Support/\(Product.name)", "protections personnelles de \(Product.name)"),
        (".ssh", "clés SSH"),
        (".gnupg", "clés GPG"),
        (".local", "outils en ligne de commande"),
    ]

    static let builtInAbsolute: [(String, String)] = [
        ("/opt/homebrew", "Homebrew, dont Syncthing"),
        ("/usr/local", "outils en ligne de commande"),
        ("/Library", "réglages et services installés pour tout le Mac"),
        ("/private/etc", "configuration système"),
        ("/private/var", "données système"),
    ]

    static let protectedRelative = [
        "", "Library", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music", "Public", "Applications",
        ".Trash", "Library/Caches", "Library/Logs", "Library/Preferences", "Library/Application Support",
        "Library/Containers", "Library/Group Containers", "Library/LaunchAgents", "Library/Mail", "Library/Safari",
        "Library/Developer", "Library/Saved Application State",
    ]

    static let protectedAbsolute = [
        "/", "/Applications", "/Users", "/Library", "/Volumes", "/private", "/opt", "/opt/homebrew", "/usr/local",
    ]

    static let systemPrefixes = ["/system", "/bin", "/sbin", "/usr", "/private/var/db", "/library/apple", "/cores"]

    public init(environment: CleanEnvironment, userExclusions: [String] = [], personal: PersonalProtections = .load()) {
        var homes = [environment.home]
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        if Self.canonicalPath(realHome.path) != Self.canonicalPath(environment.home.path) {
            homes.append(realHome)
        }

        var list: [Exclusion] = []
        for home in homes {
            for (relative, label) in Self.builtInRelative {
                list.append(Exclusion(path: Self.canonicalPath(home.appendingPathComponent(relative).path), label: label, isBuiltIn: true))
            }
        }
        for home in homes {
            for path in personal.paths(relativeTo: home) {
                list.append(Exclusion(path: Self.canonicalPath(path), label: "protection personnelle", isBuiltIn: true))
            }
        }
        protectedApps = personal.apps.map { $0.lowercased() }
        for (path, label) in Self.builtInAbsolute {
            list.append(Exclusion(path: Self.canonicalPath(path), label: label, isBuiltIn: true))
        }
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            list.append(Exclusion(path: Self.canonicalPath(bundlePath), label: "\(Product.name) lui-même", isBuiltIn: true))
        }
        for path in userExclusions where !path.isEmpty {
            list.append(Exclusion(path: Self.canonicalPath(path), label: "exclusion ajoutée", isBuiltIn: false))
        }
        var seen = Set<String>()
        exclusions = list.filter { seen.insert($0.path.lowercased()).inserted }
        lowercasedExclusions = exclusions.map { ($0.path.lowercased(), $0.label) }

        var protected = Set(Self.protectedAbsolute.map { $0.lowercased() })
        for home in homes {
            for relative in Self.protectedRelative {
                let url = relative.isEmpty ? home : home.appendingPathComponent(relative)
                protected.insert(Self.canonicalPath(url.path).lowercased())
            }
        }
        protectedFolders = protected
    }

    // MARK: - Paths

    /// Resolves every symlink, including the last component.
    public static func canonicalPath(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let nsPath = path as NSString
        let parent = nsPath.deletingLastPathComponent
        if parent.isEmpty || parent == path { return nsPath.standardizingPath }
        return (canonicalPath(parent) as NSString).appendingPathComponent(nsPath.lastPathComponent)
    }

    /// Resolves the parent folders but keeps the item itself: trashing a symlink moves the link, not its target.
    public static func itemPath(_ url: URL) -> String {
        let path = url.path
        if path == "/" { return "/" }
        let nsPath = path as NSString
        return (canonicalPath(nsPath.deletingLastPathComponent) as NSString).appendingPathComponent(nsPath.lastPathComponent)
    }

    static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    // MARK: - Checks

    /// Fast check used while walking folders: true if the scanner should not descend.
    public func isExcluded(path: String) -> Bool {
        let key = path.lowercased()
        return lowercasedExclusions.contains { Self.isInside(key, $0.path) }
    }

    public func exclusionLabel(for url: URL) -> String? {
        let key = Self.itemPath(url).lowercased()
        return lowercasedExclusions.first { Self.isInside(key, $0.path) }?.label
    }

    public func verdict(for url: URL) -> SafetyVerdict {
        let item = Self.itemPath(url)
        let key = item.lowercased()

        if protectedFolders.contains(key) {
            return .denied("Dossier de base, seul son contenu peut être nettoyé")
        }
        for exclusion in lowercasedExclusions {
            if Self.isInside(key, exclusion.path) { return .denied("Exclu : \(exclusion.label)") }
            if Self.isInside(exclusion.path, key) { return .denied("Contient un dossier exclu : \(exclusion.label)") }
        }
        if Self.systemPrefixes.contains(where: { Self.isInside(key, $0) }) && !Self.isInside(key, "/usr/local") {
            return .denied("Protégé par macOS (SIP)")
        }

        var info = stat()
        guard lstat(item, &info) == 0 else { return .denied("Élément introuvable") }

        if (info.st_mode & S_IFMT) == S_IFLNK {
            let target = Self.canonicalPath(item).lowercased()
            if let exclusion = lowercasedExclusions.first(where: { Self.isInside(target, $0.path) }) {
                return .denied("Lien vers un dossier exclu : \(exclusion.label)")
            }
        }
        if info.st_flags & UInt32(SF_RESTRICTED) != 0 {
            return .denied("Protégé par macOS (SIP)")
        }
        if info.st_flags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)) != 0 {
            return .denied("Fichier verrouillé")
        }
        return .allowed
    }
}
