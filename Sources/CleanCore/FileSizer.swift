import Foundation

public enum FileSizer {
    static let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]

    /// Disk space used by a file or a whole folder. Symlinks are not followed.
    public static func allocatedSize(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let child = enumerator?.nextObject() as? URL {
            guard let childValues = try? child.resourceValues(forKeys: Set(keys)), childValues.isRegularFile == true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }

    public static func allocatedSize(of urls: [URL]) -> Int64 {
        urls.reduce(0) { $0 + allocatedSize(of: $1) }
    }

    /// Children of a folder, hidden files included, or nil when macOS refuses the listing.
    public static func children(of url: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
    }

    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    public static func modificationDate(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
