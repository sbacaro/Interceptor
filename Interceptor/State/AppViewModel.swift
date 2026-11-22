import Foundation
import InterceptorEngine
import Observation
import os
import ServiceManagement

/// Smoothed ballistic VU meter state rendered at 60 Hz per channel.
public struct SmoothedChannelMeter: Sendable, Equatable {
    public var rmsDB: Float = -60.0
    public var peakDB: Float = -60.0
    public var peakHoldDB: Float = -60.0
    public var peakHoldTimestamp: TimeInterval = 0
    public var isClipped: Bool = false

    public static let floorDB: Float = -60.0

    public init(
        rmsDB: Float = -60.0,
        peakDB: Float = -60.0,
        peakHoldDB: Float = -60.0,
        peakHoldTimestamp: TimeInterval = 0,
        isClipped: Bool = false
    ) {
        self.rmsDB = rmsDB
        self.peakDB = peakDB
        self.peakHoldDB = peakHoldDB
        self.peakHoldTimestamp = peakHoldTimestamp
        self.isClipped = isClipped
    }

    public mutating func update(
        with raw: ChannelMeterLevel,
        now: TimeInterval,
        deltaTime: Float
    ) {
        let clampedPeak = max(Self.floorDB, min(0.0, raw.peakDB))
        let clampedRMS = max(Self.floorDB, min(0.0, raw.rmsDB))

        // Gentle exponential smoothing so low-FPS visual meters move fluidly without flickering.
        let attackAlpha = min(1.0, deltaTime * 14.0)
        let releaseDecay = deltaTime * 22.0

        if clampedPeak >= peakDB {
            peakDB = peakDB + (clampedPeak - peakDB) * attackAlpha
        } else {
            peakDB = max(Self.floorDB, peakDB - releaseDecay)
        }

        if clampedRMS >= rmsDB {
            rmsDB = rmsDB + (clampedRMS - rmsDB) * attackAlpha
        } else {
            rmsDB = max(Self.floorDB, rmsDB - releaseDecay * 0.85)
        }

        if clampedPeak >= peakHoldDB || (now - peakHoldTimestamp) > 1.5 {
            if clampedPeak >= peakHoldDB {
                peakHoldDB = clampedPeak
                peakHoldTimestamp = now
            } else {
                peakHoldDB = max(peakDB, peakHoldDB - deltaTime * 14.0)
            }
        }

        isClipped = raw.isClipped
    }

    public mutating func decayToSilence(deltaTime: Float) {
        let decay = deltaTime * 36.0
        peakDB = max(Self.floorDB, peakDB - decay)
        rmsDB = max(Self.floorDB, rmsDB - decay)
        peakHoldDB = max(Self.floorDB, peakHoldDB - decay)
        isClipped = false
    }

    public var isSilent: Bool {
        peakDB <= Self.floorDB + 0.05 &&
            rmsDB <= Self.floorDB + 0.05 &&
            peakHoldDB <= Self.floorDB + 0.05 &&
            !isClipped
    }

    public func isVisiblyDifferent(from other: SmoothedChannelMeter) -> Bool {
        abs(peakDB - other.peakDB) > 0.3 ||
            abs(rmsDB - other.rmsDB) > 0.3 ||
            abs(peakHoldDB - other.peakHoldDB) > 0.3 ||
            isClipped != other.isClipped
    }
}

/// Non-observable GPU meter bridge: pushes smoothed levels directly to `CoreAnimationVUMeterNSView`'s
/// `CALayer`s without triggering a single SwiftUI view diff or body evaluation.
@MainActor
public final class RouteMeterModel {
    public private(set) var level: SmoothedChannelMeter
    private var renderer: (@MainActor (SmoothedChannelMeter) -> Void)?

    public init(level: SmoothedChannelMeter = SmoothedChannelMeter()) {
        self.level = level
    }

    public func attachRenderer(_ renderer: @escaping @MainActor (SmoothedChannelMeter) -> Void) {
        self.renderer = renderer
    }

    public func detachRenderer() {
        self.renderer = nil
    }

    public func push(_ newLevel: SmoothedChannelMeter) {
        level = newLevel
        renderer?(newLevel)
    }
}

/// Primary `@MainActor` observable view model coordinating virtual routing bridges,
/// preferences, and 60 Hz per-channel VU metering.
@MainActor
@Observable
public final class AppViewModel {
    private enum DefaultsKey {
        static let autoReconnect = "com.interceptor.pref.autoReconnect"
        static let restoreActiveBridgesOnLaunch = "com.interceptor.pref.restoreActiveBridgesOnLaunch"
        static let preferredBufferFrames = "com.interceptor.pref.preferredBufferFrames"
        static let driftBufferProfile = "com.interceptor.pref.driftBufferProfile"
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.interceptor.audio", category: "AppViewModel")
    public let engine: InterceptorEngine
    public let updater: GitHubReleaseUpdater

    /// Currently selected virtual routing bridge in the sidebar.
    public var selectedBridgeID: UUID?

    /// Controls the on-demand Bridge Info popover (`⌘I`).
    public var isBridgeInfoPresented: Bool = false

    /// Controls the in-window Settings sheet (`⌘,`).
    public var isSettingsPresented: Bool = false

    // MARK: - User Preferences

    public var autoReconnectEnabled: Bool {
        didSet {
            defaults.set(autoReconnectEnabled, forKey: DefaultsKey.autoReconnect)
            engine.autoReconnectEnabled = autoReconnectEnabled
        }
    }

    public var restoreActiveBridgesOnLaunch: Bool {
        didSet {
            defaults.set(restoreActiveBridgesOnLaunch, forKey: DefaultsKey.restoreActiveBridgesOnLaunch)
        }
    }

    /// `0` means Automatic (use destination device default buffer size).
    public var preferredBufferFramesSetting: Int {
        didSet {
            defaults.set(preferredBufferFramesSetting, forKey: DefaultsKey.preferredBufferFrames)
            engine.preferredBufferFrames = preferredBufferFramesSetting > 0 ? preferredBufferFramesSetting : nil
        }
    }

    /// Safety headroom profile for the decoupled drift-compensating ring buffer.
    public var driftBufferProfile: DriftBufferProfile {
        didSet {
            defaults.set(driftBufferProfile.rawValue, forKey: DefaultsKey.driftBufferProfile)
            engine.driftBufferProfile = driftBufferProfile
        }
    }

    // MARK: - Launch at Login (SMAppService)

    /// Reflects whether Interceptor is registered to open automatically at macOS login.
    public private(set) var launchAtLoginEnabled: Bool = false

    /// True when macOS Login Items requires explicit user approval in System Settings.
    public private(set) var launchAtLoginNeedsApproval: Bool = false

    /// Optional non-fatal message if login item registration could not be updated.
    public private(set) var launchAtLoginErrorMessage: String?

    // MARK: - Live Per-Channel Meters (Isolated 30 Hz, Visible Window Only)

    /// Stored outside `@Observable` tracking so meter ticks never invalidate list/row/picker views.
    @ObservationIgnored
    private var routeMeterModels: [UUID: RouteMeterModel] = [:]

    @ObservationIgnored
    private var isMainWindowVisible: Bool = false

    @ObservationIgnored
    private var meterTask: Task<Void, Never>?

    public init(
        engine: InterceptorEngine = InterceptorEngine(),
        updater: GitHubReleaseUpdater = GitHubReleaseUpdater(),
        defaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.updater = updater
        self.defaults = defaults

        defaults.register(defaults: [
            DefaultsKey.autoReconnect: true,
            DefaultsKey.restoreActiveBridgesOnLaunch: true,
            DefaultsKey.preferredBufferFrames: 0,
            DefaultsKey.driftBufferProfile: DriftBufferProfile.balanced.rawValue
        ])

        let savedAutoReconnect = defaults.bool(forKey: DefaultsKey.autoReconnect)
        let savedRestoreActive = defaults.bool(forKey: DefaultsKey.restoreActiveBridgesOnLaunch)
        let savedBuffer = defaults.integer(forKey: DefaultsKey.preferredBufferFrames)
        let savedProfile = DriftBufferProfile(
            rawValue: defaults.string(forKey: DefaultsKey.driftBufferProfile) ?? ""
        ) ?? .balanced

        self.autoReconnectEnabled = savedAutoReconnect
        self.restoreActiveBridgesOnLaunch = savedRestoreActive
        self.preferredBufferFramesSetting = savedBuffer
        self.driftBufferProfile = savedProfile

        engine.autoReconnectEnabled = savedAutoReconnect
        engine.preferredBufferFrames = savedBuffer > 0 ? savedBuffer : nil
        engine.driftBufferProfile = savedProfile

        self.selectedBridgeID = engine.bridges.first?.id
        refreshLaunchAtLoginStatus()

        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if savedRestoreActive && !isPreview {
            Task { @MainActor [weak self] in
                self?.engine.restoreActiveBridges()
            }
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.updater.checkAutomaticallyIfNeeded()
        }
    }

    // MARK: - Selected Bridge Convenience

    public var selectedBridge: AudioBridgeConfiguration? {
        if let id = selectedBridgeID, let found = engine.bridge(for: id) {
            return found
        }
        return engine.bridges.first
    }

    public var selectedBridgeTelemetry: EngineTelemetry {
        guard let id = selectedBridge?.id else { return EngineTelemetry() }
        return engine.telemetry(for: id)
    }

    // MARK: - Virtual Bridge Actions

    public func addBridge() {
        let created = engine.addBridge()
        selectedBridgeID = created.id
    }

    public func duplicateBridge(id: UUID) {
        if let copy = engine.duplicateBridge(id: id) {
            selectedBridgeID = copy.id
        }
    }

    public func removeBridge(id: UUID) {
        let previousIndex = engine.bridges.firstIndex(where: { $0.id == id })
        if let removed = engine.bridge(for: id) {
            for route in removed.routes {
                routeMeterModels.removeValue(forKey: route.id)
            }
        }
        engine.removeBridge(id: id)
        if selectedBridgeID == id {
            if let idx = previousIndex, !engine.bridges.isEmpty {
                selectedBridgeID = engine.bridges[min(idx, engine.bridges.count - 1)].id
            } else {
                selectedBridgeID = engine.bridges.first?.id
            }
        }
    }

    public func renameBridge(id: UUID, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var config = engine.bridge(for: id) else { return }
        config.name = trimmed
        engine.updateBridge(config)
    }

    public func updateBridge(id: UUID, _ mutate: (inout AudioBridgeConfiguration) -> Void) {
        guard var config = engine.bridge(for: id) else { return }
        mutate(&config)
        engine.updateBridge(config)
    }

    public func updateSelectedBridge(_ mutate: (inout AudioBridgeConfiguration) -> Void) {
        guard let id = selectedBridge?.id else { return }
        updateBridge(id: id, mutate)
    }

    public func toggleSelectedBridge() {
        guard let id = selectedBridge?.id else { return }
        toggleBridge(id: id)
    }

    public func toggleBridge(id: UUID) {
        let wasActive = engine.isBridgeActiveOrPending(id)
        engine.toggleBridge(id: id)
        if wasActive && (!isMainWindowVisible || selectedBridge?.id != id) {
            resetRouteMeters(forBridgeID: id)
        }
    }

    public func stopAllBridges() {
        engine.stopAll()
        let activeSelectedID = selectedBridge?.id
        for bridge in engine.bridges where !isMainWindowVisible || bridge.id != activeSelectedID {
            resetRouteMeters(forBridgeID: bridge.id)
        }
    }

    public func resetClips(forBridgeID id: UUID) {
        engine.resetClips(forBridgeID: id)
    }

    public func resetClipsForSelectedBridge() {
        guard let id = selectedBridge?.id else { return }
        resetClips(forBridgeID: id)
    }

    public func refreshDevices() {
        engine.refreshDevices()
    }

    public func openAudioCaptureSettings() {
        AudioCapturePermission.openSystemSettings()
    }

    public func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            launchAtLoginEnabled = true
            launchAtLoginNeedsApproval = false
        case .requiresApproval:
            launchAtLoginEnabled = true
            launchAtLoginNeedsApproval = true
        case .notRegistered, .notFound:
            launchAtLoginEnabled = false
            launchAtLoginNeedsApproval = false
        @unknown default:
            launchAtLoginEnabled = false
            launchAtLoginNeedsApproval = false
        }
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginErrorMessage = nil
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            logger.error("Failed to update Launch at Login (\(enabled)): \(error.localizedDescription)")
            launchAtLoginErrorMessage = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    public func checkForUpdates() {
        updater.checkForUpdates(userInitiated: true)
    }

    public func installAvailableUpdate(_ update: AvailableUpdate) {
        isSettingsPresented = false
        isBridgeInfoPresented = false
        updater.installUpdate(update) { [weak self] in
            self?.shutdown()
        }
    }

    // MARK: - Mono Channel Editing inside Bridges

    public func addChannel(toBridgeID id: UUID) {
        updateBridge(id: id) { config in
            let maxSrc = engine.sourceDevice(for: config)?.maxLogicalOutputChannel ?? 64
            let maxDst = engine.destinationDevice(for: config)?.totalOutputChannels ?? 2

            let nextSrc: Int
            let nextDst: Int
            if let last = config.routes.last {
                nextSrc = last.sourceChannel < maxSrc ? last.sourceChannel + 1 : 1
                nextDst = last.destinationChannel < maxDst ? last.destinationChannel + 1 : 1
            } else {
                nextSrc = 1
                nextDst = 1
            }

            let existingLabels = Set(config.routes.map(\.label))
            var labelNumber = 1
            while existingLabels.contains("Channel \(labelNumber)") {
                labelNumber += 1
            }

            config.routes.append(
                ChannelRoute(
                    label: "Channel \(labelNumber)",
                    isEnabled: true,
                    sourceChannel: max(1, min(nextSrc, maxSrc)),
                    destinationChannel: max(1, min(nextDst, maxDst))
                )
            )
        }
    }

    public func addChannelToSelectedBridge() {
        guard let id = selectedBridge?.id else { return }
        addChannel(toBridgeID: id)
    }

    public func updateRoute(_ updated: ChannelRoute, inBridgeID id: UUID) {
        updateBridge(id: id) { config in
            guard let idx = config.routes.firstIndex(where: { $0.id == updated.id }) else { return }
            config.routes[idx] = updated
        }
    }

    public func updateRouteInSelectedBridge(_ updated: ChannelRoute) {
        guard let id = selectedBridge?.id else { return }
        updateRoute(updated, inBridgeID: id)
    }

    public func removeRoute(routeID: UUID, fromBridgeID id: UUID) {
        routeMeterModels.removeValue(forKey: routeID)
        updateBridge(id: id) { config in
            config.routes.removeAll { $0.id == routeID }
        }
    }

    public func removeRouteFromSelectedBridge(routeID: UUID) {
        guard let id = selectedBridge?.id else { return }
        removeRoute(routeID: routeID, fromBridgeID: id)
    }

    // MARK: - Isolated Metering Lookup & Visibility Lifecycle

    /// Returns a stable per-route observable meter holder without creating an `@Observable` dependency on `AppViewModel`.
    public func meterModel(for routeID: UUID) -> RouteMeterModel {
        if let existing = routeMeterModels[routeID] {
            return existing
        }
        let created = RouteMeterModel()
        routeMeterModels[routeID] = created
        return created
    }

    /// Starts or completely suspends UI meter polling based on whether the main window is actually visible on screen.
    public func setMainWindowVisible(_ visible: Bool) {
        guard isMainWindowVisible != visible else { return }
        isMainWindowVisible = visible
        if visible {
            startMeterLoop()
        } else {
            stopMeterLoop()
        }
    }

    public func shutdown() {
        stopMeterLoop()
        engine.shutdown()
    }

    private func resetRouteMeters(forBridgeID id: UUID) {
        guard let config = engine.bridge(for: id) else { return }
        for route in config.routes {
            if let model = routeMeterModels[route.id], !model.level.isSilent {
                model.push(SmoothedChannelMeter())
            }
        }
    }

    private func stopMeterLoop() {
        meterTask?.cancel()
        meterTask = nil
    }

    private func startMeterLoop() {
        guard isMainWindowVisible, meterTask == nil else { return }
        meterTask = Task { @MainActor [weak self] in
            var lastTick = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self, self.isMainWindowVisible else { break }
                let now = ProcessInfo.processInfo.systemUptime
                let dt = Float(max(0.016, min(0.1, now - lastTick)))
                lastTick = now

                if self.engine.anyBridgeRunning {
                    self.engine.syncXRunCounts()
                }

                var isActiveMetering = false
                var anyDecaying = false

                if let bridge = self.selectedBridge {
                    let isRunning = self.engine.isBridgeRunning(bridge.id)
                    if isRunning {
                        isActiveMetering = true
                        var cachedRawLevels: [Int: ChannelMeterLevel] = [:]
                        cachedRawLevels.reserveCapacity(bridge.routes.count)

                        for route in bridge.routes {
                            guard let model = self.routeMeterModels[route.id] else { continue }
                            var next = model.level

                            if route.isEnabled {
                                let raw: ChannelMeterLevel
                                if let existing = cachedRawLevels[route.sourceChannel] {
                                    raw = existing
                                } else {
                                    raw = self.engine.consumeSourceChannelLevel(
                                        sourceChannel: route.sourceChannel,
                                        inBridgeID: bridge.id
                                    )
                                    cachedRawLevels[route.sourceChannel] = raw
                                }
                                next.update(with: raw, now: now, deltaTime: dt)
                            } else if !next.isSilent {
                                next.decayToSilence(deltaTime: dt)
                            }

                            if next.isVisiblyDifferent(from: model.level) {
                                model.push(next)
                            }
                        }
                    } else {
                        for route in bridge.routes {
                            guard let model = self.routeMeterModels[route.id], !model.level.isSilent else { continue }
                            var next = model.level
                            next.decayToSilence(deltaTime: dt)
                            model.push(next)
                            if !next.isSilent {
                                anyDecaying = true
                            }
                        }
                    }
                }

                if isActiveMetering || anyDecaying {
                    try? await Task.sleep(for: .milliseconds(66))
                } else {
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
        }
    }
}
