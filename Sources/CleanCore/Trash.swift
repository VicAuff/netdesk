import Foundation

public protocol TrashPerforming: Sendable {
    /// Returns where the item landed in the Trash.
    func moveToTrash(_ url: URL) throws -> URL?
}

/// The real Trash, through FileManager.trashItem.
public struct SystemTrash: TrashPerforming {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}

/// A stand-in Trash folder for tests: moves items there and never touches ~/.Trash.
public struct FolderTrash: TrashPerforming {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    public func moveToTrash(_ url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while FileSizer.exists(destination) {
            destination = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(counter)")
                .appendingPathExtension(url.pathExtension)
            counter += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String)
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
