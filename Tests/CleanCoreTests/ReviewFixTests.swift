import Foundation
import SQLite3
import Testing
@testable import CleanCore

/// One test per fix from the safety review of 29/10.
@Suite struct ReviewFixTests {
    @Test func vitalFoldersAreExcluded() throws {
        let box = try Sandbox()
        for relative in ["Library/Keychains/login.keychain-db", ".ssh/id_ed25519", ".gnupg/key", ".local/bin/tool",
                         "Library/Application Support/Syncthing/config.xml", "Library/Logs/NetDesk/journal.jsonl",
                         "Library/Application Support/Google/DriveFS/pending"] {
            let url = try box.file(relative)
            #expect(!box.policy.verdict(for: url).isAllowed, "\(relative) devrait être refusé")
        }
        for path in ["/opt/homebrew/bin", "/Library/Preferences", "/private/etc/hosts", "/private/var/folders"] where FileManager.default.fileExists(atPath: path) {
            #expect(!box.policy.verdict(for: URL(fileURLWithPath: path)).isAllowed, "\(path) devrait être refusé")
        }
    }

    @Test func spaceLensOnlyTrashesUserFiles() throws {
        let box = try Sandbox()
        let env = box.environment
        let film = try box.file("Movies/film.mov")
        let support = try box.file("Library/Application Support/x")
        let config = try box.folder(".config")
        let app = try box.folder("Applications/Outil.app")
        #expect(SpaceScanner.selectionBlock(for: film, environment: env) == nil)
        #expect(SpaceScanner.selectionBlock(for: support, environment: env) != nil)
        #expect(SpaceScanner.selectionBlock(for: config, environment: env) != nil)
        #expect(SpaceScanner.selectionBlock(for: app, environment: env) != nil)
        #expect(SpaceScanner.selectionBlock(for: URL(fileURLWithPath: "/Applications/Safari.app"), environment: env) != nil)
    }

    func makeApp(_ box: Sandbox, name: String, bundleID: String) throws {
        let info = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        try box.file("Applications/\(name).app/Contents/Info.plist",
                     data: try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
    }

    @Test func openAppKeepsItsFiles() throws {
        let box = try Sandbox()
        try makeApp(box, name: "Messagerie", bundleID: "com.fakevendor.Messagerie")
        try box.file("Library/Group Containers/ABCDE12345.com.fakevendor.Messagerie/chats.db")
        try box.file("Library/Preferences/com.fakevendor.Messagerie.plist")
        let scanner = ApplicationScanner(context: box.context(running: ["com.fakevendor.Messagerie"]), knownBundleID: { _ in false })
        let app = try #require(scanner.installedApps().first)
        let items = scanner.uninstallItems(for: app)
        #expect(items.count == 3)
        #expect(items.allSatisfy { !$0.isSelectable })
    }

    @Test func siblingAppWithLongerIDIsLeftAlone() throws {
        let box = try Sandbox()
        try makeApp(box, name: "Navigateur", bundleID: "com.fakevendor.Navigateur")
        try makeApp(box, name: "Navigateur Beta", bundleID: "com.fakevendor.Navigateur.beta")
        try box.file("Library/Preferences/com.fakevendor.Navigateur.plist")
        try box.file("Library/Preferences/com.fakevendor.Navigateur.beta.plist")
        let scanner = ApplicationScanner(context: box.context(), knownBundleID: { _ in false })
        let apps = scanner.installedApps()
        let stable = try #require(apps.first { $0.bundleID == "com.fakevendor.Navigateur" })
        let titles = scanner.uninstallItems(for: stable, installed: apps).map(\.title)
        #expect(titles.contains("com.fakevendor.Navigateur.plist"))
        #expect(!titles.contains("com.fakevendor.Navigateur.beta.plist"))
    }

    @Test func executorRechecksOpenAppsAtRunTime() throws {
        let box = try Sandbox()
        let file = try box.file("Library/Caches/com.fakevendor.app/data")
        let item = CleanItem(url: file, size: 1, selectedByDefault: true).requiring("com.fakevendor.app")
        let executor = CleanupExecutor(environment: box.environment, policy: box.policy, trash: box.fakeTrash, journal: box.journal,
                                       runner: RecordingRunner(), isRunning: { $0 == "com.fakevendor.app" })
        let report = executor.perform([item], module: "test")
        #expect(report.failed.count == 1)
        #expect(box.exists("Library/Caches/com.fakevendor.app/data"))
    }

    @Test func serviceIsNotStoppedWhenItsPlistIsProtected() throws {
        let box = try Sandbox()
        let plist = try box.file("Synced/agent.plist")
        let runner = RecordingRunner()
        let item = CleanItem(url: plist, size: 1, action: .unloadAndTrash(label: "com.example.agent"), selectedByDefault: true)
        let report = box.executor(runner: runner).perform([item], module: "test")
        #expect(report.failed.count == 1)
        #expect(runner.calls.isEmpty)
    }

    @Test func groupCheckboxSkipsSensitiveRows() {
        let plain = CleanItem(id: "a", urls: [], size: 0, action: .revokePermission(service: "Camera", client: "x"), selectedByDefault: false)
        let group = CleanGroup(id: "g", title: "g", explanation: "", symbol: "", items: [plain, plain.sensitive().withID("b")])
        #expect(group.bulkSelectableItems.map(\.id) == ["a"])
    }

    @Test func personallyProtectedAppsKeepTheirPermissions() throws {
        let box = try Sandbox()
        let folder = try box.folder("Library/Application Support/com.apple.TCC")
        var db: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent("TCC.db").path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER); INSERT INTO access VALUES ('kTCCServiceAccessibility','com.example.dictation',2),('kTCCServiceAccessibility','com.example.terminal',2),('kTCCServiceCamera','com.example.visio',2);", nil, nil, nil)
        sqlite3_close(db)
        let permissions = try #require(PrivacyScanner(context: box.context()).scan().first { $0.id == "permissions" })
        let locked = permissions.items.filter { !$0.isSelectable }.map(\.subtitle)
        #expect(Set(locked) == ["com.example.dictation", "com.example.terminal"])
        #expect(permissions.items.allSatisfy { $0.isSensitive })
    }
}

extension CleanItem {
    func withID(_ id: String) -> CleanItem {
        var copy = CleanItem(id: id, urls: urls, title: title, subtitle: subtitle, size: size, action: action, selectedByDefault: selectedByDefault)
        if isSensitive { copy = copy.sensitive() }
        return copy
    }
}
