import CoreServices
import Foundation

public struct InstalledApp: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let bundleID: String?
    public let version: String?
    public let size: Int64
    public let lastUsed: Date?
    public let isAppStore: Bool
    public let isOwnedByRoot: Bool
    public let isRunning: Bool
    public let blockedReason: String?

    public var id: String { url.path }
}

/// Places in ~/Library where apps leave files, named after their bundle ID or their name.
let leftoverLocations = [
    "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Preferences/ByHost", "Library/Containers",
    "Library/Group Containers", "Library/Saved Application State", "Library/HTTPStorages", "Library/WebKit", "Library/Logs",
    "Library/LaunchAgents", "Library/Cookies", "Library/Application Scripts",
]

/// Reverse-DNS prefixes never reported as leftovers: Apple, Homebrew, Swift, Syncthing. Personal ones come from the policy.
let protectedIDPrefixes = ["com.apple.", "group.com.apple.", "is.workflow.", "sh.brew.", "org.swift.", "net.syncthing.", "org.syncthing."]

public struct ApplicationScanner: Sendable {
    let context: ScanContext
    let knownBundleID: @Sendable (String) -> Bool

    public init(context: ScanContext, knownBundleID: (@Sendable (String) -> Bool)? = nil) {
        self.context = context
        self.knownBundleID = knownBundleID ?? ApplicationScanner.launchServicesKnows
    }

    /// True when Launch Services knows an app with this bundle ID somewhere on the Mac.
    public static let launchServicesKnows: @Sendable (String) -> Bool = { bundleID in
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else { return false }
        return !urls.isEmpty
    }

    // MARK: - Installed apps

    public func installedApps() -> [InstalledApp] {
        var bundles: [URL] = []
        for directory in context.environment.applicationDirectories {
            guard let children = FileSizer.children(of: directory) else { continue }
            for child in children {
                if child.pathExtension == "app" {
                    bundles.append(child)
                } else if (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                          let nested = FileSizer.children(of: child) {
                    bundles.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                }
            }
        }
        return bundles.map(app(at:)).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func app(at url: URL) -> InstalledApp {
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        let bundleID = bundle?.bundleIdentifier ?? info?["CFBundleIdentifier"] as? String
        var owner = stat()
        let ownedByRoot = lstat(url.path, &owner) == 0 && owner.st_uid == 0
        let running = bundleID.map(context.isRunning) ?? false
        var blocked: String?
        if case .denied(let reason) = context.policy.verdict(for: url) { blocked = reason }
        if running && blocked == nil { blocked = "App ouverte, quitte-la d'abord" }
        return InstalledApp(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            version: info?["CFBundleShortVersionString"] as? String,
            size: FileSizer.allocatedSize(of: url),
            lastUsed: Self.lastUsedDate(url),
            isAppStore: FileSizer.exists(url.appendingPathComponent("Contents/_MASReceipt/receipt")),
            isOwnedByRoot: ownedByRoot,
            isRunning: running,
            blockedReason: blocked
        )
    }

    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    // MARK: - Uninstaller

    /// The app itself plus every file found under its bundle ID (ticked) or its exact name (unticked).
    /// `installed` lets the matching ignore files that belong to another installed app with a longer ID (Chrome vs Chrome Canary).
    public func uninstallItems(for app: InstalledApp, installed: [InstalledApp] = []) -> [CleanItem] {
        let appItem = CleanItem(url: app.url, title: app.name, subtitle: "Application", size: app.size, date: app.lastUsed,
                                selectedByDefault: app.blockedReason == nil, blockedReason: app.blockedReason,
                                warning: app.isOwnedByRoot ? "Appartient au système, macOS demandera ton mot de passe" : nil)
        let others = Set(installed.compactMap { $0.bundleID?.lowercased() }).subtracting([app.bundleID?.lowercased() ?? ""])
        var rest = leftovers(bundleID: app.bundleID, name: app.name, otherBundleIDs: others)
        if app.blockedReason != nil {
            // A locked or open app keeps its files: they are its live data.
            rest = rest.map { $0.blocked("L'app reste en place, ses fichiers aussi") }
        }
        return ([appItem] + rest).map { $0.requiring(app.bundleID) }
    }

    public func leftovers(bundleID: String?, name: String?, otherBundleIDs: Set<String> = []) -> [CleanItem] {
        let env = context.environment
        let id = bundleID?.lowercased()
        let appName = name?.lowercased()
        var items: [CleanItem] = []
        for location in leftoverLocations {
            guard let children = FileSizer.children(of: env.path(location)) else { continue }
            for url in children {
                let entry = url.lastPathComponent.lowercased()
                var byID = false
                if let id, !id.isEmpty {
                    let stem = Self.strippedExtension(entry)
                    byID = stem == id || stem.hasPrefix(id + ".") || entry.hasSuffix("." + id) || entry == "group." + id
                }
                let byName = !byID && appName != nil && (appName?.count ?? 0) >= 4 && Self.strippedExtension(entry) == appName
                guard byID || byName else { continue }
                let stem = Self.strippedExtension(entry)
                if otherBundleIDs.contains(where: { other in
                    other.count > (id?.count ?? 0) && (stem == other || stem.hasPrefix(other + ".") || entry.hasSuffix("." + other))
                }) { continue }
                if location == "Library/Preferences/ByHost" && !byID { continue }
                items.append(CleanItem(url: url, subtitle: "~/\(location)", size: FileSizer.allocatedSize(of: url),
                                       selectedByDefault: byID,
                                       warning: byName ? "Trouvé par le nom de l'app, vérifie avant de cocher" : nil))
            }
        }
        return context.policy.annotate(items).sorted { $0.size > $1.size }
    }

    static func strippedExtension(_ name: String) -> String {
        for suffix in [".plist", ".savedstate", ".binarycookies"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    // MARK: - Leftovers of apps already gone

    public func orphanLeftovers(installed: [InstalledApp]) -> [CleanGroup] {
        let env = context.environment
        let installedIDs = Set(installed.compactMap { $0.bundleID?.lowercased() })
        let installedVendors = Set(installedIDs.map(Self.vendor))
        var byID: [String: [CleanItem]] = [:]
        // Group Containers are shared between the apps of one vendor under names that match no bundle ID.
        for location in leftoverLocations where location != "Library/Group Containers" {
            guard let children = FileSizer.children(of: env.path(location)) else { continue }
            for url in children {
                guard let candidate = Self.bundleIDCandidate(from: url.lastPathComponent) else { continue }
                let ownID = Bundle.main.bundleIdentifier?.lowercased() ?? Product.name.lowercased()
                if (protectedIDPrefixes + context.policy.protectedApps).contains(where: { candidate.hasPrefix($0) })
                    || candidate.contains("apple") || candidate.hasPrefix(ownID) { continue }
                if installedIDs.contains(where: { candidate == $0 || candidate.hasPrefix($0 + ".") }) { continue }
                if installedVendors.contains(Self.vendor(candidate)) { continue }
                if context.runningBundleIDs.contains(where: { $0.lowercased() == candidate }) { continue }
                byID[candidate, default: []].append(
                    CleanItem(url: url, subtitle: "~/\(location)", size: FileSizer.allocatedSize(of: url), selectedByDefault: false,
                              warning: "Rapprochement par le nom du dossier, vérifie avant de cocher"))
            }
        }
        return byID.compactMap { candidate, items in
            // Launch Services still knows the app: it lives somewhere else, these are not leftovers.
            if knownBundleID(candidate) { return nil }
            return CleanGroup(id: "orphan-\(candidate)", title: candidate, explanation: "Aucune app installée ne porte cet identifiant.",
                              symbol: "questionmark.folder", items: context.policy.annotate(items))
        }.sorted { $0.totalSize > $1.totalSize }
    }

    static func vendor(_ bundleID: String) -> String {
        bundleID.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// "com.vendor.app.plist", "TEAMID1234.com.vendor.app", "group.com.vendor.app" -> "com.vendor.app".
    static func bundleIDCandidate(from entry: String) -> String? {
        var name = strippedExtension(entry.lowercased())
        var parts = name.split(separator: ".").map(String.init)
        if let first = entry.split(separator: ".").first, first.count == 10,
           first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            parts.removeFirst()
        } else if parts.first == "group" {
            parts.removeFirst()
        }
        // ByHost files end with a host UUID.
        if let last = parts.last, last.count >= 12, last.contains("-") || last.allSatisfy(\.isHexDigit) {
            parts.removeLast()
        }
        guard parts.count >= 3, let tld = parts.first, (2...4).contains(tld.count), tld.allSatisfy(\.isLetter) else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }) else { return nil }
        name = parts.joined(separator: ".")
        return name
    }

    // MARK: - Unused apps

    public static let unusedAfterDays = 90

    public static func isUnused(_ app: InstalledApp, now: Date = Date()) -> Bool {
        guard let lastUsed = app.lastUsed else { return true }
        return lastUsed < now.addingTimeInterval(-Double(Self.unusedAfterDays) * 86_400)
    }
}
