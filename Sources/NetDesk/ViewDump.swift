import AppKit
import CleanCore

/// Diagnostic: with NETDESK_DUMP_VIEWS=<file>, visits every module and writes the size of the main
/// containers, to catch a layout that overflows the window. It reads only.
@MainActor
enum ViewDump {
    static func run(_ app: AppState) async {
        guard let path = ProcessInfo.processInfo.environment["NETDESK_DUMP_VIEWS"] else { return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out = "bundle=\(Bundle.main.bundlePath) fullDiskAccess=\(FullDiskAccess.isGranted())\n"
        for probe in [".Trash", "Library/Safari", "Library/Mail", "Library/Application Support/com.apple.TCC"] {
            let listed = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(probe).path)) != nil
            out += "probe \(probe) listable=\(listed)\n"
        }
        for module in Module.allCases {
            app.selection = module
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
                  let root = window.contentView else { continue }
            var findings: [String] = []
            func visit(_ view: NSView) {
                let name = "\(type(of: view))"
                if name.contains("NavigationSplitRepresentable") || name.contains("SplitViewItemViewWrapper") {
                    findings.append("\(name.prefix(40)) \(view.frame.integral)")
                }
                view.subviews.forEach(visit)
            }
            visit(root)
            out += "\(module.rawValue) window=\(window.frame.size) " + findings.joined(separator: " | ") + "\n"
        }
        try? out.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
