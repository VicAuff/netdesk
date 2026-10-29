import Foundation
@testable import CleanCore

/// A fake home folder. Tests run with NETDESK_TEST_ROOT pointing at the scratchpad, never at the real home.
struct Sandbox {
    let root: URL
    let home: URL

    init() throws {
        let base = ProcessInfo.processInfo.environment["NETDESK_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/private/tmp") // /private/var is excluded by the policy
        root = base.appendingPathComponent("netdesk-tests/\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    var environment: CleanEnvironment {
        CleanEnvironment(home: home, applicationDirectories: [home.appendingPathComponent("Applications")],
                         volumesDirectory: root.appendingPathComponent("Volumes"))
    }

    /// A fixed, fictitious personal configuration, so the tests do not depend on the machine.
    static let personal = PersonalProtections(folders: ["~/Synced", "~/.private"], apps: ["com.example.dictation", "com.example.terminal"])

    var policy: SafetyPolicy { SafetyPolicy(environment: environment, personal: Sandbox.personal) }

    func context(running: Set<String> = []) -> ScanContext {
        ScanContext(environment: environment, policy: policy, runningBundleIDs: running)
    }

    var fakeTrash: FolderTrash { FolderTrash(folder: root.appendingPathComponent("FakeTrash")) }
    var journal: Journal { Journal(file: environment.journalFile) }

    func executor(runner: CommandRunning = RecordingRunner()) -> CleanupExecutor {
        CleanupExecutor(environment: environment, policy: policy, trash: fakeTrash, journal: journal, runner: runner)
    }

    @discardableResult
    func file(_ relative: String, size: Int = 10_000, seed: UInt8 = 7, data: Data? = nil) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = data ?? Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) &+ seed })
        try bytes.write(to: url)
        return url
    }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func exists(_ relative: String) -> Bool {
        FileSizer.exists(home.appendingPathComponent(relative))
    }
}

final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    let status: Int32

    init(status: Int32 = 0) {
        self.status = status
    }

    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        lock.lock()
        calls.append([executable] + arguments)
        lock.unlock()
        return (status, "")
    }
}
