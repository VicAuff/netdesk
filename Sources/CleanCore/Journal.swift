import Foundation

public struct JournalEntry: Codable, Identifiable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case trashed, deleted, revoked, loginItemRemoved, restored
    }

    public let id: UUID
    public let date: Date
    public let module: String
    public let kind: Kind
    public let title: String
    public let originalPath: String
    public let trashPath: String?
    public let size: Int64
    /// For a `restored` entry: the entry it undid.
    public let reference: UUID?

    public init(module: String, kind: Kind, title: String, originalPath: String, trashPath: String?, size: Int64, reference: UUID? = nil) {
        self.id = UUID()
        self.date = Date()
        self.module = module
        self.kind = kind
        self.title = title
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.size = size
        self.reference = reference
    }
}

public enum JournalError: LocalizedError {
    case notInTrash, destinationExists, notRestorable

    public var errorDescription: String? {
        switch self {
        case .notInTrash: return "L'élément n'est plus dans la Corbeille."
        case .destinationExists: return "Un élément porte déjà ce nom à l'emplacement d'origine."
        case .notRestorable: return "Cette action ne se remet pas en place."
        }
    }
}

/// Append-only log of every action, one JSON object per line.
public final class Journal: @unchecked Sendable {
    public let file: URL
    private let lock = NSLock()

    public init(file: URL) {
        self.file = file
    }

    public func append(_ entry: JournalEntry) {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: file)
        }
    }

    /// Newest first.
    public func entries() -> [JournalEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(JournalEntry.self, from: Data($0.utf8)) }.reversed()
    }

    public func restoredIDs() -> Set<UUID> {
        Set(entries().compactMap { $0.kind == .restored ? $0.reference : nil })
    }

    public func canRestore(_ entry: JournalEntry) -> Bool {
        guard entry.kind == .trashed, let trashPath = entry.trashPath else { return false }
        return FileSizer.exists(URL(fileURLWithPath: trashPath)) && !FileSizer.exists(URL(fileURLWithPath: entry.originalPath))
    }

    /// Moves an item back from the Trash to where it was.
    public func restore(_ entry: JournalEntry) throws {
        guard entry.kind == .trashed, let trashPath = entry.trashPath else { throw JournalError.notRestorable }
        let source = URL(fileURLWithPath: trashPath)
        let destination = URL(fileURLWithPath: entry.originalPath)
        guard FileSizer.exists(source) else { throw JournalError.notInTrash }
        guard !FileSizer.exists(destination) else { throw JournalError.destinationExists }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        append(JournalEntry(module: entry.module, kind: .restored, title: entry.title, originalPath: entry.originalPath,
                            trashPath: trashPath, size: entry.size, reference: entry.id))
    }
}
