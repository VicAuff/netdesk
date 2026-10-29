import Foundation

/// Trash bins of the Mac and of mounted volumes. Emptying them is the only permanent deletion in the app.
public struct TrashBinScanner: Sendable {
    let context: ScanContext

    public init(context: ScanContext) {
        self.context = context
    }

    public func scan() -> [CleanGroup] {
        var groups: [CleanGroup] = []
        let env = context.environment
        groups.append(group(id: "trash-home", title: "Corbeille", folder: env.trash))
        if let volumes = FileSizer.children(of: env.volumesDirectory) {
            for volume in volumes {
                var info = stat()
                // The boot volume appears as a symlink to "/": its Trash is ~/.Trash, already listed.
                if lstat(volume.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK { continue }
                let folder = volume.appendingPathComponent(".Trashes/\(env.userID)")
                guard FileSizer.exists(folder) else { continue }
                groups.append(group(id: "trash-\(volume.lastPathComponent)", title: "Corbeille de \(volume.lastPathComponent)", folder: folder))
            }
        }
        return groups
    }

    func group(id: String, title: String, folder: URL) -> CleanGroup {
        guard let children = FileSizer.children(of: folder) else {
            return CleanGroup(id: id, title: title, explanation: "Éléments déjà mis à la Corbeille.", symbol: "trash", items: [],
                              notice: "La Corbeille ne se lit qu'avec l'accès complet au disque.")
        }
        let items = children.filter { $0.lastPathComponent != ".DS_Store" }.map { url in
            CleanItem(url: url, size: FileSizer.allocatedSize(of: url), date: FileSizer.modificationDate(url),
                      action: .deletePermanently, selectedByDefault: true)
        }.sorted { $0.size > $1.size }
        return CleanGroup(id: id, title: title, explanation: "Vider la Corbeille supprime ces éléments définitivement.",
                          symbol: "trash", items: items)
    }
}
