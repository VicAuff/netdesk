import CleanCore
import Foundation
import Observation

/// State of one scan-and-clean list: results, ticked items, last report.
@MainActor
@Observable
final class ScanModel: Identifiable {
    enum Phase: Equatable { case idle, scanning, ready, working }

    let id: String
    let moduleName: String
    private let scanner: @Sendable (ScanContext) -> [CleanGroup]

    var phase: Phase = .idle
    var groups: [CleanGroup] = []
    var selection: Set<String> = []
    var collapsed: Set<String> = []
    var scannedAt: Date?
    var lastReport: CleanupReport?

    init(id: String, moduleName: String, scanner: @escaping @Sendable (ScanContext) -> [CleanGroup]) {
        self.id = id
        self.moduleName = moduleName
        self.scanner = scanner
    }

    var allItems: [CleanItem] { groups.flatMap(\.items) }
    var selectedItems: [CleanItem] { allItems.filter { selection.contains($0.id) && $0.isSelectable } }
    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var totalSize: Int64 { groups.reduce(0) { $0 + $1.totalSize } }
    var hasResults: Bool { scannedAt != nil }

    func scan(_ context: ScanContext) async {
        guard phase != .scanning && phase != .working else { return }
        phase = .scanning
        let scanner = self.scanner
        let result = await Task.detached(priority: .userInitiated) { scanner(context) }.value
        groups = result
        selection = Set(result.flatMap(\.items).filter { $0.selectedByDefault && $0.isSelectable }.map(\.id))
        collapsed = Set(result.filter { $0.items.count > 12 }.map(\.id))
        scannedAt = Date()
        phase = .ready
    }

    func perform(with executor: CleanupExecutor, items: [CleanItem]? = nil) async -> CleanupReport {
        phase = .working
        let toRun = items ?? selectedItems
        let moduleName = self.moduleName
        let report = await Task.detached(priority: .userInitiated) { executor.perform(toRun, module: moduleName) }.value
        let done = Set(report.succeeded.map(\.item.id))
        groups = groups.map { group in
            var group = group
            group.items.removeAll { done.contains($0.id) }
            return group
        }
        selection.subtract(done)
        lastReport = report
        phase = .ready
        return report
    }

    // MARK: - Selection

    func isSelected(_ item: CleanItem) -> Bool { selection.contains(item.id) }

    func toggle(_ item: CleanItem) {
        guard item.isSelectable else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    enum GroupState { case none, some, all }

    /// The group checkbox only covers non-sensitive rows; permissions, passwords and backups are ticked one by one.
    func state(of group: CleanGroup) -> GroupState {
        let selectable = group.bulkSelectableItems
        let count = selectable.filter { selection.contains($0.id) }.count
        if count == 0 { return .none }
        return count == selectable.count ? .all : .some
    }

    func toggle(_ group: CleanGroup) {
        let ids = group.bulkSelectableItems.map(\.id)
        if state(of: group) == .all { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    func selectedSize(in group: CleanGroup) -> Int64 {
        group.items.filter { selection.contains($0.id) && $0.isSelectable }.reduce(0) { $0 + $1.size }
    }
}
