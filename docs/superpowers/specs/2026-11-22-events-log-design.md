# Events Diagnostic Window Design

**Date:** 2026-11-22
**Status:** Proposed
**Scope:** Feature (InterceptorEngine + Interceptor macOS UI)

## Intent & Why

Audio engineers using Interceptor alongside DAWs (such as Pro Tools) and network/hardware interfaces often leave Interceptor running silently in the Menu Bar. When an audio glitch, clock/sample-rate change, device disconnect, `coreaudiod` restart, or permission denial happens, there is currently no in-app chronological log to inspect what occurred and when—diagnostics only go to `os.Logger` (Console.app), and XRun counters are only polled while the main window is visible.

Inspired by **Audinate Dante Controller's Events** log, this feature adds a dedicated, live **Events** window (`⌘E`) with severity filtering, unread problem badges on the main toolbar and Menu Bar, background XRun monitoring (distinguishing buffer **underrun** vs **overrun**), and one-click Copy/Export.

## Goals, Non-Goals & Anti-Goals

### Goals
- Dedicated macOS `Events` window (`⌘E`) that can stay open side-by-side with the main patch window.
- Structured, timestamped session event log with severities (**Error**, **Warning**, **Info**) and categories (**Audio**, **Device**, **Clock**, **Permission**, **System**, **Update**).
- Separate tracking of **Buffer Underrun** (source stream stalled/paused) vs **Buffer Overrun** (monitor output stalled/wake-from-sleep) in the real-time engine with zero RT overhead.
- Background 1 Hz XRun polling whenever any bridge is running so dropouts are captured even when the main window is closed/hidden in the Menu Bar.
- Unread warning/error badge on the main toolbar `Events` button and in the Menu Bar popover, clearing automatically when the Events window is opened/focused.
- Filters by severity, source/Virtual Device, and free-text search, plus **Copy**, **Export…** (`.log`), and **Clear**.
- Proper multi-window Dock visibility in `AppDelegate` so closing the main window does not hide an open Events window.

### Non-Goals
- Persisting the event log across app restarts (session-only in memory, matching Dante Controller; users can Export before quitting).
- Logging individual audio callbacks or per-frame telemetry from the real-time thread.
- Remote or network log streaming.

### Anti-Goals
- **Zero real-time impact:** No locks, heap allocations, Swift concurrency hops, or `EventLog` calls from Core Audio IOProc threads.
- **No log flooding:** Burst XRuns within a 1-second window must be coalesced into a single warning event per bridge showing the delta and cumulative total.
- **No window-lifecycle regressions:** Closing the main window while Events is open must keep `.regular` activation policy until both windows are closed.

## Approaches Considered

### Approach A — In-Memory Rolling `EventLog` (1,000 entries) + Copy / Export *(Selected)*
- `InterceptorEngine` owns a `@MainActor @Observable` `EventLog` keeping the latest 1,000 events in memory.
- Zero disk I/O during live audio sessions, instant filtering/clearing, and on-demand `.log` export via `NSSavePanel` or clipboard copy.
- Matches Dante Controller's session-log workflow cleanly.

### Approach B — Continuous On-Disk Rotating Log File *(Not Selected)*
- Persists every event asynchronously to a rotating log file in `Application Support/Interceptor/`.
- Adds background file I/O, log rotation, and crash-safety complexity not needed for live diagnostic monitoring when Export covers sharing/archiving.

## Architecture & Component Design

### 1. Real-Time Engine Counters (`InterceptorEngine/RealTime/`)
- **`AtomicMeterBank.swift`**:
  - Add relaxed `Atomic<UInt64>` counters `underruns` and `overruns` alongside existing `xruns`.
  - Add `@inline(__always) recordUnderrun()` and `recordOverrun()` which increment their specific counter and `xruns`. Keep existing `recordXRun()` for API compatibility.
  - Expose `underrunCount: UInt64` and `overrunCount: UInt64`; reset both in `resetAll()`.
- **`RealTimeAudioProcessor.swift`**:
  - In `processMonitorOutput`, map `ringBuffer.beginRead`:
    - `.notReady(xrun: true)` → `meterBank.recordUnderrun()`
    - `.ready(_, xrun: true)` → `meterBank.recordOverrun()`

### 2. Event Model & Rolling Store (`InterceptorEngine/Models/EngineEvent.swift`)
- `EventSeverity: String, CaseIterable, Sendable, Comparable`: `.info`, `.warning`, `.error`.
- `EventCategory: String, CaseIterable, Sendable`: `.audio`, `.device`, `.clock`, `.permission`, `.system`, `.update`.
- `EngineEvent: Identifiable, Sendable, Equatable`:
  - `id: UUID`, `timestamp: Date`, `severity: EventSeverity`, `category: EventCategory`, `bridgeID: UUID?`, `sourceName: String`, `message: String`.
- `EventLog` (`@MainActor @Observable`):
  - `maxEntries = 1_000`; stores entries newest-first so the latest issue is always immediately visible at the top.
  - `unreadWarningCount: Int`, `unreadErrorCount: Int`, `totalUnreadProblemCount: Int`, `highestUnreadSeverity: EventSeverity?`.
  - `isEventsWindowVisible: Bool`: when set to `true`, automatically calls `markAllRead()`.
  - `record(severity:category:bridgeID:sourceName:message:)`: inserts at index 0, trims tail beyond `maxEntries`, and increments unread counts only for `.warning` / `.error` when `!isEventsWindowVisible`.
  - `clear()`, `markAllRead()`, `exportText(for: [EngineEvent]) -> String`.

### 3. Engine Instrumentation & Background XRun Monitor (`InterceptorEngine/CoreAudio/InterceptorEngine.swift`)
- `InterceptorEngine` owns `public let eventLog: EventLog`.
- Each `BridgeRuntime` tracks `lastLoggedUnderruns: UInt64` and `lastLoggedOverruns: UInt64` (reset on start/stop).
- A lightweight `xrunMonitorTask: Task<Void, Never>?` runs at 1 Hz **only while `anyBridgeRunning == true`** (started/stopped from `syncLatencyCriticalActivity()`, cancelled in `shutdown()`):
  - Calls `syncXRunCounts()`.
  - For each running bridge where underrun or overrun counts increased since the previous check, logs a single coalesced `.warning` event (e.g., `"Buffer underrun (+3, total 5) — source stream stalled"`, `"Buffer overrun (+1, total 2) — monitor output stalled"`, or combined if both occurred).
- Lifecycle & diagnostic events emitted by `InterceptorEngine`:
  - **Info:** Bridge started (rate, buffer frames, latency, SRC vs bit-transparent), bridge stopped (user action), bridge restored on launch, interface auto-reconnected.
  - **Warning:** XRun underrun/overrun detected, active source/monitor interface disconnected, bridge waiting for offline interface, format/sample-rate change triggering bridge rebuild, `coreaudiod` restarted.
  - **Error:** System Audio Recording permission denied, bridge start failure (`AudioTapBridgeError`).
- `GitHubReleaseUpdater` (via callback or `AppViewModel` hook) records update check / download / install failures as `.error` under `.update`.

### 4. Dedicated Events Window & App Integration (`Interceptor/`)
- **`InterceptorApp.swift`**:
  - Add `Window("Events", id: "events")` hosting `EventsWindowView(viewModel: viewModel, appDelegate: appDelegate)` with `.defaultSize(width: 720, height: 420)`.
  - Add `"Events"` menu command with shortcut `⌘E` (opens/focuses the Events window).
- **`AppDelegate.swift`**:
  - Add `openEventsWindowAction`, `registerEventsWindow(_:)`, and `showEventsWindow()`.
  - Observe Events window close/miniaturize/occlusion/becomeKey to sync `viewModel?.engine.eventLog.isEventsWindowVisible`.
  - Only switch `NSApp.setActivationPolicy(.accessory)` when **both** `mainWindow` and `eventsWindow` are closed/not visible.
- **`MainWindowView.swift`**:
  - Add an `Events` toolbar button (`⌘E`) alongside `Bridge Info` and `Settings…`, displaying a subtle unread badge/dot (red if `unreadErrorCount > 0`, orange if `unreadWarningCount > 0`).
- **`MenuBarPopoverView.swift`**:
  - Add an `"Events…"` (`⌘E`) row showing the unread warning/error count badge when > 0.
- **`EventsWindowView.swift`**:
  - Filter bar: severity pills (`All`, `Errors`, `Warnings`, `Info` with counts), Source/Bridge picker (`All Sources` + bridges + `System`/`Updater`), and search field.
  - Action buttons: `Copy`, `Export…` (`NSSavePanel` writing `.log`), `Clear`.
  - Native macOS `Table` with monospaced `Time` (`HH:mm:ss.SSS`), severity icon (`Type`), `Source`, and `Message` columns, plus `ContentUnavailableView` when empty.

## Verification Plan
- Unit tests in `InterceptorEngineTests`:
  - `AtomicMeterBankTests`: verify `recordUnderrun()` and `recordOverrun()` independently increment specific counters + total `xrunCount`, and reset cleanly.
  - `EventLogTests`: verify rolling cap (`maxEntries`), unread warning/error counting, auto-clear when `isEventsWindowVisible == true`, `clear()`, and plain-text export formatting.
- Full `xcodebuild test` pass and signed Release build check.
