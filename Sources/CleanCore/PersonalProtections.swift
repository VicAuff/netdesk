import Foundation

/// Machine-specific protections, kept out of the code and of the repository:
/// `~/Library/Application Support/NetDesk/protections.json`.
///
///     { "folders": ["~/Sync", "~/.private"], "apps": ["com.example.dictation"] }
///
/// `folders` are excluded like the built-in ones. `apps` are bundle ID prefixes never reported
/// as leftovers and whose permissions cannot be revoked.
public struct PersonalProtections: Codable, Sendable {
    public var folders: [String]
    public var apps: [String]

    public init(folders: [String] = [], apps: [String] = []) {
        self.folders = folders
        self.apps = apps
    }

    public static func file(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/\(Product.name)/protections.json")
    }

    /// Read from the real home folder, so a test with a fake home still protects this Mac.
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> PersonalProtections {
        guard let data = try? Data(contentsOf: file(home: home)),
              let decoded = try? JSONDecoder().decode(PersonalProtections.self, from: data) else { return PersonalProtections() }
        return decoded
    }

    /// "~/X" becomes X relative to the given home; absolute paths stay as they are.
    func paths(relativeTo home: URL) -> [String] {
        folders.map { folder in
            if folder == "~" { return home.path }
            if folder.hasPrefix("~/") { return home.appendingPathComponent(String(folder.dropFirst(2))).path }
            return folder
        }
    }
}
