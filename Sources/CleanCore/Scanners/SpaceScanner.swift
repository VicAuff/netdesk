import Foundation

/// One folder or file in the disk map.
public final class SpaceNode: Identifiable, @unchecked Sendable {
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public internal(set) var size: Int64 = 0
    public internal(set) var children: [SpaceNode] = []
    /// Files under the size threshold, summed instead of listed.
    public internal(set) var smallFilesSize: Int64 = 0
    public internal(set) var smallFilesCount = 0
    public internal(set) var isReadable = true
    public internal(set) var skippedReason: String?
    public weak var parent: SpaceNode?

    public var id: String { url.path }

    init(url: URL, isDirectory: Bool, isPackage: Bool) {
        self.url = url
        self.name = url.path == "/" ? "Macintosh HD" : url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
    }
}

public final class SpaceScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0
    private var _cancelled = false

    public init() {}

    public var files: Int {
        lock.lock(); defer { lock.unlock() }
        return _files
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }

    func add(_ count: Int) {
        lock.lock(); _files += count; lock.unlock()
    }
}

public struct SpaceScanner: Sendable {
    let context: ScanContext
    let minimumListedFileSize: Int64

    public init(context: ScanContext, minimumListedFileSize: Int64 = 1_000_000) {
        self.context = context
        self.minimumListedFileSize = minimumListedFileSize
    }

    /// Mount points and firmlinks that would count the data volume twice when scanning "/".
    static let skippedFromRoot: Set<String> = ["/system/volumes", "/volumes", "/dev", "/net", "/home", "/private/var/vm"]

    var cloudRoots: [String] {
        ["Library/CloudStorage", "Library/Mobile Documents"].map {
            SafetyPolicy.canonicalPath(context.environment.path($0).path).lowercased()
        }
    }

    public func scan(_ root: URL, progress: SpaceScanProgress = SpaceScanProgress()) -> SpaceNode {
        let node = SpaceNode(url: root, isDirectory: true, isPackage: false)
        fill(node, progress: progress, cloudRoots: Set(cloudRoots))
        return node
    }

    static let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    private func fill(_ node: SpaceNode, progress: SpaceScanProgress, cloudRoots: Set<String>) {
        guard !progress.isCancelled else { return }
        let key = node.url.path.lowercased()
        if Self.skippedFromRoot.contains(key) {
            node.skippedReason = "Volume monté ou doublon du disque, non compté"
            return
        }
        if cloudRoots.contains(key) {
            // Listing a cloud folder can trigger network enumeration; its local size is mostly placeholders.
            node.skippedReason = "Stockage cloud, non analysé"
            return
        }
        guard let children = try? FileManager.default.contentsOfDirectory(at: node.url, includingPropertiesForKeys: Self.keys, options: []) else {
            node.isReadable = false
            return
        }
        var files = 0
        for child in children {
            guard let values = try? child.resourceValues(forKeys: Set(Self.keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                let sub = SpaceNode(url: child, isDirectory: true, isPackage: values.isPackage == true)
                sub.parent = node
                fill(sub, progress: progress, cloudRoots: cloudRoots)
                node.children.append(sub)
                node.size += sub.size
            } else {
                files += 1
                let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                node.size += size
                if size >= minimumListedFileSize {
                    let leaf = SpaceNode(url: child, isDirectory: false, isPackage: false)
                    leaf.size = size
                    leaf.parent = node
                    node.children.append(leaf)
                } else {
                    node.smallFilesSize += size
                    node.smallFilesCount += 1
                }
            }
        }
        progress.add(files)
        node.children.sort { $0.size > $1.size }
    }

    /// The disk map shows the whole disk but only trashes your own files: inside the home folder,
    /// outside ~/Library, ~/Applications and the hidden folders at its root.
    public static func selectionBlock(for url: URL, environment: CleanEnvironment) -> String? {
        let home = SafetyPolicy.canonicalPath(environment.home.path).lowercased()
        let path = SafetyPolicy.itemPath(url).lowercased()
        guard path.hasPrefix(home + "/") else { return "Hors de ton dossier perso : la carte du disque ne fait que montrer" }
        let first = path.dropFirst(home.count + 1).split(separator: "/").first.map(String.init) ?? ""
        if first == "library" { return "Bibliothèque : passe par Nettoyage ou le Désinstalleur" }
        if first == "applications" { return "Apps : passe par le Désinstalleur" }
        if first.hasPrefix(".") { return "Dossier caché de configuration" }
        return nil
    }

    /// Removes a trashed node and subtracts its size up the tree.
    public static func remove(_ node: SpaceNode) {
        guard let parent = node.parent else { return }
        parent.children.removeAll { $0 === node }
        var ancestor: SpaceNode? = parent
        while let current = ancestor {
            current.size -= node.size
            ancestor = current.parent
        }
    }
}
