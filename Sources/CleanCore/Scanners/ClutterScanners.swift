import CryptoKit
import Foundation

/// Folders of the home that the file sorting walks: everything visible except Library and the exclusions.
func clutterRoots(_ context: ScanContext) -> [URL] {
    let env = context.environment
    guard let children = FileSizer.children(of: env.home) else { return [] }
    return children.filter { url in
        let name = url.lastPathComponent
        if name.hasPrefix(".") || name == "Library" || name == "Applications" { return false }
        if context.policy.isExcluded(path: SafetyPolicy.canonicalPath(url.path)) { return false }
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

struct WalkedFile {
    let url: URL
    let size: Int64
    let modified: Date?
    let accessed: Date?
    let created: Date?
    let isPackage: Bool
}

/// Walks folders without following links, skipping excluded paths and app bundles.
/// Packages (Photos library, project bundles) come back as one file.
func walk(_ roots: [URL], context: ScanContext, includePackages: Bool, visit: (WalkedFile) -> Void) {
    let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey,
                                  .fileAllocatedSizeKey, .contentModificationDateKey, .contentAccessDateKey, .creationDateKey]
    for root in roots {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                              errorHandler: { _, _ in true }) else { continue }
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                // Hidden folders (.git, tool configs) and dependencies are never user documents.
                let name = url.lastPathComponent
                if name.hasPrefix(".") || name == "node_modules" || context.policy.isExcluded(path: SafetyPolicy.canonicalPath(url.path)) {
                    enumerator.skipDescendants()
                    continue
                }
                if values.isPackage == true {
                    enumerator.skipDescendants()
                    if includePackages && url.pathExtension.lowercased() != "app" {
                        visit(WalkedFile(url: url, size: FileSizer.allocatedSize(of: url), modified: values.contentModificationDate,
                                         accessed: values.contentAccessDate, created: values.creationDate, isPackage: true))
                    }
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            if url.lastPathComponent == ".DS_Store" { continue }
            visit(WalkedFile(url: url, size: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0),
                             modified: values.contentModificationDate, accessed: values.contentAccessDate,
                             created: values.creationDate, isPackage: false))
        }
    }
}

func relativeDisplayPath(_ url: URL, home: URL) -> String {
    let path = url.deletingLastPathComponent().path
    let homePath = home.path
    if path.hasPrefix(homePath) { return "~" + path.dropFirst(homePath.count) }
    return path
}

// MARK: - Large & old files

public struct LargeFileScanner: Sendable {
    let context: ScanContext
    let minimumSize: Int64

    public init(context: ScanContext, minimumSize: Int64 = 50_000_000) {
        self.context = context
        self.minimumSize = minimumSize
    }

    public func scan() -> [CleanGroup] {
        var files: [WalkedFile] = []
        walk(clutterRoots(context), context: context, includePackages: true) { file in
            if file.size >= minimumSize { files.append(file) }
        }
        let buckets: [(String, String, ClosedRange<Int64>)] = [
            ("huge", "Plus de 1 Go", 1_000_000_000...Int64.max),
            ("big", "De 250 Mo à 1 Go", 250_000_000...999_999_999),
            ("medium", "De \(Format.bytes(minimumSize)) à 250 Mo", minimumSize...249_999_999),
        ]
        return buckets.compactMap { id, title, range in
            let items = files.filter { range.contains($0.size) }.sorted { $0.size > $1.size }.map { file in
                let lastOpened = file.accessed ?? file.modified
                return CleanItem(url: file.url, subtitle: "\(relativeDisplayPath(file.url, home: context.environment.home)) · ouvert le \(Format.date(lastOpened))",
                                 size: file.size, date: lastOpened, selectedByDefault: false)
            }
            guard !items.isEmpty else { return nil }
            return CleanGroup(id: id, title: title, explanation: "Gros fichiers de ton dossier perso, à trier toi-même.",
                              symbol: "externaldrive", items: context.policy.annotate(items))
        }
    }
}

// MARK: - Duplicates

public struct DuplicateScanner: Sendable {
    let context: ScanContext
    let minimumSize: Int64

    public init(context: ScanContext, minimumSize: Int64 = 512_000) {
        self.context = context
        self.minimumSize = minimumSize
    }

    public func scan() -> [CleanGroup] {
        var bySize: [Int64: [WalkedFile]] = [:]
        var seenInodes = Set<UInt64>()
        walk(clutterRoots(context), context: context, includePackages: false) { file in
            guard file.size >= minimumSize else { return }
            var info = stat()
            if lstat(file.url.path, &info) == 0 {
                // Hard links share an inode: they are the same file, not a copy.
                guard seenInodes.insert(UInt64(info.st_ino)).inserted else { return }
            }
            bySize[file.size, default: []].append(file)
        }
        var groups: [CleanGroup] = []
        for (_, candidates) in bySize where candidates.count > 1 {
            let byPartial = Dictionary(grouping: candidates) { Self.partialHash($0.url) ?? UUID().uuidString }
            for (_, sameStart) in byPartial where sameStart.count > 1 {
                let byFull = Dictionary(grouping: sameStart) { Self.fullHash($0.url) ?? UUID().uuidString }
                for (hash, copies) in byFull where copies.count > 1 {
                    // The oldest copy stays unticked, the others are pre-selected.
                    let sorted = copies.sorted { ($0.created ?? .distantFuture) < ($1.created ?? .distantFuture) }
                    let items = sorted.enumerated().map { index, file in
                        CleanItem(url: file.url, title: file.url.lastPathComponent,
                                  subtitle: "\(relativeDisplayPath(file.url, home: context.environment.home)) · créé le \(Format.date(file.created))",
                                  size: file.size, date: file.created, selectedByDefault: false,
                                  warning: index == 0 ? "Exemplaire le plus ancien" : nil)
                    }
                    groups.append(CleanGroup(id: "dup-\(hash.prefix(16))", title: sorted[0].url.lastPathComponent,
                                             explanation: "\(copies.count) exemplaires identiques",
                                             symbol: "doc.on.doc", items: context.policy.annotate(items)))
                }
            }
        }
        return groups.sorted { $0.totalSize > $1.totalSize }
    }

    static func partialHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        if let head = try? handle.read(upToCount: 65_536) { hasher.update(data: head) }
        if let end = try? handle.seekToEnd(), end > 131_072 {
            try? handle.seek(toOffset: end - 65_536)
            if let tail = try? handle.read(upToCount: 65_536) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Downloads by source

public struct DownloadsScanner: Sendable {
    let context: ScanContext

    public init(context: ScanContext) {
        self.context = context
    }

    static let knownAgents: [(match: String, label: String)] = [
        ("safari", "Safari"), ("chrome", "Google Chrome"), ("firefox", "Firefox"), ("arc", "Arc"), ("brave", "Brave"),
        ("edge", "Microsoft Edge"), ("slack", "Slack"), ("mail", "Mail"), ("messages", "Messages"), ("whatsapp", "WhatsApp"),
        ("sharingd", "AirDrop"), ("airdrop", "AirDrop"), ("telegram", "Telegram"), ("discord", "Discord"),
    ]

    public func scan() -> [CleanGroup] {
        let folder = context.environment.path("Downloads")
        guard let children = FileSizer.children(of: folder) else {
            return [CleanGroup(id: "downloads", title: "Téléchargements", explanation: "", symbol: "arrow.down.circle", items: [],
                               notice: "Autorise l'accès au dossier Téléchargements pour l'analyser.")]
        }
        var bySource: [String: [CleanItem]] = [:]
        for url in children {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            let source = Self.source(of: url)
            let origin = Self.origin(of: url)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let item = CleanItem(url: url, subtitle: [origin, "téléchargé le \(Format.date(created))"].compactMap { $0 }.joined(separator: " · "),
                                 size: FileSizer.allocatedSize(of: url), date: created, selectedByDefault: false)
            bySource[source, default: []].append(item)
        }
        return bySource.map { source, items in
            CleanGroup(id: "dl-\(source)", title: source, explanation: "Fichiers de Téléchargements venus de \(source).",
                       symbol: "arrow.down.circle", items: context.policy.annotate(items.sorted { $0.size > $1.size }))
        }.sorted { $0.totalSize > $1.totalSize }
    }

    /// The quarantine attribute reads "flags;date;agent;uuid".
    static func source(of url: URL) -> String {
        guard let value = xattrString(url, "com.apple.quarantine") else { return "Autres" }
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return "Autres" }
        let agent = String(fields[2]).lowercased()
        if agent.isEmpty { return "Autres" }
        return knownAgents.first { agent.contains($0.match) }?.label ?? String(fields[2])
    }

    static func origin(of url: URL) -> String? {
        guard let data = xattrData(url, "com.apple.metadata:kMDItemWhereFroms"),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String],
              let first = list.first, let host = URL(string: first)?.host else { return nil }
        return host
    }
}

func xattrData(_ url: URL, _ name: String) -> Data? {
    let length = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
    guard length > 0 else { return nil }
    var data = Data(count: length)
    let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
    return read > 0 ? data.prefix(read) : nil
}

func xattrString(_ url: URL, _ name: String) -> String? {
    xattrData(url, name).map { String(decoding: $0, as: UTF8.self) }
}

// MARK: - Installers

public struct InstallerScanner: Sendable {
    let context: ScanContext
    let mountedImages: Set<String>
    let isEncrypted: @Sendable (URL) -> Bool

    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip"]

    public init(context: ScanContext, mountedImages: Set<String> = [], isEncrypted: (@Sendable (URL) -> Bool)? = nil) {
        self.context = context
        self.mountedImages = mountedImages
        self.isEncrypted = isEncrypted ?? InstallerScanner.hdiutilSaysEncrypted
    }

    /// An encrypted disk image may be a vault of documents, not an installer.
    public static let hdiutilSaysEncrypted: @Sendable (URL) -> Bool = { url in
        guard url.pathExtension.lowercased() == "dmg" else { return false }
        let result = ProcessRunner().run("/usr/bin/hdiutil", ["isencrypted", "-plist", url.path])
        if let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any] {
            return plist["encrypted"] as? Bool ?? false
        }
        return result.output.lowercased().contains("encrypted: yes")
    }

    /// Paths of disk images currently mounted, from `hdiutil info`.
    public static func currentlyMountedImages(runner: CommandRunning = ProcessRunner()) -> Set<String> {
        let result = runner.run("/usr/bin/hdiutil", ["info", "-plist"])
        guard result.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: Data(result.output.utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { $0["image-path"] as? String }.map(SafetyPolicy.canonicalPath))
    }

    public func scan() -> [CleanGroup] {
        let env = context.environment
        let roots = ["Downloads", "Desktop", "Documents"].map(env.path)
        var items: [CleanItem] = []
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                  options: [.skipsHiddenFiles], errorHandler: { _, _ in true }) else { continue }
            while let url = enumerator.nextObject() as? URL {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                if isDirectory && context.policy.isExcluded(path: SafetyPolicy.canonicalPath(url.path)) {
                    enumerator.skipDescendants()
                    continue
                }
                if enumerator.level > 3 { enumerator.skipDescendants() }
                guard Self.extensions.contains(url.pathExtension.lowercased()) else { continue }
                if isDirectory { enumerator.skipDescendants() }
                let date = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                let mounted = mountedImages.contains(SafetyPolicy.canonicalPath(url.path))
                let encrypted = isEncrypted(url)
                let inDownloads = root.lastPathComponent == "Downloads"
                let ticked = !mounted && !encrypted && inDownloads && url.pathExtension.lowercased() != "iso" && (date ?? .distantPast) < weekAgo
                items.append(CleanItem(url: url, subtitle: "\(relativeDisplayPath(url, home: env.home)) · \(Format.date(date))",
                                       size: FileSizer.allocatedSize(of: url), date: date, selectedByDefault: ticked,
                                       blockedReason: mounted ? "Image montée, éjecte-la d'abord" : nil,
                                       warning: encrypted ? "Image chiffrée : peut contenir des documents" : nil))
            }
        }
        guard !items.isEmpty else { return [] }
        return [CleanGroup(id: "installers", title: "Installeurs et images disque", explanation: "Fichiers .dmg, .pkg et .iso déjà utilisés en général.",
                           symbol: "shippingbox", items: context.policy.annotate(items.sorted { $0.size > $1.size }))]
    }
}
