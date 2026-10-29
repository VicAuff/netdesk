import Foundation
import Testing
@testable import CleanCore

@Suite struct SafetyTests {
    @Test func excludedFoldersAreRefused() throws {
        let box = try Sandbox()
        let policy = box.policy
        for relative in ["Synced/projet/a.txt", ".private/key", "Library/Mobile Documents/doc.pages",
                         "Library/CloudStorage/GoogleDrive-x/file.pdf"] {
            let url = try box.file(relative)
            #expect(!policy.verdict(for: url).isAllowed, "\(relative) devrait être refusé")
        }
        let normal = try box.file("Desktop/notes.txt")
        #expect(policy.verdict(for: normal).isAllowed)
    }

    @Test func realHomeExclusionsApplyEvenWithAFakeHome() throws {
        let box = try Sandbox()
        let realHome = FileManager.default.homeDirectoryForCurrentUser
        #expect(!box.policy.verdict(for: realHome.appendingPathComponent("Library/Keychains")).isAllowed)
        #expect(!box.policy.verdict(for: realHome.appendingPathComponent("Library/CloudStorage")).isAllowed)
    }

    @Test func symlinksCannotBypassExclusions() throws {
        let box = try Sandbox()
        try box.file("Synced/secret.txt")
        // A link to an excluded folder is refused...
        let link = box.home.appendingPathComponent("Desktop/raccourci")
        try box.folder("Desktop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: box.home.appendingPathComponent("Synced"))
        #expect(!box.policy.verdict(for: link).isAllowed)
        // ...and so is a path going through a linked parent folder.
        let through = link.appendingPathComponent("secret.txt")
        #expect(!box.policy.verdict(for: through).isAllowed)
    }

    @Test func baseFoldersAndSystemAreRefused() throws {
        let box = try Sandbox()
        try box.folder("Library/Caches")
        #expect(!box.policy.verdict(for: box.home).isAllowed)
        #expect(!box.policy.verdict(for: box.home.appendingPathComponent("Library")).isAllowed)
        #expect(!box.policy.verdict(for: box.home.appendingPathComponent("Library/Caches")).isAllowed)
        #expect(!box.policy.verdict(for: URL(fileURLWithPath: "/System/Library/CoreServices")).isAllowed)
        #expect(!box.policy.verdict(for: URL(fileURLWithPath: "/usr/bin/true")).isAllowed)
        #expect(!box.policy.verdict(for: URL(fileURLWithPath: "/Applications")).isAllowed)
    }

    @Test func trashJournalAndRestore() throws {
        let box = try Sandbox()
        let file = try box.file("Desktop/vieux.txt")
        let excluded = try box.file("Synced/garder.txt")
        let executor = box.executor()
        let report = executor.perform([
            CleanItem(url: file, size: 10_000, selectedByDefault: true),
            CleanItem(url: excluded, size: 10_000, selectedByDefault: true),
        ], module: "test")
        #expect(report.succeeded.count == 1)
        #expect(report.failed.count == 1)
        #expect(!box.exists("Desktop/vieux.txt"))
        #expect(box.exists("Synced/garder.txt"))
        #expect(FileSizer.exists(box.fakeTrash.folder.appendingPathComponent("vieux.txt")))

        let entry = try #require(box.journal.entries().first { $0.kind == .trashed })
        #expect(box.journal.canRestore(entry))
        try box.journal.restore(entry)
        #expect(box.exists("Desktop/vieux.txt"))
        #expect(box.journal.restoredIDs().contains(entry.id))
    }

    @Test func permanentDeletionOnlyInsideTrash() throws {
        let box = try Sandbox()
        let inTrash = try box.file(".Trash/ancien.zip")
        let outside = try box.file("Documents/important.pdf")
        let report = box.executor().perform([
            CleanItem(url: inTrash, size: 1, action: .deletePermanently, selectedByDefault: true),
            CleanItem(url: outside, size: 1, action: .deletePermanently, selectedByDefault: true),
        ], module: "test")
        #expect(!box.exists(".Trash/ancien.zip"))
        #expect(box.exists("Documents/important.pdf"))
        #expect(report.failed.first?.item.url == outside)
    }

    @Test func blockedItemsAreNeverRun() throws {
        let box = try Sandbox()
        let file = try box.file("Desktop/bloque.txt")
        let item = CleanItem(url: file, size: 1, selectedByDefault: true, blockedReason: "test")
        let report = box.executor().perform([item], module: "test")
        #expect(report.failed.count == 1)
        #expect(box.exists("Desktop/bloque.txt"))
    }
}
