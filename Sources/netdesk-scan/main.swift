import CleanCore
import Foundation

// Read-only check of the scanners. It never moves or deletes anything.
// Usage: netdesk-scan <module> [--home <fake home>]
// Modules: junk, trash, large, duplicates, downloads, installers, apps, orphans, privacy, performance, space, monitor

var arguments = Array(CommandLine.arguments.dropFirst())
var environment = CleanEnvironment.current
if let index = arguments.firstIndex(of: "--home"), index + 1 < arguments.count {
    let home = URL(fileURLWithPath: arguments[index + 1])
    environment = CleanEnvironment(home: home, applicationDirectories: [home.appendingPathComponent("Applications")],
                                   volumesDirectory: home.appendingPathComponent("Volumes"))
    arguments.removeSubrange(index...index + 1)
}
let module = arguments.first ?? "junk"
let context = ScanContext(environment: environment, policy: SafetyPolicy(environment: environment))

func show(_ groups: [CleanGroup]) {
    var total: Int64 = 0
    var selected: Int64 = 0
    for group in groups {
        print("== \(group.title) : \(group.items.count) éléments, \(Format.bytes(group.totalSize))")
        if let notice = group.notice { print("   ! \(notice)") }
        for item in group.items.prefix(12) {
            let mark = item.blockedReason != nil ? "[bloqué]" : (item.selectedByDefault ? "[x]" : "[ ]")
            let reason = item.blockedReason.map { " (\($0))" } ?? ""
            print("   \(mark) \(item.title) · \(Format.bytes(item.size))\(reason)")
        }
        if group.items.count > 12 { print("   ... \(group.items.count - 12) autres") }
        total += group.totalSize
        selected += group.items.filter { $0.selectedByDefault && $0.blockedReason == nil }.reduce(0) { $0 + $1.size }
    }
    print("Total : \(Format.bytes(total)), coché par défaut : \(Format.bytes(selected))")
}

let start = Date()
switch module {
case "junk": show(JunkScanner(context: context).scan())
case "trash": show(TrashBinScanner(context: context).scan())
case "large": show(LargeFileScanner(context: context).scan())
case "duplicates": show(DuplicateScanner(context: context).scan())
case "downloads": show(DownloadsScanner(context: context).scan())
case "installers": show(InstallerScanner(context: context, mountedImages: InstallerScanner.currentlyMountedImages()).scan())
case "apps":
    let scanner = ApplicationScanner(context: context)
    let apps = scanner.installedApps()
    for app in apps {
        let leftovers = scanner.leftovers(bundleID: app.bundleID, name: app.name)
        let used = app.lastUsed.map(Format.date) ?? "jamais (Spotlight)"
        print("\(app.name) · \(Format.bytes(app.size)) · ouverte : \(used) · restes : \(leftovers.count) (\(Format.bytes(leftovers.reduce(0) { $0 + $1.size })))\(app.blockedReason.map { " [\($0)]" } ?? "")")
    }
    print("\(apps.count) apps, \(apps.filter { ApplicationScanner.isUnused($0) }.count) inutilisées depuis \(ApplicationScanner.unusedAfterDays) jours")
case "orphans":
    let scanner = ApplicationScanner(context: context)
    show(scanner.orphanLeftovers(installed: scanner.installedApps()))
case "privacy": show(PrivacyScanner(context: context).scan())
case "performance": show(PerformanceScanner(context: context).scan())
case "space":
    let root = arguments.count > 1 ? URL(fileURLWithPath: arguments[1]) : environment.home
    let node = SpaceScanner(context: context).scan(root)
    print("\(node.name) : \(Format.bytes(node.size))")
    for child in node.children.prefix(15) {
        print("   \(child.name) · \(Format.bytes(child.size))\(child.skippedReason.map { " (\($0))" } ?? "")\(child.isReadable ? "" : " (illisible)")")
    }
case "monitor":
    let monitor = SystemMonitor()
    _ = monitor.sample()
    Thread.sleep(forTimeInterval: 1)
    let s = monitor.sample()
    print("CPU \(Int(s.cpuUsage * 100)) %, mémoire \(Format.bytes(s.memoryUsed)) / \(Format.bytes(s.memoryTotal)), disque libre \(Format.bytes(s.diskAvailable)) / \(Format.bytes(s.diskTotal)), batterie \(s.batteryLevel.map { "\($0) %" } ?? "?")")
default:
    print("Module inconnu : \(module)")
    exit(1)
}
print(String(format: "(%.1f s)", Date().timeIntervalSince(start)))
