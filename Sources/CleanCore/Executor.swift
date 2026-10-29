import Foundation

public struct CleanupOutcome: Identifiable, Sendable {
    public let id = UUID()
    public let item: CleanItem
    public let success: Bool
    public let message: String?
}

public struct CleanupReport: Sendable {
    public let outcomes: [CleanupOutcome]

    public init(outcomes: [CleanupOutcome]) {
        self.outcomes = outcomes
    }

    public var succeeded: [CleanupOutcome] { outcomes.filter(\.success) }
    public var failed: [CleanupOutcome] { outcomes.filter { !$0.success } }
    public var processedSize: Int64 { succeeded.reduce(0) { $0 + $1.item.size } }
}

/// Runs the confirmed actions. Every URL goes through the safety policy again right before it is touched.
public struct CleanupExecutor: Sendable {
    public let environment: CleanEnvironment
    public let policy: SafetyPolicy
    public let trash: TrashPerforming
    public let journal: Journal
    public let runner: CommandRunning
    /// Fallback for items FileManager cannot move (apps owned by root): lets macOS ask for the password.
    public let recycler: (@Sendable (URL) -> Result<URL?, Error>)?
    public let loginItemRemover: (@Sendable (String) -> Result<Void, Error>)?
    /// Checked right before each action, since an app may have been opened after the scan.
    public let isRunning: (@Sendable (String) -> Bool)?

    public init(environment: CleanEnvironment,
                policy: SafetyPolicy,
                trash: TrashPerforming,
                journal: Journal,
                runner: CommandRunning = ProcessRunner(),
                recycler: (@Sendable (URL) -> Result<URL?, Error>)? = nil,
                loginItemRemover: (@Sendable (String) -> Result<Void, Error>)? = nil,
                isRunning: (@Sendable (String) -> Bool)? = nil) {
        self.environment = environment
        self.policy = policy
        self.trash = trash
        self.journal = journal
        self.runner = runner
        self.recycler = recycler
        self.loginItemRemover = loginItemRemover
        self.isRunning = isRunning
    }

    public func perform(_ items: [CleanItem], module: String) -> CleanupReport {
        CleanupReport(outcomes: items.map { perform($0, module: module) })
    }

    func perform(_ item: CleanItem, module: String) -> CleanupOutcome {
        if let reason = item.blockedReason {
            return CleanupOutcome(item: item, success: false, message: reason)
        }
        if let bundleID = item.requiresClosed, isRunning?(bundleID) == true {
            return CleanupOutcome(item: item, success: false, message: "L'app concernée est ouverte (\(bundleID)), ferme-la puis recommence")
        }
        switch item.action {
        case .none:
            return CleanupOutcome(item: item, success: false, message: "Aucune action")
        case .trash:
            return trashURLs(of: item, module: module)
        case .unloadAndTrash(let label):
            // The plist must pass the policy before the service is stopped.
            for url in item.urls {
                if case .denied(let reason) = policy.verdict(for: url) {
                    return CleanupOutcome(item: item, success: false, message: reason)
                }
            }
            let result = runner.run("/bin/launchctl", ["bootout", "gui/\(environment.userID)/\(label)"])
            // 3 and 113 mean the service was not loaded, which is fine before removing the plist.
            if result.status != 0 && result.status != 3 && result.status != 113 && !result.output.contains("Could not find") {
                return CleanupOutcome(item: item, success: false, message: "launchctl : \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return trashURLs(of: item, module: module)
        case .revokePermission(let service, let client):
            let result = runner.run("/usr/bin/tccutil", ["reset", service, client])
            guard result.status == 0 else {
                return CleanupOutcome(item: item, success: false, message: "tccutil : \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            journal.append(JournalEntry(module: module, kind: .revoked, title: item.title, originalPath: "\(service) \(client)", trashPath: nil, size: 0))
            return CleanupOutcome(item: item, success: true, message: nil)
        case .removeLoginItem(let name):
            guard let loginItemRemover else {
                return CleanupOutcome(item: item, success: false, message: "Indisponible ici")
            }
            switch loginItemRemover(name) {
            case .success:
                journal.append(JournalEntry(module: module, kind: .loginItemRemoved, title: name, originalPath: name, trashPath: nil, size: 0))
                return CleanupOutcome(item: item, success: true, message: nil)
            case .failure(let error):
                return CleanupOutcome(item: item, success: false, message: error.localizedDescription)
            }
        case .deletePermanently:
            return deletePermanently(item, module: module)
        }
    }

    private func trashURLs(of item: CleanItem, module: String) -> CleanupOutcome {
        var errors: [String] = []
        var moved = 0
        for url in item.urls {
            guard FileSizer.exists(url) else { continue }
            if case .denied(let reason) = policy.verdict(for: url) {
                errors.append("\(url.lastPathComponent) : \(reason)")
                continue
            }
            let size = FileSizer.allocatedSize(of: url)
            do {
                let destination = try trash.moveToTrash(url)
                record(url: url, destination: destination, size: size, item: item, module: module)
                moved += 1
            } catch {
                if let recycler, isPermissionError(error) {
                    switch recycler(url) {
                    case .success(let destination):
                        record(url: url, destination: destination, size: size, item: item, module: module)
                        moved += 1
                    case .failure(let fallbackError):
                        errors.append("\(url.lastPathComponent) : \(fallbackError.localizedDescription)")
                    }
                } else {
                    errors.append("\(url.lastPathComponent) : \(error.localizedDescription)")
                }
            }
        }
        if errors.isEmpty {
            return CleanupOutcome(item: item, success: true, message: moved == 0 ? "Déjà absent" : nil)
        }
        return CleanupOutcome(item: item, success: false, message: errors.joined(separator: "\n"))
    }

    private func record(url: URL, destination: URL?, size: Int64, item: CleanItem, module: String) {
        journal.append(JournalEntry(module: module, kind: .trashed, title: item.title, originalPath: url.path,
                                    trashPath: destination?.path, size: size))
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(EACCES) || underlying.code == Int(EPERM) {
            return true
        }
        return false
    }

    /// Only items sitting directly inside a Trash folder can be deleted for good.
    func trashFolders() -> [String] {
        var folders = [SafetyPolicy.canonicalPath(environment.trash.path)]
        if let volumes = FileSizer.children(of: environment.volumesDirectory) {
            for volume in volumes {
                folders.append(SafetyPolicy.canonicalPath(volume.appendingPathComponent(".Trashes/\(environment.userID)").path))
            }
        }
        return folders.map { $0.lowercased() }
    }

    private func deletePermanently(_ item: CleanItem, module: String) -> CleanupOutcome {
        let allowedParents = Set(trashFolders())
        var errors: [String] = []
        for url in item.urls {
            let path = SafetyPolicy.itemPath(url)
            let parent = (path as NSString).deletingLastPathComponent.lowercased()
            guard allowedParents.contains(parent) else {
                errors.append("\(url.lastPathComponent) : n'est pas dans une Corbeille")
                continue
            }
            if case .denied(let reason) = policy.verdict(for: url) {
                errors.append("\(url.lastPathComponent) : \(reason)")
                continue
            }
            let size = FileSizer.allocatedSize(of: url)
            do {
                try FileManager.default.removeItem(at: url)
                journal.append(JournalEntry(module: module, kind: .deleted, title: item.title, originalPath: url.path, trashPath: nil, size: size))
            } catch {
                errors.append("\(url.lastPathComponent) : \(error.localizedDescription)")
            }
        }
        return CleanupOutcome(item: item, success: errors.isEmpty, message: errors.isEmpty ? nil : errors.joined(separator: "\n"))
    }
}
