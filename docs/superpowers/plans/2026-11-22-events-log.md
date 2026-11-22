# Events Diagnostic Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Audinate Dante Controller-style dedicated **Events** diagnostic window (`⌘E`) with severity/source/text filtering, unread toolbar & Menu Bar badges, background 1 Hz underrun/overrun XRun monitoring, and Copy/Export support.

**Architecture:** `AtomicMeterBank` tracks lock-free relaxed `Atomic<UInt64>` underrun and overrun counters written from `RealTimeAudioProcessor` with zero RT overhead. `InterceptorEngine` owns an in-memory rolling `@MainActor @Observable` `EventLog` (max 1,000 entries, newest first) fed by engine lifecycle/device/clock/permission transitions, updater errors, and a 1 Hz background monitor task active only while a bridge is running. A dedicated SwiftUI `Window("Events", id: "events")` renders a native macOS `Table` with multi-window Dock lifecycle coordination in `AppDelegate`.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit (`NSWindow`, `NSSavePanel`, `NSPasteboard`), Core Audio, `Synchronization.Atomic`, Swift Testing (`Testing`), Xcode project (`Interceptor.xcodeproj`).

**Spec:** `docs/superpowers/specs/2026-11-22-events-log-design.md`

## Global Constraints

- Minimum deployment target: macOS 26.0, Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`).
- Zero locks, zero heap allocations, zero Swift concurrency hops, and zero `EventLog` calls on Core Audio real-time IOProc threads.
- Session-only in-memory log capped at `1_000` entries (no continuous disk writes during live audio).
- Multi-window `AppDelegate` Dock policy: transition to `.accessory` only when **both** Main and Events windows are closed/not visible.
- Build/test artifacts must stay under `/tmp/InterceptorDerivedData`; never leave `.app` or `.zip` inside the repository (`AGENTS.md`).
- Test command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=macOS' -derivedDataPath /tmp/InterceptorDerivedData`

## Review Focus

1. **Burst XRun coalescing & restart reset:** Multiple underruns/overruns within one 1-second tick produce a single warning entry per bridge showing exact delta and cumulative total; restarting a bridge resets baseline counters so old counts are never subtracted incorrectly. (Pinned in Task 3)
2. **Rolling capacity eviction (`maxEntries`):** Recording more than `maxEntries` evicts the oldest tail entries while keeping `entries.count == maxEntries` and newest entries at index 0; `clear()` resets both entries and unread counters. (Pinned in Task 2)
3. **Unread severity precedence & visibility gating:** `.info` events never increment unread counters; when both warnings and errors are unread, `highestUnreadSeverity == .error`; setting `isEventsWindowVisible = true` clears unread counts immediately and suppresses further unread increments while open. (Pinned in Task 2)
4. **Simultaneous underrun + overrun in one polling tick:** When both `underrunDelta > 0` and `overrunDelta > 0` occur in the same tick, one combined warning describes both deltas without losing either count. (Pinned in Task 3)
5. **Export formatting edge cases:** `exportText(for:)` handles empty arrays cleanly and flattens embedded newlines in error messages so every event occupies one deterministic log line. (Pinned in Task 2)

---

### Task 1: Real-Time Underrun & Overrun Counters

**Files:**
- Modify: `InterceptorEngine/RealTime/AtomicMeterBank.swift:60-136,200-215`
- Modify: `InterceptorEngine/RealTime/RealTimeAudioProcessor.swift:322-333`
- Test: `InterceptorEngineTests/AtomicMeterBankTests.swift`
- Test: `InterceptorEngineTests/RealTimeAudioProcessorTests.swift`

**Interfaces:**
- Consumes: `LockFreeAudioRingBuffer.beginRead(outputFrameCount:) -> ReadBeginResult` (`.notReady(xrun: Bool)` for underflow, `.ready(plan: ReadBlockPlan, xrun: Bool)` for overflow)
- Produces:
  - `AtomicMeterBank.recordUnderrun()`
  - `AtomicMeterBank.recordOverrun()`
  - `AtomicMeterBank.underrunCount: UInt64`
  - `AtomicMeterBank.overrunCount: UInt64`

- [ ] **Step 1: Write failing tests for underrun/overrun tracking in `AtomicMeterBankTests.swift`**

Add a test `tracksUnderrunsAndOverrunsSeparatelyAndResets()` asserting:
```swift
@Test("Tracks underruns and overruns separately while summing total XRuns and resetting cleanly")
func tracksUnderrunsAndOverrunsSeparatelyAndResets() {
    let bank = AtomicMeterBank()

    bank.recordUnderrun()
    bank.recordUnderrun()
    bank.recordOverrun()

    #expect(bank.underrunCount == 2)
    #expect(bank.overrunCount == 1)
    #expect(bank.xrunCount == 3)

    bank.resetAll()
    #expect(bank.underrunCount == 0)
    #expect(bank.overrunCount == 0)
    #expect(bank.xrunCount == 0)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=macOS' -derivedDataPath /tmp/InterceptorDerivedData -only-testing:InterceptorEngineTests/AtomicMeterBankTests`
Expected: FAIL (compile error: `AtomicMeterBank` has no member `recordUnderrun` / `underrunCount`).

- [ ] **Step 3: Implement `recordUnderrun()`, `recordOverrun()`, `underrunCount`, `overrunCount` in `AtomicMeterBank.swift` and wire `RealTimeAudioProcessor.swift`**

In `InterceptorEngine/RealTime/AtomicMeterBank.swift`:
- Add `private let underruns: Atomic<UInt64>` and `private let overruns: Atomic<UInt64>`, initialized to `0`.
- Add `@inline(__always) public func recordUnderrun()` (relaxed `wrappingAdd(1)` on both `underruns` and `xruns`) and `@inline(__always) public func recordOverrun()` (relaxed `wrappingAdd(1)` on both `overruns` and `xruns`). Keep `recordXRun()` unchanged for compatibility.
- Add `public var underrunCount: UInt64` and `public var overrunCount: UInt64` (relaxed loads).
- Store `0` to `underruns` and `overruns` inside `resetAll()`.

In `InterceptorEngine/RealTime/RealTimeAudioProcessor.swift`:
- In `processMonitorOutput(outOutputData:frameCount:)`:
  - `.notReady(xrun: true)` → `meterBank.recordUnderrun()`
  - `.ready(_, xrun: true)` → `meterBank.recordOverrun()`

- [ ] **Step 4: Run tests to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=macOS' -derivedDataPath /tmp/InterceptorDerivedData`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add InterceptorEngine/RealTime/AtomicMeterBank.swift InterceptorEngine/RealTime/RealTimeAudioProcessor.swift InterceptorEngineTests/AtomicMeterBankTests.swift
git commit -m "Track buffer underruns and overruns separately in AtomicMeterBank"
```

---

### Task 2: `EngineEvent` Model & In-Memory `EventLog` Store

**Files:**
- Create: `InterceptorEngine/Models/EngineEvent.swift`
- Create: `InterceptorEngineTests/EventLogTests.swift`
- Modify: `Interceptor.xcodeproj/project.pbxproj` (register `EngineEvent.swift` in `InterceptorEngine` and `EventLogTests.swift` in `InterceptorEngineTests`)

**Interfaces:**
- Consumes: none
- Produces:
  - `public enum EventSeverity: String, CaseIterable, Sendable, Comparable, Identifiable` (`.info`, `.warning`, `.error`)
  - `public enum EventCategory: String, CaseIterable, Sendable, Identifiable` (`.audio`, `.device`, `.clock`, `.permission`, `.system`, `.update`)
  - `public struct EngineEvent: Identifiable, Sendable, Equatable` (`id: UUID`, `timestamp: Date`, `severity: EventSeverity`, `category: EventCategory`, `bridgeID: UUID?`, `sourceName: String`, `message: String`)
  - `public final class EventLog` (`@MainActor @Observable`):
    - `public init(maxEntries: Int = 1_000)`
    - `public private(set) var entries: [EngineEvent]` (newest first)
    - `public private(set) var unreadWarningCount: Int`
    - `public private(set) var unreadErrorCount: Int`
    - `public var totalUnreadProblemCount: Int`
    - `public var highestUnreadSeverity: EventSeverity?`
    - `public var isEventsWindowVisible: Bool` (setting `true` triggers `markAllRead()`)
    - `public func record(severity: EventSeverity, category: EventCategory, bridgeID: UUID? = nil, sourceName: String, message: String, timestamp: Date = Date())`
    - `public func markAllRead()`
    - `public func clear()`
    - `public static func exportText(for events: [EngineEvent]) -> String`

- [ ] **Step 1: Create `InterceptorEngineTests/EventLogTests.swift` and register it + `EngineEvent.swift` in `project.pbxproj`**

Write tests pinning Review Focus items 2, 3, and 5:
- `enforcesRollingCapacityNewestFirst()`: create `EventLog(maxEntries: 3)`, record 5 events `"e1"..."e5"`, assert `entries.count == 3` and `entries.map(\.message) == ["e5", "e4", "e3"]`.
- `tracksUnreadSeverityPrecedenceAndVisibilityGating()`:
  - Record `.info` → `unreadWarningCount == 0`, `unreadErrorCount == 0`, `highestUnreadSeverity == nil`.
  - Record `.warning` → `unreadWarningCount == 1`, `highestUnreadSeverity == .warning`.
  - Record `.error` → `unreadErrorCount == 1`, `totalUnreadProblemCount == 2`, `highestUnreadSeverity == .error`.
  - Set `isEventsWindowVisible = true` → `unreadWarningCount == 0`, `unreadErrorCount == 0`, `highestUnreadSeverity == nil`.
  - Record another `.error` while visible → `unreadErrorCount == 0`.
  - Set `isEventsWindowVisible = false`, record `.warning`, then call `clear()` → `entries.isEmpty`, `totalUnreadProblemCount == 0`.
- `formatsPlainTextExportAndFlattensNewlines()`:
  - `EventLog.exportText(for: [])` returns `""`.
  - Record event with message `"Line 1\nLine 2"` → exported text has single line containing `"ERROR"`, `"Main Monitor"`, `"Line 1 Line 2"` with no raw inner newline.

- [ ] **Step 2: Run `EventLogTests` to verify failure before creating `EngineEvent.swift`**

Create a minimal empty stub or run build to confirm missing type failure, then implement `EngineEvent.swift`.

- [ ] **Step 3: Implement `InterceptorEngine/Models/EngineEvent.swift`**

Implement `EventSeverity` (with `Comparable` ordering `.info < .warning < .error`, plus `displayName`), `EventCategory` (with `displayName`), `EngineEvent`, and `@MainActor @Observable public final class EventLog`:
- `record(...)` inserts at index `0`, removes excess tail items when `entries.count > maxEntries`, and increments `unreadWarningCount` or `unreadErrorCount` only when `!isEventsWindowVisible`.
- `isEventsWindowVisible` `didSet`: if `isEventsWindowVisible`, call `markAllRead()`.
- `exportText(for events: [EngineEvent])`: return `""` when empty; otherwise format each event chronologically (oldest-to-newest for log file readability, or matching table order—use chronological oldest-to-newest with ISO-8601 fractional seconds: `[YYYY-MM-DD HH:mm:ss.SSS] [SEVERITY] [Category] [Source] Message`), replacing `\r\n` / `\n` with single spaces.

- [ ] **Step 4: Run `EventLogTests` to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=macOS' -derivedDataPath /tmp/InterceptorDerivedData -only-testing:InterceptorEngineTests/EventLogTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add InterceptorEngine/Models/EngineEvent.swift InterceptorEngineTests/EventLogTests.swift Interceptor.xcodeproj/project.pbxproj
git commit -m "Add EngineEvent model and in-memory EventLog store"
```

---

### Task 3: Engine & Updater Event Instrumentation + Background 1 Hz XRun Monitor

**Files:**
- Modify: `InterceptorEngine/CoreAudio/InterceptorEngine.swift`
- Modify: `Interceptor/Updates/GitHubReleaseUpdater.swift`
- Modify: `Interceptor/State/AppViewModel.swift`
- Test: `InterceptorEngineTests/EventLogTests.swift`

**Interfaces:**
- Consumes:
  - `AtomicMeterBank.underrunCount`, `overrunCount`, `xrunCount` (Task 1)
  - `EventLog`, `EngineEvent`, `EventSeverity`, `EventCategory` (Task 2)
- Produces:
  - `InterceptorEngine.eventLog: EventLog`
  - `InterceptorEngine.formatXRunEventMessage(underrunDelta: UInt64, overrunDelta: UInt64, totalXRuns: UInt64) -> String?` (internal/public static helper for deterministic unit testing)
  - `GitHubReleaseUpdater.onError: (@MainActor (String) -> Void)?`

- [ ] **Step 1: Write failing tests in `EventLogTests.swift` for XRun message coalescing**

Pin Review Focus items 1 and 4:
```swift
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
```

- [ ] **Step 2: Run test to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=macOS' -derivedDataPath /tmp/InterceptorDerivedData -only-testing:InterceptorEngineTests/EventLogTests`
Expected: FAIL (`InterceptorEngine` has no member `formatXRunEventMessage`).

- [ ] **Step 3: Instrument `InterceptorEngine`, `GitHubReleaseUpdater`, and `AppViewModel`**

In `InterceptorEngine/CoreAudio/InterceptorEngine.swift`:
- Add `public let eventLog: EventLog` (injectable via `init(catalog:store:eventLog: EventLog = EventLog())`).
- Add `var lastLoggedUnderruns: UInt64 = 0` and `var lastLoggedOverruns: UInt64 = 0` to `BridgeRuntime`, reset to `0` on bridge start and teardown.
- Add `public static func formatXRunEventMessage(underrunDelta: UInt64, overrunDelta: UInt64, totalXRuns: UInt64) -> String?`.
- Update `syncXRunCounts()` to also check `underrunCount` and `overrunCount` deltas against `lastLoggedUnderruns` / `lastLoggedOverruns` (guarding against wrap/reset when current < lastLogged), update the baseline counters, and emit a coalesced `.warning` / `.audio` event via `eventLog.record(...)`.
- Add `private var xrunMonitorTask: Task<Void, Never>?` managed in `syncLatencyCriticalActivity()` (starts a 1-second sleep loop calling `syncXRunCounts()` whenever `anyBridgeRunning == true`, cancels when no bridge is running and in `shutdown()`).
- Record structured events in `eventLog`:
  - `startBridge`: waiting for offline source/destination (`.warning`, `.device`); started (`.info`, `.audio`, showing sample rate, buffer frames, estimated latency, SRC vs bit-transparent); permission denied (`.error`, `.permission`); other start failure (`.error`, `.audio`).
  - `stopBridge`: user-stopped an active/pending bridge (`.info`, `.audio`). Do not emit stop noise during `shutdown()`.
  - `restoreActiveBridges`: restoring active bridges on launch (`.info`, `.system`).
  - `handleActiveDeviceDisconnected`: active source/monitor interface disconnected (`.warning`, `.device`).
  - `handleTopologyChange`: interface returned / auto-reconnecting (`.info`, `.device`).
  - `scheduleFormatRebuild`: audio format or sample rate changed, rebuilding bridge (`.warning`, `.clock`).
  - `handleCoreAudioRestarted`: `coreaudiod` restarted, recovering active bridges (`.warning`, `.system`).

In `Interceptor/Updates/GitHubReleaseUpdater.swift` & `Interceptor/State/AppViewModel.swift`:
- Add `public var onError: (@MainActor (String) -> Void)?` on `GitHubReleaseUpdater` and invoke it whenever `state = .error(msg)` is set (including user-initiated check errors and install failures).
- In `AppViewModel.init`, wire `updater.onError` to record `.error` / `.update` with `sourceName: "Updater"` into `engine.eventLog`.

- [ ] **Step 4: Run full test suite to verify pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=macOS' -derivedDataPath /tmp/InterceptorDerivedData`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add InterceptorEngine/CoreAudio/InterceptorEngine.swift Interceptor/Updates/GitHubReleaseUpdater.swift Interceptor/State/AppViewModel.swift InterceptorEngineTests/EventLogTests.swift
git commit -m "Instrument engine and updater diagnostics with 1 Hz background XRun monitor"
```

---

### Task 4: Dedicated Events Window (`⌘E`), Badges & Multi-Window Dock Lifecycle

**Files:**
- Create: `Interceptor/Views/EventsWindowView.swift`
- Modify: `Interceptor/App/InterceptorApp.swift`
- Modify: `Interceptor/App/AppDelegate.swift`
- Modify: `Interceptor/Views/MainWindowView.swift`
- Modify: `Interceptor/Views/MenuBarPopoverView.swift`
- Modify: `Interceptor/Resources/Localizable.xcstrings`
- Modify: `Interceptor.xcodeproj/project.pbxproj` (register `EventsWindowView.swift`)

**Interfaces:**
- Consumes:
  - `InterceptorEngine.eventLog` (`entries`, `unreadWarningCount`, `unreadErrorCount`, `totalUnreadProblemCount`, `highestUnreadSeverity`, `isEventsWindowVisible`, `clear()`, `EventLog.exportText(for:)`)
- Produces:
  - SwiftUI scene `Window("Events", id: "events")`
  - `AppDelegate.openEventsWindowAction`, `registerEventsWindow(_:)`, `showEventsWindow()`
  - Keyboard shortcut `⌘E` ("Events") in `InterceptorCommands`

- [ ] **Step 1: Create `Interceptor/Views/EventsWindowView.swift` and register it in `project.pbxproj`**

Build a native macOS Dante Controller-inspired diagnostic window:
- Top filter bar:
  - Severity filter pills: `All`, `Errors` (with red count if > 0), `Warnings` (with orange count if > 0), `Info`.
  - Source picker (`All Sources` + dynamic list of unique sources present + configured bridges).
  - Search field (`Search events…`).
- Toolbar actions:
  - `Copy` (copies `EventLog.exportText(for: filteredEvents)` to `NSPasteboard.general`, brief confirmation icon/label).
  - `Export…` (presents `NSSavePanel` with default filename `Interceptor-Events-YYYYMMDD-HHmmss.log` and writes UTF-8 `EventLog.exportText(for: filteredEvents)`).
  - `Clear` (calls `viewModel.engine.eventLog.clear()`, disabled when `entries.isEmpty`).
- Body:
  - Native SwiftUI `Table(filteredEvents)` with columns:
    - `Time` (fixed width ~92, monospaced `HH:mm:ss.SSS`)
    - `Type` (fixed width ~44, SF Symbol colored red/orange/secondary with tooltip & accessibility label)
    - `Source` (width ~140, lineLimit 1)
    - `Message` (flexible width, selectable/copyable via context menu)
  - `ContentUnavailableView` when no events (or no events match active filters).
- Footer status strip: total events count, error count, warning count, and `"Live · Monitoring active bridges"` indicator when `engine.anyBridgeRunning`.
- Attach `EventsWindowRegistrationView` (`NSViewRepresentable` mirroring `MainWindowRegistrationView`) to call `appDelegate.registerEventsWindow(window)`.

- [ ] **Step 2: Update `AppDelegate.swift` for multi-window Dock lifecycle & Events visibility tracking**

- Track `private weak var eventsWindow: NSWindow?` and `private var eventsWindowObservers: [NSObjectProtocol] = []`, plus `var openEventsWindowAction: (() -> Void)?`.
- Add `registerEventsWindow(_ window: NSWindow)` observing `willClose`, `willMiniaturize`, `didDeminiaturize`, `didChangeOcclusionState`, `didBecomeKey` to sync `viewModel?.engine.eventLog.isEventsWindowVisible` and keep `.regular` activation policy while visible.
- Add `showEventsWindow()` switching to `.regular` if needed, calling `openEventsWindowAction?()`, deminiaturizing/fronting `eventsWindow`, activating `NSApp`, and syncing visibility.
- Update `handleMainWindowWillClose()` and add `handleEventsWindowWillClose()` to share a single `scheduleAccessoryPolicyTransitionIfNoWindowsVisible()` helper that only switches to `.accessory` when **neither** `mainWindow?.isVisible == true` **nor** `eventsWindow?.isVisible == true`.
- Update `applicationDidBecomeActive` to also sync events window visibility, and `applicationWillTerminate` to remove events window observers.

- [ ] **Step 3: Wire `InterceptorApp.swift`, `MainWindowView.swift`, `MenuBarPopoverView.swift`, and `Localizable.xcstrings`**

- `InterceptorApp.swift`:
  - Add `Window("Events", id: "events")` hosting `EventsWindowView(viewModel: viewModel, appDelegate: appDelegate)` with `.defaultSize(width: 740, height: 420)`.
  - In `InterceptorCommands` (`Bridge` menu), add `Button("Events") { appDelegate.showEventsWindow() }` with `.keyboardShortcut("e", modifiers: .command)`.
- `MainWindowView.swift`:
  - Register `appDelegate.openEventsWindowAction = { openWindow(id: "events") }` on appear.
  - Add toolbar button for **Events** (`⌘E`) showing SF Symbol (`list.bullet.rectangle` when clean, `exclamationmark.triangle.fill` / badge overlay in red or orange when `eventLog.totalUnreadProblemCount > 0`) and tooltip showing unread warning/error counts.
- `MenuBarPopoverView.swift`:
  - Register `appDelegate.openEventsWindowAction = { openWindow(id: "events") }` on appear.
  - Add `"Events…"` (`⌘E`) action row above `"Settings…"` displaying an unread count badge (red for errors, orange for warnings) when `totalUnreadProblemCount > 0`.
- `Localizable.xcstrings`: add new user-facing English strings for Events UI.

- [ ] **Step 4: Run full test suite and signed Release build**

Run:
```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor -destination 'platform=macOS' -derivedDataPath /tmp/InterceptorDerivedData
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -project Interceptor.xcodeproj -scheme Interceptor -configuration Release -destination 'generic/platform=macOS' -derivedDataPath /tmp/InterceptorDerivedData ONLY_ACTIVE_ARCH=NO
codesign --verify --deep --strict /tmp/InterceptorDerivedData/Build/Products/Release/Interceptor.app
```
Expected: `** TEST SUCCEEDED **`, `** BUILD SUCCEEDED **`, and `codesign --verify` exits `0`. Verify `git status` shows zero `.app` or `.zip` files in the repo.

- [ ] **Step 5: Commit**

```bash
git add Interceptor/Views/EventsWindowView.swift Interceptor/App/InterceptorApp.swift Interceptor/App/AppDelegate.swift Interceptor/Views/MainWindowView.swift Interceptor/Views/MenuBarPopoverView.swift Interceptor/Resources/Localizable.xcstrings Interceptor.xcodeproj/project.pbxproj
git commit -m "Add dedicated Events diagnostic window with unread badges and export"
```
