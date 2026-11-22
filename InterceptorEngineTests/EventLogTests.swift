import Foundation
import InterceptorEngine
import Testing

@Suite("Event Log")
struct EventLogTests {
    @MainActor
    @Test("Enforces rolling capacity with newest entries first and clamps non-positive maxEntries")
    func enforcesRollingCapacityNewestFirst() {
        let log = EventLog(maxEntries: 3)
        for index in 1...5 {
            log.record(
                severity: .info,
                category: .audio,
                sourceName: "Main Monitor",
                message: "e\(index)"
            )
        }

        #expect(log.entries.count == 3)
        #expect(log.entries.map(\.message) == ["e5", "e4", "e3"])

        let clampedLog = EventLog(maxEntries: 0)
        clampedLog.record(severity: .info, category: .system, sourceName: "System", message: "first")
        clampedLog.record(severity: .info, category: .system, sourceName: "System", message: "second")
        #expect(clampedLog.entries.count == 1)
        #expect(clampedLog.entries.first?.message == "second")
    }

    @MainActor
    @Test("Tracks unread severity precedence, visibility gating, and clear")
    func tracksUnreadSeverityPrecedenceAndVisibilityGating() {
        #expect(EventSeverity.info < EventSeverity.warning)
        #expect(EventSeverity.warning < EventSeverity.error)

        let log = EventLog(maxEntries: 100)
        log.record(severity: .info, category: .audio, sourceName: "Bridge A", message: "Started")
        #expect(log.unreadWarningCount == 0)
        #expect(log.unreadErrorCount == 0)
        #expect(log.totalUnreadProblemCount == 0)
        #expect(log.highestUnreadSeverity == nil)

        log.record(severity: .warning, category: .audio, sourceName: "Bridge A", message: "Underrun")
        #expect(log.unreadWarningCount == 1)
        #expect(log.unreadErrorCount == 0)
        #expect(log.totalUnreadProblemCount == 1)
        #expect(log.highestUnreadSeverity == .warning)

        log.record(severity: .error, category: .permission, sourceName: "System", message: "Denied")
        #expect(log.unreadWarningCount == 1)
        #expect(log.unreadErrorCount == 1)
        #expect(log.totalUnreadProblemCount == 2)
        #expect(log.highestUnreadSeverity == .error)

        log.isEventsWindowVisible = true
        #expect(log.unreadWarningCount == 0)
        #expect(log.unreadErrorCount == 0)
        #expect(log.totalUnreadProblemCount == 0)
        #expect(log.highestUnreadSeverity == nil)

        log.record(severity: .error, category: .audio, sourceName: "Bridge A", message: "While visible")
        #expect(log.unreadErrorCount == 0)
        #expect(log.totalUnreadProblemCount == 0)

        log.isEventsWindowVisible = false
        log.record(severity: .warning, category: .clock, sourceName: "Bridge A", message: "Rate changed")
        #expect(log.unreadWarningCount == 1)
        #expect(log.totalUnreadProblemCount == 1)

        log.clear()
        #expect(log.entries.isEmpty)
        #expect(log.unreadWarningCount == 0)
        #expect(log.unreadErrorCount == 0)
        #expect(log.totalUnreadProblemCount == 0)
        #expect(log.highestUnreadSeverity == nil)
    }

    @MainActor
    @Test("Formats plain text export chronologically and flattens embedded newlines")
    func formatsPlainTextExportAndFlattensNewlines() {
        #expect(EventLog.exportText(for: []) == "")

        let log = EventLog(maxEntries: 100)
        let earlier = Date(timeIntervalSince1970: 1_700_000_000.125)
        let later = Date(timeIntervalSince1970: 1_700_000_005.250)

        log.record(
            severity: .info,
            category: .system,
            sourceName: "System",
            message: "Initialized",
            timestamp: earlier
        )
        log.record(
            severity: .error,
            category: .audio,
            sourceName: "Main Monitor",
            message: "Line 1\nLine 2\r\nLine 3",
            timestamp: later
        )

        let exportedAll = EventLog.exportText(for: log.entries)
        let allLines = exportedAll.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(allLines.count == 2)
        #expect(allLines[0].contains("[INFO] [System] [System] Initialized"))
        #expect(allLines[1].contains("[ERROR] [Audio] [Main Monitor] Line 1 Line 2 Line 3"))

        let singleExport = EventLog.exportText(for: [log.entries[0]])
        #expect(!singleExport.contains("\n"))
        #expect(!singleExport.contains("\r"))
        #expect(singleExport.contains("ERROR"))
        #expect(singleExport.contains("Main Monitor"))
        #expect(singleExport.contains("Line 1 Line 2 Line 3"))
    }
}
