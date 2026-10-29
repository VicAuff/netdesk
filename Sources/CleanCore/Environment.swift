import Foundation

/// Where the scanners look. Tests point `home` at a fake folder so nothing real is touched.
public struct CleanEnvironment: Sendable {
    public let home: URL
    public let applicationDirectories: [URL]
    public let volumesDirectory: URL
    public let userID: uid_t
    public let isRealSystem: Bool

    public init(home: URL,
                applicationDirectories: [URL],
                volumesDirectory: URL,
                userID: uid_t = getuid(),
                isRealSystem: Bool = false) {
        self.home = home
        self.applicationDirectories = applicationDirectories
        self.volumesDirectory = volumesDirectory
        self.userID = userID
        self.isRealSystem = isRealSystem
    }

    public static var current: CleanEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CleanEnvironment(
            home: home,
            applicationDirectories: [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")],
            volumesDirectory: URL(fileURLWithPath: "/Volumes"),
            isRealSystem: true
        )
    }

    public func path(_ relative: String) -> URL {
        home.appendingPathComponent(relative)
    }

    public var library: URL { path("Library") }
    public var trash: URL { path(".Trash") }
    public var logsDirectory: URL { path("Library/Logs/\(Product.name)") }
    public var journalFile: URL { logsDirectory.appendingPathComponent("journal.jsonl") }
}

public enum FullDiskAccess {
    /// Folders macOS only lists with Full Disk Access. The user TCC database is gone on macOS 27,
    /// so its presence cannot be the test any more.
    public static func isGranted(in environment: CleanEnvironment = .current) -> Bool {
        for relative in [".Trash", "Library/Safari", "Library/Mail"] {
            let url = environment.path(relative)
            guard FileSizer.exists(url) else { continue }
            if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil { return true }
        }
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
