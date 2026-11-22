import Foundation
import Observation

/// Diagnostic severity level for an `EngineEvent`.
public enum EventSeverity: String, CaseIterable, Sendable, Comparable, Identifiable {
    case info
    case warning
    case error

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .info:
            String(localized: "Info", bundle: .interceptorEngine)
        case .warning:
            String(localized: "Warning", bundle: .interceptorEngine)
        case .error:
            String(localized: "Error", bundle: .interceptorEngine)
        }
    }

    /// Deterministic non-localized uppercase tag used in plain-text log exports.
    fileprivate var exportLabel: String {
        rawValue.uppercased()
    }

    private var sortRank: Int {
        switch self {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    public static func < (lhs: EventSeverity, rhs: EventSeverity) -> Bool {
        lhs.sortRank < rhs.sortRank
    }
}

/// Functional subsystem category for an `EngineEvent`.
public enum EventCategory: String, CaseIterable, Sendable, Identifiable {
    case audio
    case device
    case clock
    case permission
    case system
    case update

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .audio:
            String(localized: "Audio", bundle: .interceptorEngine)
        case .device:
            String(localized: "Device", bundle: .interceptorEngine)
        case .clock:
            String(localized: "Clock", bundle: .interceptorEngine)
        case .permission:
            String(localized: "Permission", bundle: .interceptorEngine)
        case .system:
            String(localized: "System", bundle: .interceptorEngine)
        case .update:
            String(localized: "Update", bundle: .interceptorEngine)
        }
    }

    /// Deterministic non-localized label used in plain-text log exports.
    fileprivate var exportLabel: String {
        switch self {
        case .audio: "Audio"
        case .device: "Device"
        case .clock: "Clock"
        case .permission: "Permission"
        case .system: "System"
        case .update: "Update"
        }
    }
}

/// Immutable diagnostic event entry captured during an Interceptor session.
public struct EngineEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let severity: EventSeverity
    public let category: EventCategory
    public let bridgeID: UUID?
    public let sourceName: String
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        severity: EventSeverity,
        category: EventCategory,
        bridgeID: UUID? = nil,
        sourceName: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.bridgeID = bridgeID
        self.sourceName = sourceName
        self.message = message
    }
}

/// Session-only rolling in-memory store of diagnostic events with unread problem tracking.
@MainActor
@Observable
public final class EventLog {
    /// Maximum number of entries retained in memory (clamped to at least 1).
    public let maxEntries: Int

    /// Recorded events ordered newest first.
    public private(set) var entries: [EngineEvent] = []

    /// Number of unread warning events recorded while the Events window is not visible.
    public private(set) var unreadWarningCount: Int = 0

    /// Number of unread error events recorded while the Events window is not visible.
    public private(set) var unreadErrorCount: Int = 0

    /// Combined unread warning and error count for toolbar and Menu Bar badges.
    public var totalUnreadProblemCount: Int {
        unreadWarningCount + unreadErrorCount
    }

    /// Highest severity among unread problems (`.error` takes precedence over `.warning`).
    public var highestUnreadSeverity: EventSeverity? {
        if unreadErrorCount > 0 {
            return .error
        }
        if unreadWarningCount > 0 {
            return .warning
        }
        return nil
    }

    /// Tracks whether the Events window is currently visible; opening it clears unread problem counts.
    public var isEventsWindowVisible: Bool = false {
        didSet {
            if isEventsWindowVisible {
                markAllRead()
            }
        }
    }

    public init(maxEntries: Int = 1_000) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Appends a new diagnostic event at the head of the log, evicting oldest entries beyond `maxEntries`.
    public func record(
        severity: EventSeverity,
        category: EventCategory,
        bridgeID: UUID? = nil,
        sourceName: String,
        message: String,
        timestamp: Date = Date()
    ) {
        let event = EngineEvent(
            timestamp: timestamp,
            severity: severity,
            category: category,
            bridgeID: bridgeID,
            sourceName: sourceName,
            message: message
        )
        entries.insert(event, at: 0)

        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }

        guard !isEventsWindowVisible else { return }

        switch severity {
        case .info:
            break
        case .warning:
            unreadWarningCount += 1
        case .error:
            unreadErrorCount += 1
        }
    }

    /// Resets unread warning and error counters without removing entries.
    public func markAllRead() {
        unreadWarningCount = 0
        unreadErrorCount = 0
    }

    /// Clears all recorded events and resets unread problem counters.
    public func clear() {
        entries.removeAll()
        markAllRead()
    }

    /// Formats events chronologically (oldest to newest) as single-line log records for copy or `.log` export.
    public static func exportText(for events: [EngineEvent]) -> String {
        guard !events.isEmpty else { return "" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        // Reverse first so events supplied in newest-first store order preserve insertion order on equal timestamps.
        let chronological = events.reversed().sorted { $0.timestamp < $1.timestamp }

        return chronological.map { event in
            let timestamp = formatter.string(from: event.timestamp)
            let source = sanitizeSingleLine(event.sourceName)
            let message = sanitizeSingleLine(event.message)
            return "[\(timestamp)] [\(event.severity.exportLabel)] [\(event.category.exportLabel)] [\(source)] \(message)"
        }
        .joined(separator: "\n")
    }

    private static func sanitizeSingleLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
