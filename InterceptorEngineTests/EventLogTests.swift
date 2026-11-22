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

    @Test("Coalesces underrun, overrun, and combined XRun deltas into clear diagnostic messages")
    func formatsCoalescedXRunMessages() {
        #expect(InterceptorEngine.formatXRunEventMessage(underrunDelta: 0, overrunDelta: 0, totalXRuns: 0) == nil)

        let under = InterceptorEngine.formatXRunEventMessage(underrunDelta: 3, overrunDelta: 0, totalXRuns: 5)
        #expect(under?.contains("underrun") == true)
        #expect(under?.contains("+3") == true)
        #expect(under?.contains("5") == true)

        let over = InterceptorEngine.formatXRunEventMessage(underrunDelta: 0, overrunDelta: 1, totalXRuns: 2)
        #expect(over?.contains("overrun") == true)
        #expect(over?.contains("+1") == true)
        #expect(over?.contains("2") == true)

        let both = InterceptorEngine.formatXRunEventMessage(underrunDelta: 2, overrunDelta: 4, totalXRuns: 10)
        #expect(both?.contains("underrun") == true)
        #expect(both?.contains("overrun") == true)
        #expect(both?.contains("+2") == true)
        #expect(both?.contains("+4") == true)
        #expect(both?.contains("10") == true)
    }

    @Test("Computes XRun deltas safely when counters advance or reset below baseline")
    func computesSafeXRunDeltaAcrossResets() {
        #expect(InterceptorEngine.xrunDelta(current: 0, lastLogged: 0) == 0)
        #expect(InterceptorEngine.xrunDelta(current: 7, lastLogged: 4) == 3)
        #expect(InterceptorEngine.xrunDelta(current: 4, lastLogged: 4) == 0)
        #expect(InterceptorEngine.xrunDelta(current: 2, lastLogged: 9) == 2)
        #expect(InterceptorEngine.xrunDelta(current: 0, lastLogged: 9) == 0)
    }

    @MainActor
    @Test("Records offline device waiting, active stop, restore, and suppresses idle or shutdown stop noise")
    func recordsEngineLifecycleEventsWithoutIdleOrShutdownNoise() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let offlineBridge = AudioBridgeConfiguration(
            name: "Studio Bus",
            sourceDeviceUID: "missing-source-\(UUID().uuidString)",
            sourceDeviceName: "Offline Console",
            destinationDeviceUID: "missing-dest-\(UUID().uuidString)",
            destinationDeviceName: "Offline DAC",
            wasActive: true
        )
        let store = BridgeStore(fileURL: tempDir.appendingPathComponent("bridges.json"))
        try store.saveBridges([offlineBridge])

        let log = EventLog(maxEntries: 100)
        let engine = InterceptorEngine(store: store, eventLog: log)
        defer { engine.shutdown() }

        #expect(log.entries.isEmpty)

        // Restoring active bridges logs a system restore event and device waiting warning.
        engine.restoreActiveBridges()
        #expect(log.entries.contains {
            $0.severity == .info && $0.category == .system && $0.sourceName == "System"
        })
        #expect(log.entries.contains {
            $0.severity == .warning &&
                $0.category == .device &&
                $0.bridgeID == offlineBridge.id &&
                $0.sourceName == "Studio Bus"
        })

        // Stopping an active/pending bridge logs an audio stop event.
        let countBeforeStop = log.entries.count
        engine.stopBridge(id: offlineBridge.id)
        #expect(log.entries.count == countBeforeStop + 1)
        #expect(log.entries.first?.severity == .info)
        #expect(log.entries.first?.category == .audio)
        #expect(log.entries.first?.bridgeID == offlineBridge.id)

        // Stopping or removing an already-idle bridge must not emit noisy stop events.
        let countAfterStop = log.entries.count
        engine.stopBridge(id: offlineBridge.id)
        #expect(log.entries.count == countAfterStop)
        engine.removeBridge(id: offlineBridge.id)
        #expect(log.entries.count == countAfterStop)

        // Start a second bridge into waiting state, then call shutdown() — must NOT emit stop noise.
        let second = engine.addBridge(name: "Headphones")
        var updatedSecond = second
        updatedSecond.sourceDeviceUID = "missing-src-2"
        updatedSecond.sourceDeviceName = "Offline Source 2"
        engine.updateBridge(updatedSecond)
        engine.startBridge(id: updatedSecond.id)
        let countBeforeShutdown = log.entries.count
        engine.shutdown()
        #expect(log.entries.count == countBeforeShutdown)
    }
}
