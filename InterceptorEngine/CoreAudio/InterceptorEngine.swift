import CoreAudio
import Foundation
import Observation
import os

/// Manages multiple independent virtual passive audio routing bridges ("virtual devices"),
/// each with its own source interface, monitor destination, discrete mono channel patches,
/// live Core Audio SubTap lifecycle, and hot-plug recovery.
@MainActor
@Observable
public final class InterceptorEngine {
    private final class BridgeRuntime {
        let tapBridge = AudioTapBridge()
        var desiredActive = false
        var activeTappedStreams: [Int] = []
        var pendingRebuildTask: Task<Void, Never>?
        var lastLoggedUnderruns: UInt64 = 0
        var lastLoggedOverruns: UInt64 = 0
    }

    private let logger = Logger(subsystem: "com.interceptor.audio", category: "InterceptorEngine")
    private let catalog: CoreAudioDeviceCatalog
    private let store: BridgeStore
    public let eventLog: EventLog

    /// All currently connected Core Audio output interfaces.
    public private(set) var availableDevices: [AudioDeviceDescriptor] = []

    /// User-facing macOS applications available for optional process-scoped tapping.
    public private(set) var availableProcesses: [AudioProcessDescriptor] = []

    /// Configured virtual routing bridges (persisted automatically).
    public private(set) var bridges: [AudioBridgeConfiguration] = []

    /// Live telemetry per bridge ID.
    public private(set) var telemetryByBridgeID: [UUID: EngineTelemetry] = [:]

    /// Automatic reconnection when a disconnected interface returns.
    public var autoReconnectEnabled: Bool = true

    /// Global optional preferred buffer frames for direct monitor outputs (`nil` = automatic).
    public var preferredBufferFrames: Int? {
        didSet {
            guard preferredBufferFrames != oldValue else { return }
            for bridge in bridges where isBridgeRunning(bridge.id) {
                restartBridge(id: bridge.id)
            }
        }
    }

    /// Global safety headroom profile for the decoupled drift-compensating ring buffer.
    public var driftBufferProfile: DriftBufferProfile = .balanced {
        didSet {
            guard driftBufferProfile != oldValue else { return }
            for bridge in bridges where isBridgeRunning(bridge.id) {
                restartBridge(id: bridge.id)
            }
        }
    }

    private var runtimes: [UUID: BridgeRuntime] = [:]

    /// Prevents macOS App Nap, timer coalescing, and E-core throttling while any bridge is active.
    private var latencyActivityToken: NSObjectProtocol?

    private var pendingDeviceRefreshTask: Task<Void, Never>?
    private var pendingProcessRefreshTask: Task<Void, Never>?
    private var xrunMonitorTask: Task<Void, Never>?

    public init(
        catalog: CoreAudioDeviceCatalog = CoreAudioDeviceCatalog(),
        store: BridgeStore = BridgeStore(),
        eventLog: EventLog = EventLog()
    ) {
        self.catalog = catalog
        self.store = store
        self.eventLog = eventLog

        refreshDevices()
        loadOrCreateInitialBridges()

        catalog.startObserving(
            onDeviceListChanged: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedDeviceTopologyChange()
                }
            },
            onProcessListChanged: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedProcessRefresh()
                }
            },
            onServiceRestarted: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleCoreAudioRestarted()
                }
            }
        )
    }

    // MARK: - Queries

    public var anyBridgeRunning: Bool {
        telemetryByBridgeID.values.contains { $0.state.isRunning }
    }

    public var anyBridgeActiveOrPending: Bool {
        telemetryByBridgeID.values.contains { $0.state.isActiveOrPending }
    }

    public var runningBridgeCount: Int {
        telemetryByBridgeID.values.filter { $0.state.isRunning }.count
    }

    public func bridge(for id: UUID?) -> AudioBridgeConfiguration? {
        guard let id else { return nil }
        return bridges.first(where: { $0.id == id })
    }

    public func telemetry(for id: UUID) -> EngineTelemetry {
        telemetryByBridgeID[id] ?? EngineTelemetry()
    }

    public func isBridgeRunning(_ id: UUID) -> Bool {
        telemetry(for: id).state.isRunning
    }

    public func isBridgeActiveOrPending(_ id: UUID) -> Bool {
        telemetry(for: id).state.isActiveOrPending
    }

    public func sourceDevice(for bridge: AudioBridgeConfiguration) -> AudioDeviceDescriptor? {
        guard let uid = bridge.sourceDeviceUID else { return nil }
        return availableDevices.first(where: { $0.uid == uid })
    }

    public func destinationDevice(for bridge: AudioBridgeConfiguration) -> AudioDeviceDescriptor? {
        guard let uid = bridge.destinationDeviceUID else { return nil }
        return availableDevices.first(where: { $0.uid == uid })
    }

    public func canStartBridge(_ id: UUID) -> Bool {
        guard let config = bridge(for: id) else { return false }
        return sourceDevice(for: config) != nil &&
            destinationDevice(for: config) != nil &&
            config.routes.contains(where: \.isEnabled)
    }

    public func validationIssues(for bridge: AudioBridgeConfiguration) -> [UUID: [RouteValidationIssue]] {
        RouteValidator.validate(
            routes: bridge.routes,
            sourceDevice: sourceDevice(for: bridge),
            destinationDevice: destinationDevice(for: bridge)
        )
    }

    // MARK: - Device Catalog

    /// Refreshes only the list of Core Audio client applications without re-enumerating hardware devices.
    public func refreshProcesses() {
        let updated = catalog.fetchAudioProcesses()
        if updated != availableProcesses {
            availableProcesses = updated
        }
    }

    public func refreshDevices() {
        availableDevices = catalog.fetchOutputDevices()
        availableProcesses = catalog.fetchAudioProcesses()
        // Keep cached display names fresh whenever devices are online.
        var didUpdateNames = false
        for i in bridges.indices {
            if let src = sourceDevice(for: bridges[i]), bridges[i].sourceDeviceName != src.name {
                bridges[i].sourceDeviceName = src.name
                didUpdateNames = true
            }
            if let dst = destinationDevice(for: bridges[i]), bridges[i].destinationDeviceName != dst.name {
                bridges[i].destinationDeviceName = dst.name
                didUpdateNames = true
            }
            let id = bridges[i].id
            if telemetry(for: id).state == .idle {
                telemetryByBridgeID[id] = makeIdleTelemetry(for: bridges[i])
            }
        }
        if didUpdateNames {
            persistBridges()
        }
    }

    // MARK: - Bridge CRUD

    @discardableResult
    public func addBridge(name: String? = nil) -> AudioBridgeConfiguration {
        let defaults = sensibleDefaultDevices()
        let bridgeName = name ?? defaultBridgeName()
        let newBridge = AudioBridgeConfiguration(
            name: bridgeName,
            sourceDeviceUID: defaults.source?.uid,
            sourceDeviceName: defaults.source?.name,
            destinationDeviceUID: defaults.destination?.uid,
            destinationDeviceName: defaults.destination?.name,
            processTarget: .allProcesses,
            routes: [
                ChannelRoute(label: "Channel 1", sourceChannel: 1, destinationChannel: 1),
                ChannelRoute(label: "Channel 2", sourceChannel: 2, destinationChannel: 2)
            ]
        )
        bridges.append(newBridge)
        telemetryByBridgeID[newBridge.id] = makeIdleTelemetry(for: newBridge)
        persistBridges()
        return newBridge
    }

    @discardableResult
    public func duplicateBridge(id: UUID) -> AudioBridgeConfiguration? {
        guard let original = bridge(for: id) else { return nil }
        let copy = AudioBridgeConfiguration(
            name: "\(original.name) Copy",
            sourceDeviceUID: original.sourceDeviceUID,
            sourceDeviceName: original.sourceDeviceName,
            destinationDeviceUID: original.destinationDeviceUID,
            destinationDeviceName: original.destinationDeviceName,
            processTarget: original.processTarget,
            routes: original.routes.map { r in
                ChannelRoute(
                    label: r.label,
                    isEnabled: r.isEnabled,
                    sourceChannel: r.sourceChannel,
                    destinationChannel: r.destinationChannel
                )
            }
        )
        bridges.append(copy)
        telemetryByBridgeID[copy.id] = makeIdleTelemetry(for: copy)
        persistBridges()
        return copy
    }

    public func removeBridge(id: UUID) {
        stopBridge(id: id)
        runtimes.removeValue(forKey: id)
        telemetryByBridgeID.removeValue(forKey: id)
        bridges.removeAll { $0.id == id }
        persistBridges()
    }

    /// Updates a bridge configuration, pushing route edits lock-free if running
    /// or cleanly rebuilding only when structural audio settings change.
    public func updateBridge(_ updated: AudioBridgeConfiguration) {
        guard let idx = bridges.firstIndex(where: { $0.id == updated.id }) else { return }
        let previous = bridges[idx]
        guard previous != updated else { return }

        var normalized = updated
        if let src = availableDevices.first(where: { $0.uid == updated.sourceDeviceUID }) {
            normalized.sourceDeviceName = src.name
        }
        if let dst = availableDevices.first(where: { $0.uid == updated.destinationDeviceUID }) {
            normalized.destinationDeviceName = dst.name
        }
        bridges[idx] = normalized
        persistBridges()

        let structuralChange =
            previous.sourceDeviceUID != normalized.sourceDeviceUID ||
            previous.destinationDeviceUID != normalized.destinationDeviceUID ||
            previous.processTarget != normalized.processTarget

        guard let runtime = runtimes[normalized.id], runtime.desiredActive else {
            let currentState = telemetry(for: normalized.id).state
            let shouldResetToIdle: Bool = {
                switch currentState {
                case .idle:
                    return true
                case .error:
                    return structuralChange
                default:
                    return false
                }
            }()

            if shouldResetToIdle {
                telemetryByBridgeID[normalized.id] = makeIdleTelemetry(for: normalized)
            } else {
                var t = telemetry(for: normalized.id)
                t.activeRouteCount = normalized.routes.filter(\.isEnabled).count
                telemetryByBridgeID[normalized.id] = t
            }
            return
        }

        if structuralChange {
            restartBridge(id: normalized.id)
            return
        }

        // Route-only change: check whether tapped source stream indices changed.
        if let source = sourceDevice(for: normalized) {
            let neededStreams = source.requiredStreamIndices(
                forLogicalChannels: normalized.routes.filter(\.isEnabled).map(\.sourceChannel)
            )
            if neededStreams != runtime.activeTappedStreams {
                restartBridge(id: normalized.id)
            } else {
                runtime.tapBridge.updateLiveRoutes(normalized.routes)
                var t = telemetry(for: normalized.id)
                t.activeRouteCount = normalized.routes.filter(\.isEnabled).count
                telemetryByBridgeID[normalized.id] = t
            }
        } else {
            var t = telemetry(for: normalized.id)
            t.activeRouteCount = normalized.routes.filter(\.isEnabled).count
            telemetryByBridgeID[normalized.id] = t
        }
    }

    // MARK: - Bridge Lifecycle

    /// Computes a non-wrapping XRun delta against the last logged baseline (guards against counter resets).
    public nonisolated static func xrunDelta(current: UInt64, lastLogged: UInt64) -> UInt64 {
        current >= lastLogged ? (current - lastLogged) : current
    }

    /// Formats coalesced underrun/overrun deltas from one monitor tick into a diagnostic message.
    public nonisolated static func formatXRunEventMessage(
        underrunDelta: UInt64,
        overrunDelta: UInt64,
        totalXRuns: UInt64
    ) -> String? {
        switch (underrunDelta, overrunDelta) {
        case (0, 0):
            return nil
        case (let underruns, 0):
            return "Buffer underrun (+\(underruns), total \(totalXRuns)) — source stream stalled"
        case (0, let overruns):
            return "Buffer overrun (+\(overruns), total \(totalXRuns)) — monitor output stalled"
        case (let underruns, let overruns):
            return "Buffer underrun (+\(underruns)) and overrun (+\(overruns)) (total \(totalXRuns))"
        }
    }

    public func startBridge(id: UUID) {
        guard let config = bridge(for: id) else { return }
        let runtime = ensureRuntime(for: id)
        runtime.desiredActive = true
        refreshDevices()

        guard let source = sourceDevice(for: config) else {
            transitionToWaitingForOfflineDevice(
                id: id,
                config: config,
                role: .source,
                deviceName: config.sourceDeviceName ?? "Source Interface"
            )
            return
        }
        guard let destination = destinationDevice(for: config) else {
            transitionToWaitingForOfflineDevice(
                id: id,
                config: config,
                role: .destination,
                deviceName: config.destinationDeviceName ?? "Monitor Interface"
            )
            return
        }

        if telemetry(for: id).state.isRunning {
            flushPendingXRunEvents(forBridgeID: id, runtime: runtime)
        }
        runtime.lastLoggedUnderruns = 0
        runtime.lastLoggedOverruns = 0

        var startingTelemetry = telemetry(for: id)
        startingTelemetry.state = .starting
        telemetryByBridgeID[id] = startingTelemetry

        let selfProcessID = catalog.currentAppProcessObjectID()

        do {
            let info = try runtime.tapBridge.start(
                sourceDevice: source,
                destinationDevice: destination,
                processTarget: config.processTarget,
                routes: config.routes,
                preferredBufferFrames: preferredBufferFrames,
                driftBufferProfile: driftBufferProfile,
                selfProcessObjectID: selfProcessID,
                onDeviceInvalidated: { [weak self] role in
                    Task { @MainActor [weak self] in
                        self?.handleActiveDeviceDisconnected(bridgeID: id, role: role)
                    }
                },
                onFormatChanged: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.scheduleFormatRebuild(bridgeID: id)
                    }
                }
            )

            runtime.lastLoggedUnderruns = 0
            runtime.lastLoggedOverruns = 0
            runtime.activeTappedStreams = info.tappedStreamIndices
            setPersistedActiveState(true, forBridgeID: id)
            let startedTelemetry = EngineTelemetry(
                state: .running,
                sourceSampleRate: info.sourceSampleRate,
                destinationSampleRate: info.destinationSampleRate,
                bufferFrames: info.bufferFrames,
                estimatedLatencyMs: info.estimatedLatencyMs,
                driftCompensationActive: true,
                driftCompensationQuality: UInt32(kAudioAggregateDriftCompensationMaxQuality),
                xrunCount: 0,
                isSourceExclusive: false,
                tappedStreamCount: info.tappedStreamIndices.count,
                activeRouteCount: config.routes.filter(\.isEnabled).count,
                activeOutputChannelCount: info.destinationOutputChannels
            )
            telemetryByBridgeID[id] = startedTelemetry
            let rateSummary = startedTelemetry.isSampleRateConverted
                ? "\(AudioDeviceDescriptor.formatSampleRate(info.sourceSampleRate)) → \(AudioDeviceDescriptor.formatSampleRate(info.destinationSampleRate))"
                : AudioDeviceDescriptor.formatSampleRate(info.destinationSampleRate)
            let pathSummary = startedTelemetry.isSampleRateConverted ? "SRC" : "Bit-Transparent"
            let latencySummary = String(format: "%.1f ms", info.estimatedLatencyMs)
            eventLog.record(
                severity: .info,
                category: .audio,
                bridgeID: id,
                sourceName: config.name,
                message: "Started (\(source.name) → \(destination.name), \(rateSummary), \(info.bufferFrames) frames, \(latencySummary), \(pathSummary))"
            )
            syncLatencyCriticalActivity()
        } catch AudioTapBridgeError.permissionDenied {
            runtime.desiredActive = false
            runtime.lastLoggedUnderruns = 0
            runtime.lastLoggedOverruns = 0
            var t = telemetry(for: id)
            t.state = .permissionRequired
            telemetryByBridgeID[id] = t
            eventLog.record(
                severity: .error,
                category: .permission,
                bridgeID: id,
                sourceName: config.name,
                message: "System Audio Recording permission required to tap \"\(source.name)\""
            )
            syncLatencyCriticalActivity()
            logger.error("System Audio Recording permission denied for bridge \(config.name).")
        } catch {
            runtime.desiredActive = false
            runtime.lastLoggedUnderruns = 0
            runtime.lastLoggedOverruns = 0
            var t = telemetry(for: id)
            t.state = .error(error.localizedDescription)
            telemetryByBridgeID[id] = t
            eventLog.record(
                severity: .error,
                category: .audio,
                bridgeID: id,
                sourceName: config.name,
                message: "Failed to start bridge: \(error.localizedDescription)"
            )
            syncLatencyCriticalActivity()
            logger.error("Failed to start bridge \(config.name): \(error.localizedDescription)")
        }
    }

    public func stopBridge(id: UUID) {
        let wasActiveOrPending = isBridgeActiveOrPending(id)
        let bridgeName = bridge(for: id)?.name
        teardownBridge(id: id)
        setPersistedActiveState(false, forBridgeID: id)
        if wasActiveOrPending, let bridgeName {
            eventLog.record(
                severity: .info,
                category: .audio,
                bridgeID: id,
                sourceName: bridgeName,
                message: "Bridge stopped"
            )
        }
        syncLatencyCriticalActivity()
    }

    public func toggleBridge(id: UUID) {
        if isBridgeActiveOrPending(id) {
            stopBridge(id: id)
        } else {
            startBridge(id: id)
        }
    }

    public func stopAll() {
        for bridge in bridges {
            stopBridge(id: bridge.id)
        }
    }

    /// Restores any virtual bridges that were active before the previous app quit or update relaunch.
    public func restoreActiveBridges() {
        let activeIDs = bridges.filter(\.wasActive).map(\.id)
        guard !activeIDs.isEmpty else { return }
        let restorableBridges = activeIDs.compactMap { id -> AudioBridgeConfiguration? in
            guard !isBridgeActiveOrPending(id),
                  let config = bridge(for: id),
                  config.sourceDeviceUID != nil,
                  config.destinationDeviceUID != nil,
                  config.routes.contains(where: \.isEnabled) else {
                return nil
            }
            return config
        }
        guard !restorableBridges.isEmpty else { return }
        let count = restorableBridges.count
        let summary = count == 1 ? "1 active bridge" : "\(count) active bridges"
        eventLog.record(
            severity: .info,
            category: .system,
            sourceName: "System",
            message: "Restoring \(summary) on launch"
        )
        for config in restorableBridges {
            logger.info("Restoring previously active bridge \(config.name).")
            startBridge(id: config.id)
        }
    }

    /// Resolves the 0-based tap input channel index corresponding to a 1-based logical source channel.
    public func tapChannelIndex(forSourceChannel sourceChannel: Int, inBridgeID id: UUID) -> Int? {
        runtimes[id]?.tapBridge.activeInfo?.logicalSourceToTapChannel[sourceChannel]
    }

    /// Zero-allocation single-channel meter read for a running bridge's 1-based logical source channel.
    public func consumeSourceChannelLevel(sourceChannel: Int, inBridgeID id: UUID) -> ChannelMeterLevel {
        guard let runtime = runtimes[id],
              let info = runtime.tapBridge.activeInfo,
              let tapIdx = info.logicalSourceToTapChannel[sourceChannel] else {
            return .silent
        }
        return runtime.tapBridge.processor.meterBank.consumeInputLevel(channel: tapIdx)
    }

    /// Synchronizes XRun counts from running bridges into observable telemetry only when changed.
    public func syncXRunCounts() {
        for (id, runtime) in runtimes where telemetryByBridgeID[id]?.state.isRunning == true {
            let currentXRuns = runtime.tapBridge.processor.meterBank.xrunCount
            if var t = telemetryByBridgeID[id], t.xrunCount != currentXRuns {
                t.xrunCount = currentXRuns
                telemetryByBridgeID[id] = t
            }
        }
    }

    /// Clears all latched clip indicators for a given bridge.
    public func resetClips(forBridgeID id: UUID) {
        runtimes[id]?.tapBridge.processor.meterBank.resetClips()
    }

    /// Consumes per-channel input activity snapshot for a running bridge (for subtle live indicators).
    public func consumeActivitySnapshot(forBridgeID id: UUID) -> MeterFrameSnapshot {
        guard let runtime = runtimes[id], let info = runtime.tapBridge.activeInfo else {
            return MeterFrameSnapshot()
        }
        let snap = runtime.tapBridge.processor.meterBank.consumeSnapshot(
            inputChannelCount: info.tappedInputChannels,
            outputChannelCount: 0
        )
        if var t = telemetryByBridgeID[id], t.xrunCount != snap.xrunCount {
            t.xrunCount = snap.xrunCount
            telemetryByBridgeID[id] = t
        }
        return snap
    }

    /// Releases all Core Audio resources synchronously during app termination or update relaunch,
    /// preserving each bridge's persisted `wasActive` state so active bridges can be restored on next launch.
    public func shutdown() {
        stopXRunMonitorLoop()
        pendingDeviceRefreshTask?.cancel()
        pendingDeviceRefreshTask = nil
        pendingProcessRefreshTask?.cancel()
        pendingProcessRefreshTask = nil
        catalog.stopObserving()
        for bridge in bridges {
            teardownBridge(id: bridge.id)
        }
        syncLatencyCriticalActivity()
    }

    // MARK: - Internal Coordination

    private func transitionToWaitingForOfflineDevice(
        id: UUID,
        config: AudioBridgeConfiguration,
        role: DeviceRole,
        deviceName: String
    ) {
        setPersistedActiveState(true, forBridgeID: id)
        let targetState = EngineState.waitingForDevice(role: role, deviceName: deviceName)
        var t = telemetry(for: id)
        let wasAlreadyWaiting = t.state == targetState
        t.state = targetState
        telemetryByBridgeID[id] = t
        if !wasAlreadyWaiting {
            let roleLabel = role == .source ? "source" : "monitor"
            eventLog.record(
                severity: .warning,
                category: .device,
                bridgeID: id,
                sourceName: config.name,
                message: "Waiting for offline \(roleLabel) interface \"\(deviceName)\""
            )
        }
        syncLatencyCriticalActivity()
    }

    private func evaluatePendingXRunEvents() {
        for (id, runtime) in runtimes where telemetryByBridgeID[id]?.state.isRunning == true {
            flushPendingXRunEvents(forBridgeID: id, runtime: runtime)
        }
    }

    private func flushPendingXRunEvents(forBridgeID id: UUID, runtime: BridgeRuntime) {
        let meterBank = runtime.tapBridge.processor.meterBank
        let currentUnderruns = meterBank.underrunCount
        let currentOverruns = meterBank.overrunCount
        let currentTotal = meterBank.xrunCount

        let underrunDelta = Self.xrunDelta(current: currentUnderruns, lastLogged: runtime.lastLoggedUnderruns)
        let overrunDelta = Self.xrunDelta(current: currentOverruns, lastLogged: runtime.lastLoggedOverruns)

        runtime.lastLoggedUnderruns = currentUnderruns
        runtime.lastLoggedOverruns = currentOverruns

        if var t = telemetryByBridgeID[id], t.xrunCount != currentTotal {
            t.xrunCount = currentTotal
            telemetryByBridgeID[id] = t
        }

        if let message = Self.formatXRunEventMessage(
            underrunDelta: underrunDelta,
            overrunDelta: overrunDelta,
            totalXRuns: currentTotal
        ) {
            let sourceName = bridge(for: id)?.name ?? "Bridge"
            eventLog.record(
                severity: .warning,
                category: .audio,
                bridgeID: id,
                sourceName: sourceName,
                message: message
            )
        }
    }

    private func stopTapAndResetXRunBaseline(forBridgeID id: UUID, runtime: BridgeRuntime) {
        if telemetryByBridgeID[id]?.state.isRunning == true {
            flushPendingXRunEvents(forBridgeID: id, runtime: runtime)
        }
        runtime.tapBridge.stop()
        runtime.lastLoggedUnderruns = 0
        runtime.lastLoggedOverruns = 0
    }

    private func teardownBridge(id: UUID) {
        if let runtime = runtimes[id] {
            runtime.desiredActive = false
            runtime.pendingRebuildTask?.cancel()
            runtime.pendingRebuildTask = nil
            stopTapAndResetXRunBaseline(forBridgeID: id, runtime: runtime)
            runtime.activeTappedStreams = []
        }

        telemetryByBridgeID[id] = makeIdleTelemetry(for: bridge(for: id))
    }

    private func setPersistedActiveState(_ isActive: Bool, forBridgeID id: UUID) {
        guard let idx = bridges.firstIndex(where: { $0.id == id }),
              bridges[idx].wasActive != isActive else { return }
        bridges[idx].wasActive = isActive
        persistBridges()
    }

    /// Keeps macOS from applying App Nap, timer coalescing, or Efficiency-core throttling
    /// while Interceptor is running active audio bridges (especially when hidden in the Menu Bar),
    /// and maintains a 1 Hz background XRun monitor while any bridge is running.
    private func syncLatencyCriticalActivity() {
        let shouldHoldAssertion = anyBridgeActiveOrPending
        if shouldHoldAssertion && latencyActivityToken == nil {
            latencyActivityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Active real-time Core Audio passive monitoring bridge"
            )
            logger.info("Acquired latency-critical ProcessInfo activity assertion.")
        } else if !shouldHoldAssertion, let token = latencyActivityToken {
            ProcessInfo.processInfo.endActivity(token)
            latencyActivityToken = nil
            logger.info("Released latency-critical ProcessInfo activity assertion.")
        }

        if anyBridgeRunning {
            startXRunMonitorLoop()
        } else {
            stopXRunMonitorLoop()
        }
    }

    private func startXRunMonitorLoop() {
        guard xrunMonitorTask == nil else { return }
        xrunMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { break }
                guard self.anyBridgeRunning else {
                    self.xrunMonitorTask = nil
                    break
                }
                self.syncXRunCounts()
                self.evaluatePendingXRunEvents()
            }
        }
    }

    private func stopXRunMonitorLoop() {
        xrunMonitorTask?.cancel()
        xrunMonitorTask = nil
    }

    private func scheduleDebouncedDeviceTopologyChange() {
        pendingDeviceRefreshTask?.cancel()
        pendingDeviceRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.handleTopologyChange()
        }
    }

    private func scheduleDebouncedProcessRefresh() {
        pendingProcessRefreshTask?.cancel()
        pendingProcessRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.refreshProcesses()
        }
    }

    private func makeIdleTelemetry(for config: AudioBridgeConfiguration?) -> EngineTelemetry {
        let src = config.flatMap { sourceDevice(for: $0) }
        let dst = config.flatMap { destinationDevice(for: $0) }
        return EngineTelemetry(
            state: .idle,
            sourceSampleRate: src?.nominalSampleRate ?? 0,
            destinationSampleRate: dst?.nominalSampleRate ?? 0,
            bufferFrames: dst?.bufferFrameSize ?? 0,
            estimatedLatencyMs: 0,
            driftCompensationActive: false,
            driftCompensationQuality: UInt32(kAudioAggregateDriftCompensationMaxQuality),
            xrunCount: 0,
            isSourceExclusive: false,
            tappedStreamCount: 0,
            activeRouteCount: config?.routes.filter(\.isEnabled).count ?? 0,
            activeOutputChannelCount: dst?.totalOutputChannels ?? 0
        )
    }

    private func ensureRuntime(for id: UUID) -> BridgeRuntime {
        if let existing = runtimes[id] { return existing }
        let created = BridgeRuntime()
        runtimes[id] = created
        return created
    }

    private func loadOrCreateInitialBridges() {
        let loaded = store.loadBridges()
        if !loaded.isEmpty {
            bridges = loaded
            refreshDevices()
            for b in bridges {
                telemetryByBridgeID[b.id] = makeIdleTelemetry(for: b)
            }
        } else {
            _ = addBridge(name: "Main Monitor")
        }
    }

    private func sensibleDefaultDevices() -> (source: AudioDeviceDescriptor?, destination: AudioDeviceDescriptor?) {
        guard !availableDevices.isEmpty else { return (nil, nil) }
        let src = availableDevices.first(where: { $0.totalOutputChannels > 2 }) ?? availableDevices.first
        let dst = availableDevices.first(where: { $0.uid != src?.uid && $0.transportType == .builtIn })
            ?? availableDevices.first(where: { $0.uid != src?.uid })
            ?? availableDevices.first
        return (src, dst)
    }

    private func defaultBridgeName() -> String {
        let base = "Monitor Bridge"
        let existing = Set(bridges.map(\.name))
        if !existing.contains(base) { return base }
        var index = 2
        while existing.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    private func persistBridges() {
        do {
            try store.saveBridges(bridges)
        } catch {
            logger.error("Failed to save bridges: \(error.localizedDescription)")
        }
    }

    private func restartBridge(id: UUID) {
        guard let runtime = runtimes[id], runtime.desiredActive else { return }
        stopTapAndResetXRunBaseline(forBridgeID: id, runtime: runtime)
        startBridge(id: id)
    }

    private func handleActiveDeviceDisconnected(bridgeID: UUID, role: DeviceRole) {
        guard let config = bridge(for: bridgeID), let runtime = runtimes[bridgeID] else { return }
        logger.warning("Active \(role.rawValue) interface disconnected on bridge \(config.name).")
        runtime.pendingRebuildTask?.cancel()
        runtime.pendingRebuildTask = nil
        stopTapAndResetXRunBaseline(forBridgeID: bridgeID, runtime: runtime)
        refreshDevices()

        let deviceName = role == .source
            ? (config.sourceDeviceName ?? "Source Interface")
            : (config.destinationDeviceName ?? "Monitor Interface")
        let roleLabel = role == .source ? "Source" : "Monitor"
        let willAutoReconnect = autoReconnectEnabled && runtime.desiredActive
        let reconnectSuffix = willAutoReconnect ? " — waiting to reconnect" : ""
        eventLog.record(
            severity: .warning,
            category: .device,
            bridgeID: bridgeID,
            sourceName: config.name,
            message: "\(roleLabel) interface \"\(deviceName)\" disconnected\(reconnectSuffix)"
        )

        if willAutoReconnect {
            var t = telemetry(for: bridgeID)
            t.state = .waitingForDevice(role: role, deviceName: deviceName)
            telemetryByBridgeID[bridgeID] = t
            syncLatencyCriticalActivity()
        } else {
            runtime.desiredActive = false
            stopBridge(id: bridgeID)
        }
    }

    private func scheduleFormatRebuild(bridgeID: UUID) {
        guard let runtime = runtimes[bridgeID], runtime.desiredActive else { return }
        runtime.pendingRebuildTask?.cancel()
        runtime.pendingRebuildTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self, self.runtimes[bridgeID]?.desiredActive == true else { return }
            self.logger.info("Audio device format change detected; refreshing passive bridge.")
            if let config = self.bridge(for: bridgeID) {
                self.eventLog.record(
                    severity: .warning,
                    category: .clock,
                    bridgeID: bridgeID,
                    sourceName: config.name,
                    message: "Audio format or sample rate changed — rebuilding bridge"
                )
            }
            self.refreshDevices()
            self.restartBridge(id: bridgeID)
        }
    }

    private func handleTopologyChange() {
        refreshDevices()

        for config in bridges {
            guard let runtime = runtimes[config.id], runtime.desiredActive else { continue }
            let state = telemetry(for: config.id).state
            switch state {
            case .waitingForDevice:
                if autoReconnectEnabled && sourceDevice(for: config) != nil && destinationDevice(for: config) != nil {
                    logger.info("Interface returned for bridge \(config.name); auto-reconnecting.")
                    eventLog.record(
                        severity: .info,
                        category: .device,
                        bridgeID: config.id,
                        sourceName: config.name,
                        message: "Audio interface returned — auto-reconnecting bridge"
                    )
                    startBridge(id: config.id)
                }
            case .running:
                if sourceDevice(for: config) == nil {
                    handleActiveDeviceDisconnected(bridgeID: config.id, role: .source)
                } else if destinationDevice(for: config) == nil {
                    handleActiveDeviceDisconnected(bridgeID: config.id, role: .destination)
                }
            default:
                break
            }
        }
    }

    private func handleCoreAudioRestarted() {
        logger.warning("coreaudiod restarted; recovering active bridges.")
        let activeIDs = bridges.map(\.id).filter { runtimes[$0]?.desiredActive == true }

        let restartMessage: String = activeIDs.isEmpty
            ? "macOS audio daemon (coreaudiod) restarted"
            : "macOS audio daemon (coreaudiod) restarted — recovering \(activeIDs.count) \(activeIDs.count == 1 ? "bridge" : "bridges")"
        eventLog.record(
            severity: .warning,
            category: .system,
            sourceName: "System",
            message: restartMessage
        )

        guard autoReconnectEnabled else {
            for id in activeIDs {
                stopBridge(id: id)
            }
            return
        }

        for id in activeIDs {
            if let runtime = runtimes[id] {
                stopTapAndResetXRunBaseline(forBridgeID: id, runtime: runtime)
                runtime.pendingRebuildTask?.cancel()
                runtime.pendingRebuildTask = nil
            }
            var t = telemetry(for: id)
            t.state = .starting
            telemetryByBridgeID[id] = t
        }
        syncLatencyCriticalActivity()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.refreshDevices()
            guard self.autoReconnectEnabled else {
                for id in activeIDs where self.runtimes[id]?.desiredActive == true {
                    self.stopBridge(id: id)
                }
                return
            }
            for id in activeIDs where self.runtimes[id]?.desiredActive == true {
                self.startBridge(id: id)
            }
        }
    }
}
