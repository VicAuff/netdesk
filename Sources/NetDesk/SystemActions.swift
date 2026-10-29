import AppKit
import CleanCore

private final class Box<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Bridges to AppKit and System Events, kept out of CleanCore so the core stays testable.
enum SystemActions {
    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Fallback for app bundles FileManager cannot move (apps owned by the system, from the App Store):
    /// Finder moves them and asks for the password itself, as when dragging them to the Trash.
    static let recycler: @Sendable (URL) -> Result<URL?, Error> = { url in
        guard url.pathExtension == "app" else {
            return .failure(NSError(domain: Product.name, code: 2, userInfo: [NSLocalizedDescriptionKey: "Seules les apps passent par le Finder."]))
        }
        let result = Box<Result<URL?, Error>>(.success(nil))
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? [])
        DispatchQueue.main.sync {
            let path = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = NSAppleScript(source: "tell application \"Finder\" to delete (POSIX file \"\(path)\")")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Le Finder a refusé"
                result.value = .failure(NSError(domain: Product.name, code: 3, userInfo: [NSLocalizedDescriptionKey: message]))
            } else {
                // Finder renames on a name clash: find the new entry instead of guessing, so "put back" restores the right item.
                let added = Set((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).subtracting(before)
                let base = url.deletingPathExtension().lastPathComponent
                result.value = .success(added.first { $0.hasPrefix(base) }.map { trash.appendingPathComponent($0) })
            }
        }
        return result.value
    }

    static let removeLoginItem: @Sendable (String) -> Result<Void, Error> = { name in
        let result = Box<Result<Void, Error>>(.success(()))
        DispatchQueue.main.sync {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let script = NSAppleScript(source: "tell application \"System Events\" to delete login item \"\(escaped)\"")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "System Events a refusé"
                result.value = .failure(NSError(domain: Product.name, code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "\(message). Désactive-le dans Réglages Système > Général > Ouverture.",
                ]))
            }
        }
        return result.value
    }

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func openFullDiskAccessSettings() {
        open(FullDiskAccess.settingsURL)
    }

    static func openLoginItemsSettings() {
        open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
    }

    static func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}
