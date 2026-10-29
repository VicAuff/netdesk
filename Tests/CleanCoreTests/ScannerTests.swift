import Foundation
import SQLite3
import Testing
@testable import CleanCore

@Suite struct ScannerTests {
    @Test func junkFindsCachesLogsAndBrokenPreferences() throws {
        let box = try Sandbox()
        try box.file("Library/Caches/com.example.editor/data.bin", size: 50_000)
        try box.file("Library/Caches/ms-playwright/chromium/bin", size: 50_000)
        try box.file("Library/Caches/com.example.running/data.bin", size: 50_000)
        try box.file("Library/Caches/com.apple.bird/sync.db", size: 50_000)
        try box.file("Library/Logs/DiagnosticReports/crash.ips", size: 20_000)
        try box.file("Library/Preferences/com.example.broken.plist", data: Data("pas un plist".utf8))
        try box.file("Library/Preferences/com.example.ok.plist",
                     data: try PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0))
        try box.file(".ollama/models/blobs/model", size: 30_000)
        try box.file("Library/Caches/pw-profile/Local State", size: 2_000)
        try box.file("Library/Caches/com.apple.someservice/data", size: 20_000)
        try box.file("Library/Caches/Google/Chrome/Default/Cache/data", size: 20_000)

        let groups = JunkScanner(context: box.context(running: ["com.example.running", "com.google.Chrome"])).scan()
        let caches = try #require(groups.first { $0.id == "caches" })
        let byName = Dictionary(uniqueKeysWithValues: caches.items.map { ($0.title, $0) })
        #expect(byName["com.example.editor"]?.selectedByDefault == true)
        #expect(byName["ms-playwright"]?.selectedByDefault == false)
        #expect(byName["com.example.running"]?.selectedByDefault == false)
        #expect(byName["com.apple.bird"] == nil)
        #expect(byName["pw-profile"]?.selectedByDefault == false)
        #expect(byName["com.apple.someservice"]?.selectedByDefault == false)
        #expect(byName["com.example.editor"]?.requiresClosed == "com.example.editor")
        #expect(groups.first { $0.id == "logs" }?.items.count == 1)
        let prefs = try #require(groups.first { $0.id == "preferences" })
        #expect(prefs.items.map(\.title) == ["com.example.broken.plist"])
        #expect(groups.first { $0.id == "ai" }?.items.first?.selectedByDefault == false)
        #expect(byName["Google"]?.selectedByDefault == false)
    }

    @Test func trashBinsListAndEmpty() throws {
        let box = try Sandbox()
        try box.file(".Trash/a.txt")
        try box.file(".Trash/dossier/b.txt")
        let groups = TrashBinScanner(context: box.context()).scan()
        let home = try #require(groups.first)
        #expect(home.items.count == 2)
        #expect(home.items.allSatisfy { $0.action == .deletePermanently && $0.blockedReason == nil })
        let report = box.executor().perform(home.items, module: "test")
        #expect(report.failed.isEmpty)
        #expect(FileSizer.children(of: box.home.appendingPathComponent(".Trash"))?.isEmpty == true)
    }

    @Test func largeFilesSkipExclusionsAndLibrary() throws {
        let box = try Sandbox()
        try box.file("Movies/film.mov", size: 2_000_000)
        try box.file("Synced/gros.bin", size: 2_000_000)
        try box.file("Library/gros.bin", size: 2_000_000)
        try box.file("Documents/petit.txt", size: 1_000)
        let groups = LargeFileScanner(context: box.context(), minimumSize: 1_000_000).scan()
        let titles = groups.flatMap(\.items).map(\.title)
        #expect(titles == ["film.mov"])
        #expect(groups.flatMap(\.items).allSatisfy { !$0.selectedByDefault })
    }

    @Test func duplicatesKeepTheOldestCopy() throws {
        let box = try Sandbox()
        let original = try box.file("Documents/photo.jpg", size: 600_000, seed: 1)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: original.path)
        try box.file("Downloads/photo copie.jpg", size: 600_000, seed: 1)
        try box.file("Desktop/autre.jpg", size: 600_000, seed: 2)
        try box.file("Synced/photo.jpg", size: 600_000, seed: 1)
        let groups = DuplicateScanner(context: box.context()).scan()
        #expect(groups.count == 1)
        let items = try #require(groups.first?.items)
        #expect(items.count == 2)
        #expect(items[0].url?.lastPathComponent == "photo.jpg" && !items[0].selectedByDefault)
        #expect(items.allSatisfy { !$0.selectedByDefault })
    }

    @Test func downloadsGroupedBySource() throws {
        let box = try Sandbox()
        let fromSafari = try box.file("Downloads/facture.pdf")
        let quarantine = "0081;65000000;Safari;11111111-2222-3333-4444-555555555555"
        _ = quarantine.withCString { setxattr(fromSafari.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        try box.file("Downloads/note.txt")
        let groups = DownloadsScanner(context: box.context()).scan()
        #expect(Set(groups.map(\.title)) == ["Safari", "Autres"])
    }

    @Test func installersTickOldOnesOnly() throws {
        let box = try Sandbox()
        let old = try box.file("Downloads/Ancien.dmg")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: old.path)
        try box.file("Downloads/Recent.pkg")
        let mounted = try box.file("Downloads/Monte.dmg")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: mounted.path)
        let vault = try box.file("Downloads/Coffre.dmg")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -30 * 86_400)], ofItemAtPath: vault.path)
        let scanner = InstallerScanner(context: box.context(), mountedImages: [SafetyPolicy.canonicalPath(mounted.path)],
                                       isEncrypted: { $0.lastPathComponent == "Coffre.dmg" })
        let items = try #require(scanner.scan().first?.items)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0) })
        #expect(byName["Ancien.dmg"]?.selectedByDefault == true)
        #expect(byName["Recent.pkg"]?.selectedByDefault == false)
        #expect(byName["Monte.dmg"]?.blockedReason != nil)
        #expect(byName["Coffre.dmg"]?.selectedByDefault == false && byName["Coffre.dmg"]?.warning != nil)
    }

    func makeApp(_ box: Sandbox, name: String, bundleID: String) throws {
        let info = ["CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": "1.0", "CFBundlePackageType": "APPL"]
        try box.file("Applications/\(name).app/Contents/Info.plist",
                     data: try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0))
        try box.file("Applications/\(name).app/Contents/MacOS/\(name)", size: 40_000)
    }

    @Test func uninstallerFindsLeftovers() throws {
        let box = try Sandbox()
        try makeApp(box, name: "Outil", bundleID: "com.fakevendor.Outil")
        try box.file("Library/Application Support/com.fakevendor.Outil/db.sqlite")
        try box.file("Library/Preferences/com.fakevendor.Outil.plist")
        try box.file("Library/Caches/Outil/cache.bin")
        try box.file("Library/Application Support/AutreApp/x")
        let scanner = ApplicationScanner(context: box.context(), knownBundleID: { _ in false })
        let app = try #require(scanner.installedApps().first)
        #expect(app.bundleID == "com.fakevendor.Outil")
        let items = scanner.uninstallItems(for: app)
        let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.title + "|" + ($0.subtitle ?? ""), $0) })
        #expect(byTitle["Outil|Application"]?.selectedByDefault == true)
        #expect(byTitle["com.fakevendor.Outil|~/Library/Application Support"]?.selectedByDefault == true)
        #expect(byTitle["com.fakevendor.Outil.plist|~/Library/Preferences"]?.selectedByDefault == true)
        #expect(byTitle["Outil|~/Library/Caches"]?.selectedByDefault == false)
        #expect(items.count == 4)

        let report = box.executor().perform(items.filter(\.selectedByDefault), module: "test")
        #expect(report.failed.isEmpty)
        #expect(!box.exists("Applications/Outil.app"))
        #expect(box.exists("Library/Caches/Outil/cache.bin"))
    }

    @Test func runningAppIsBlocked() throws {
        let box = try Sandbox()
        try makeApp(box, name: "Ouverte", bundleID: "com.fakevendor.Ouverte")
        let scanner = ApplicationScanner(context: box.context(running: ["com.fakevendor.Ouverte"]), knownBundleID: { _ in false })
        let app = try #require(scanner.installedApps().first)
        #expect(app.blockedReason != nil)
        #expect(scanner.uninstallItems(for: app).first?.isSelectable == false)
    }

    @Test func orphansIgnoreInstalledVendorsAndApple() throws {
        let box = try Sandbox()
        try makeApp(box, name: "Outil", bundleID: "com.fakevendor.Outil")
        try box.file("Library/Caches/com.gonevendor.Ancien/cache.bin")
        try box.file("Library/Preferences/com.gonevendor.Ancien.plist")
        try box.file("Library/Preferences/com.fakevendor.Helper.plist")
        try box.file("Library/Preferences/com.apple.finder.plist")
        try box.file("Library/Group Containers/ABCDE12345.com.gonevendor.Ancien/x")
        let scanner = ApplicationScanner(context: box.context(), knownBundleID: { _ in false })
        let groups = scanner.orphanLeftovers(installed: scanner.installedApps())
        #expect(groups.map(\.title) == ["com.gonevendor.ancien"])
        #expect(groups.first?.items.count == 2)
        #expect(groups.first?.items.allSatisfy { !$0.selectedByDefault } == true)
    }

    @Test func privacyBrowserFilesAndPermissions() throws {
        let box = try Sandbox()
        let chrome = "Library/Application Support/Google/Chrome/Default/"
        try box.file(chrome + "Preferences")
        try box.file(chrome + "History", size: 30_000)
        try box.file(chrome + "Cookies", size: 5_000)
        try box.file(chrome + "Login Data", size: 5_000)

        let tccFolder = try box.folder("Library/Application Support/com.apple.TCC")
        var db: OpaquePointer?
        #expect(sqlite3_open(tccFolder.appendingPathComponent("TCC.db").path, &db) == SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER); INSERT INTO access VALUES ('kTCCServiceCamera','com.example.visio',2),('kTCCServiceMicrophone','com.example.refuse',0);", nil, nil, nil)
        sqlite3_close(db)

        let open = PrivacyScanner(context: box.context()).scan()
        let chromeGroup = try #require(open.first { $0.id == "com.google.Chrome" })
        #expect(Set(chromeGroup.items.map(\.title)) == ["Historique", "Cookies", "Mots de passe enregistrés"])
        #expect(chromeGroup.items.allSatisfy { $0.isSelectable && !$0.selectedByDefault })
        let permissions = try #require(open.first { $0.id == "permissions" })
        #expect(permissions.items.count == 1)
        #expect(permissions.items.first?.action == .revokePermission(service: "Camera", client: "com.example.visio"))

        let running = PrivacyScanner(context: box.context(running: ["com.google.Chrome"])).scan()
        #expect(running.first { $0.id == "com.google.Chrome" }?.items.allSatisfy { !$0.isSelectable } == true)

        let runner = RecordingRunner()
        let report = box.executor(runner: runner).perform(permissions.items, module: "test")
        #expect(report.failed.isEmpty)
        #expect(runner.calls == [["/usr/bin/tccutil", "reset", "Camera", "com.example.visio"]])
    }

    static let btmFixture = """
     Records for UID 0 : FFFFEEEE
     Items:
     #1:
                     Name: AgentSysteme
                     Type: legacy daemon (0x10010)
              Disposition: [enabled, allowed, notified] (0xb)
                      URL: /Library/LaunchDaemons/com.example.root.plist
     Records for UID 501 : 91BD3C4C
     Items:
     #1:
                     UUID: AA07
                     Name: (null)
                     Type: developer (0x20)
              Disposition: [disabled, allowed, not notified] (0x2)
     #2:
                     Name: syncthing
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.sh.brew.syncthing
                      URL: /Users/501/Library/LaunchAgents/sh.brew.syncthing.plist
     #3:
                     Name: Updater
           Developer Name: Example Inc.
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.com.example.updater
                      URL: /Users/501/Library/LaunchAgents/com.example.updater.plist
     #4:
                     Name: Canva
                     Type: app (0x2)
              Disposition: [disabled, allowed, not notified] (0x2)
                      URL: /Applications/Canva.app
     #5:
                     Name: Notes Pro
                     Type: app (0x2)
              Disposition: [enabled, allowed, notified] (0xb)
                      URL: /Applications/Notes Pro.app
    """

    @Test func backgroundItemsParsedAndSyncthingProtected() throws {
        let box = try Sandbox()
        let parsed = BTMParser.parse(Self.btmFixture, uid: 501)
        #expect(parsed.map(\.name) == ["syncthing", "Updater", "Canva", "Notes Pro"])
        #expect(parsed.first { $0.name == "Canva" }?.enabled == false)

        let environment = CleanEnvironment(home: box.home, applicationDirectories: [], volumesDirectory: box.root, userID: 501)
        let context = ScanContext(environment: environment, policy: SafetyPolicy(environment: environment, personal: Sandbox.personal))
        try box.file("Library/LaunchAgents/sh.brew.syncthing.plist",
                     data: try PropertyListSerialization.data(fromPropertyList: ["Label": "sh.brew.syncthing"], format: .xml, options: 0))
        try box.file("Library/LaunchAgents/com.example.updater.plist",
                     data: try PropertyListSerialization.data(fromPropertyList: ["Label": "com.example.updater"], format: .xml, options: 0))
        let groups = PerformanceScanner(context: context, runner: RecordingRunner()).scan(btmText: Self.btmFixture)
        let background = try #require(groups.first { $0.id == "background" })
        let syncthing = try #require(background.items.first { $0.title == "syncthing" })
        #expect(!syncthing.isSelectable)
        let updater = try #require(background.items.first { $0.title == "Updater" })
        #expect(updater.action == .unloadAndTrash(label: "com.example.updater"))
        #expect(background.items.count == 2)

        let login = try #require(groups.first { $0.id == "login" })
        #expect(login.items.first { $0.title == "Canva" }?.isSelectable == false)
        #expect(login.items.first { $0.title == "Notes Pro" }?.isSelectable == true)

        let runner = RecordingRunner()
        let executor = CleanupExecutor(environment: environment, policy: context.policy, trash: box.fakeTrash, journal: box.journal, runner: runner)
        let report = executor.perform([updater], module: "test")
        #expect(report.failed.isEmpty)
        #expect(runner.calls.first == ["/bin/launchctl", "bootout", "gui/501/com.example.updater"])
        #expect(!box.exists("Library/LaunchAgents/com.example.updater.plist"))
        #expect(box.exists("Library/LaunchAgents/sh.brew.syncthing.plist"))
    }

    @Test func spaceLensSumsAndSkipsCloud() throws {
        let box = try Sandbox()
        try box.file("Movies/a.mov", size: 2_000_000)
        try box.file("Documents/b.txt", size: 10_000)
        try box.file("Library/CloudStorage/GoogleDrive-x/c.bin", size: 2_000_000)
        let node = SpaceScanner(context: box.context()).scan(box.home)
        let movies = try #require(node.children.first { $0.name == "Movies" })
        #expect(movies.children.first?.name == "a.mov")
        let cloud = try #require(node.children.first { $0.name == "Library" }?.children.first { $0.name == "CloudStorage" })
        #expect(cloud.skippedReason != nil && cloud.size == 0)
        let before = node.size
        SpaceScanner.remove(movies)
        #expect(node.size == before - movies.size)
    }
}
