import Foundation

public enum ItemAction: Hashable, Sendable {
    /// Move every URL of the item to the Trash.
    case trash
    /// Stop a user launch agent, then move its plist to the Trash.
    case unloadAndTrash(label: String)
    /// `tccutil reset <service> <client>`.
    case revokePermission(service: String, client: String)
    /// Remove an "open at login" item through System Events.
    case removeLoginItem(name: String)
    /// Permanent deletion, only for items already in a Trash folder.
    case deletePermanently
    /// Informational row, nothing to run.
    case none
}

public struct CleanItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let urls: [URL]
    public let title: String
    public let subtitle: String?
    public let size: Int64
    public let date: Date?
    public let action: ItemAction
    public internal(set) var selectedByDefault: Bool
    public internal(set) var blockedReason: String?
    public let warning: String?
    /// Must be ticked one by one: the group checkbox skips it.
    public internal(set) var isSensitive = false
    /// Bundle ID of an app that must be closed at the moment the action runs.
    public internal(set) var requiresClosed: String?

    public var url: URL? { urls.first }
    public var isSelectable: Bool { blockedReason == nil && action != .none }

    public init(id: String? = nil,
                urls: [URL],
                title: String? = nil,
                subtitle: String? = nil,
                size: Int64,
                date: Date? = nil,
                action: ItemAction = .trash,
                selectedByDefault: Bool,
                blockedReason: String? = nil,
                warning: String? = nil) {
        self.id = id ?? urls.map(\.path).joined(separator: "|")
        self.urls = urls
        self.title = title ?? urls.first?.lastPathComponent ?? "?"
        self.subtitle = subtitle
        self.size = size
        self.date = date
        self.action = action
        self.selectedByDefault = selectedByDefault
        self.blockedReason = blockedReason
        self.warning = warning
    }

    public init(url: URL,
                title: String? = nil,
                subtitle: String? = nil,
                size: Int64,
                date: Date? = nil,
                action: ItemAction = .trash,
                selectedByDefault: Bool,
                blockedReason: String? = nil,
                warning: String? = nil) {
        self.init(urls: [url], title: title, subtitle: subtitle, size: size, date: date, action: action,
                  selectedByDefault: selectedByDefault, blockedReason: blockedReason, warning: warning)
    }

    public func blocked(_ reason: String?) -> CleanItem {
        guard let reason else { return self }
        var copy = self
        copy.selectedByDefault = false
        copy.blockedReason = copy.blockedReason ?? reason
        return copy
    }

    public func sensitive() -> CleanItem {
        var copy = self
        copy.isSensitive = true
        return copy
    }

    public func requiring(_ bundleID: String?) -> CleanItem {
        var copy = self
        copy.requiresClosed = bundleID
        return copy
    }
}

public struct CleanGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let explanation: String
    public let symbol: String
    public var items: [CleanItem]
    public var notice: String?

    public init(id: String, title: String, explanation: String, symbol: String, items: [CleanItem], notice: String? = nil) {
        self.id = id
        self.title = title
        self.explanation = explanation
        self.symbol = symbol
        self.items = items
        self.notice = notice
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    /// What the group checkbox ticks: sensitive rows (permissions, passwords, backups) stay out.
    public var bulkSelectableItems: [CleanItem] { items.filter { $0.isSelectable && !$0.isSensitive } }
}

extension SafetyPolicy {
    /// Blocks every item the policy refuses, so the list shows a lock instead of a checkbox.
    public func annotate(_ item: CleanItem) -> CleanItem {
        switch item.action {
        case .trash, .unloadAndTrash, .deletePermanently:
            for url in item.urls {
                if case .denied(let reason) = verdict(for: url) {
                    return item.blocked(reason)
                }
            }
            return item
        default:
            return item
        }
    }

    public func annotate(_ items: [CleanItem]) -> [CleanItem] {
        items.map(annotate)
    }
}

public enum Format {
    public static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: value)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    public static func date(_ date: Date?) -> String {
        guard let date else { return "date inconnue" }
        return dateFormatter.string(from: date)
    }
}
