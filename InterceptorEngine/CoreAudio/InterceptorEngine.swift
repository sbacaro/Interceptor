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
    }

    private let logger = Logger(subsystem: "com.interceptor.audio", category: "InterceptorEngine")
    private let catalog: CoreAudioDeviceCatalog
    private let store: BridgeStore

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

    /// Global optional preferred buffer frames for private monitor aggregates (`nil` = automatic).
    public var preferredBufferFrames: Int? {
        didSet {
            guard preferredBufferFrames != oldValue else { return }
            for bridge in bridges where isBridgeRunning(bridge.id) {
                restartBridge(id: bridge.id)
            }
        }
    }

    private var runtimes: [UUID: BridgeRuntime] = [:]

    public init(
        catalog: CoreAudioDeviceCatalog = CoreAudioDeviceCatalog(),
        store: BridgeStore = BridgeStore()
    ) {
        self.catalog = catalog
        self.store = store

        refreshDevices()
        loadOrCreateInitialBridges()

        catalog.startObserving(
            onTopologyChange: { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleTopologyChange()
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
        telemetryByBridgeID[newBridge.id] = EngineTelemetry(activeRouteCount: 2)
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
        telemetryByBridgeID[copy.id] = EngineTelemetry(activeRouteCount: copy.routes.filter(\.isEnabled).count)
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
            var t = telemetry(for: normalized.id)
            t.activeRouteCount = normalized.routes.filter(\.isEnabled).count
            telemetryByBridgeID[normalized.id] = t
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
        }
    }

    // MARK: - Bridge Lifecycle

    public func startBridge(id: UUID) {
        guard let config = bridge(for: id) else { return }
        let runtime = ensureRuntime(for: id)
        runtime.desiredActive = true
        refreshDevices()

        guard let source = sourceDevice(for: config) else {
            var t = telemetry(for: id)
            t.state = .waitingForDevice(role: .source, deviceName: config.sourceDeviceName ?? "Source Interface")
            telemetryByBridgeID[id] = t
            return
        }
        guard let destination = destinationDevice(for: config) else {
            var t = telemetry(for: id)
            t.state = .waitingForDevice(role: .destination, deviceName: config.destinationDeviceName ?? "Monitor Interface")
            telemetryByBridgeID[id] = t
            return
        }

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

            runtime.activeTappedStreams = info.tappedStreamIndices
            telemetryByBridgeID[id] = EngineTelemetry(
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
        } catch AudioTapBridgeError.permissionDenied {
            runtime.desiredActive = false
            var t = telemetry(for: id)
            t.state = .permissionRequired
            telemetryByBridgeID[id] = t
            logger.error("System Audio Recording permission denied for bridge \(config.name).")
        } catch {
            runtime.desiredActive = false
            var t = telemetry(for: id)
            t.state = .error(error.localizedDescription)
            telemetryByBridgeID[id] = t
            logger.error("Failed to start bridge \(config.name): \(error.localizedDescription)")
        }
    }

    public func stopBridge(id: UUID) {
        if let runtime = runtimes[id] {
            runtime.desiredActive = false
            runtime.pendingRebuildTask?.cancel()
            runtime.pendingRebuildTask = nil
            runtime.tapBridge.stop()
            runtime.activeTappedStreams = []
        }

        let config = bridge(for: id)
        let src = config.flatMap { sourceDevice(for: $0) }
        let dst = config.flatMap { destinationDevice(for: $0) }
        telemetryByBridgeID[id] = EngineTelemetry(
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

    /// Resolves the 0-based tap input channel index corresponding to a 1-based logical source channel.
    public func tapChannelIndex(forSourceChannel sourceChannel: Int, inBridgeID id: UUID) -> Int? {
        runtimes[id]?.tapBridge.activeInfo?.logicalSourceToTapChannel[sourceChannel]
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

    /// Releases all Core Audio resources synchronously during app termination.
    public func shutdown() {
        catalog.stopObserving()
        stopAll()
    }

    // MARK: - Internal Coordination

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
            for b in bridges {
                telemetryByBridgeID[b.id] = EngineTelemetry(activeRouteCount: b.routes.filter(\.isEnabled).count)
            }
            refreshDevices()
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
        runtime.tapBridge.stop()
        startBridge(id: id)
    }

    private func handleActiveDeviceDisconnected(bridgeID: UUID, role: DeviceRole) {
        guard let config = bridge(for: bridgeID), let runtime = runtimes[bridgeID] else { return }
        logger.warning("Active \(role.rawValue) interface disconnected on bridge \(config.name).")
        runtime.tapBridge.stop()
        refreshDevices()

        if autoReconnectEnabled && runtime.desiredActive {
            let name = role == .source
                ? (config.sourceDeviceName ?? "Source Interface")
                : (config.destinationDeviceName ?? "Monitor Interface")
            var t = telemetry(for: bridgeID)
            t.state = .waitingForDevice(role: role, deviceName: name)
            telemetryByBridgeID[bridgeID] = t
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
            self.logger.info("Sample rate change detected; refreshing passive bridge.")
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
        for id in activeIDs {
            runtimes[id]?.tapBridge.stop()
            runtimes[id]?.pendingRebuildTask?.cancel()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.refreshDevices()
            if self.autoReconnectEnabled {
                for id in activeIDs where self.runtimes[id]?.desiredActive == true {
                    self.startBridge(id: id)
                }
            }
        }
    }
}
