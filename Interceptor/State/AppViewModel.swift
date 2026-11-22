import Foundation
import InterceptorEngine
import Observation
import os

/// Smoothed ballistic VU meter state rendered at 60 Hz per channel.
public struct SmoothedChannelMeter: Sendable, Equatable {
    public var rmsDB: Float = -60.0
    public var peakDB: Float = -60.0
    public var peakHoldDB: Float = -60.0
    public var peakHoldTimestamp: TimeInterval = 0
    public var isClipped: Bool = false

    public static let floorDB: Float = -60.0

    public mutating func update(
        with raw: ChannelMeterLevel,
        now: TimeInterval,
        deltaTime: Float
    ) {
        let clampedPeak = max(Self.floorDB, min(0.0, raw.peakDB))
        let clampedRMS = max(Self.floorDB, min(0.0, raw.rmsDB))

        let decay = deltaTime * 24.0
        if clampedPeak >= peakDB {
            peakDB = clampedPeak
        } else {
            peakDB = max(Self.floorDB, peakDB - decay)
        }

        if clampedRMS >= rmsDB {
            rmsDB = clampedRMS
        } else {
            rmsDB = max(Self.floorDB, rmsDB - decay * 0.85)
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
}

/// Primary `@MainActor` observable view model coordinating virtual routing bridges,
/// preferences, and 60 Hz per-channel VU metering.
@MainActor
@Observable
public final class AppViewModel {
    private enum DefaultsKey {
        static let autoReconnect = "com.interceptor.pref.autoReconnect"
        static let keepRunningInMenuBar = "com.interceptor.pref.keepRunningInMenuBar"
        static let preferredBufferFrames = "com.interceptor.pref.preferredBufferFrames"
    }

    private let defaults: UserDefaults
    public let engine: InterceptorEngine

    /// Currently selected virtual routing bridge in the sidebar.
    public var selectedBridgeID: UUID?

    /// Controls the on-demand Bridge Info popover (`⌘I`).
    public var isBridgeInfoPresented: Bool = false

    // MARK: - User Preferences

    public var autoReconnectEnabled: Bool {
        didSet {
            defaults.set(autoReconnectEnabled, forKey: DefaultsKey.autoReconnect)
            engine.autoReconnectEnabled = autoReconnectEnabled
        }
    }

    public var keepRunningInMenuBar: Bool {
        didSet { defaults.set(keepRunningInMenuBar, forKey: DefaultsKey.keepRunningInMenuBar) }
    }

    /// `0` means Automatic (use destination device default buffer size).
    public var preferredBufferFramesSetting: Int {
        didSet {
            defaults.set(preferredBufferFramesSetting, forKey: DefaultsKey.preferredBufferFrames)
            engine.preferredBufferFrames = preferredBufferFramesSetting > 0 ? preferredBufferFramesSetting : nil
        }
    }

    // MARK: - Live Per-Channel Meters (60 Hz)

    public private(set) var metersByBridgeID: [UUID: [SmoothedChannelMeter]] = [:]

    private var meterTask: Task<Void, Never>?

    public init(
        engine: InterceptorEngine = InterceptorEngine(),
        defaults: UserDefaults = .standard
    ) {
        self.engine = engine
        self.defaults = defaults

        defaults.register(defaults: [
            DefaultsKey.autoReconnect: true,
            DefaultsKey.keepRunningInMenuBar: true,
            DefaultsKey.preferredBufferFrames: 0
        ])

        let savedAutoReconnect = defaults.bool(forKey: DefaultsKey.autoReconnect)
        let savedKeepMenuBar = defaults.bool(forKey: DefaultsKey.keepRunningInMenuBar)
        let savedBuffer = defaults.integer(forKey: DefaultsKey.preferredBufferFrames)

        self.autoReconnectEnabled = savedAutoReconnect
        self.keepRunningInMenuBar = savedKeepMenuBar
        self.preferredBufferFramesSetting = savedBuffer

        engine.autoReconnectEnabled = savedAutoReconnect
        engine.preferredBufferFrames = savedBuffer > 0 ? savedBuffer : nil

        self.selectedBridgeID = engine.bridges.first?.id
        startMeterLoop()
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
        engine.removeBridge(id: id)
        metersByBridgeID.removeValue(forKey: id)
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

    public func updateSelectedBridge(_ mutate: (inout AudioBridgeConfiguration) -> Void) {
        guard var config = selectedBridge else { return }
        mutate(&config)
        engine.updateBridge(config)
    }

    public func toggleSelectedBridge() {
        guard let id = selectedBridge?.id else { return }
        engine.toggleBridge(id: id)
    }

    public func toggleBridge(id: UUID) {
        engine.toggleBridge(id: id)
    }

    public func stopAllBridges() {
        engine.stopAll()
    }

    public func refreshDevices() {
        engine.refreshDevices()
    }

    public func openAudioCaptureSettings() {
        AudioCapturePermission.openSystemSettings()
    }

    // MARK: - Mono Channel Editing inside Selected Bridge

    public func addChannelToSelectedBridge() {
        updateSelectedBridge { config in
            let maxSrc = engine.sourceDevice(for: config)?.totalOutputChannels ?? 64
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

            config.routes.append(
                ChannelRoute(
                    label: "Channel \(config.routes.count + 1)",
                    isEnabled: true,
                    sourceChannel: max(1, min(nextSrc, maxSrc)),
                    destinationChannel: max(1, min(nextDst, maxDst))
                )
            )
        }
    }

    public func updateRouteInSelectedBridge(_ updated: ChannelRoute) {
        updateSelectedBridge { config in
            guard let idx = config.routes.firstIndex(where: { $0.id == updated.id }) else { return }
            config.routes[idx] = updated
        }
    }

    public func removeRouteFromSelectedBridge(routeID: UUID) {
        updateSelectedBridge { config in
            config.routes.removeAll { $0.id == routeID }
        }
    }

    // MARK: - Metering Lookup

    public func meter(for route: ChannelRoute, inBridgeID bridgeID: UUID) -> SmoothedChannelMeter {
        guard engine.isBridgeRunning(bridgeID), route.isEnabled,
              let bank = metersByBridgeID[bridgeID] else {
            return SmoothedChannelMeter()
        }
        let idx = route.sourceChannel - 1
        guard idx >= 0 && idx < bank.count else {
            return SmoothedChannelMeter()
        }
        return bank[idx]
    }

    public func shutdown() {
        meterTask?.cancel()
        meterTask = nil
        engine.shutdown()
    }

    private func startMeterLoop() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            var lastTick = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                guard let self else { break }
                let now = ProcessInfo.processInfo.systemUptime
                let dt = Float(max(0.008, min(0.1, now - lastTick)))
                lastTick = now

                var anyRunning = false
                var anyDecaying = false

                for bridge in self.engine.bridges {
                    if self.engine.isBridgeRunning(bridge.id) {
                        anyRunning = true
                        let snapshot = self.engine.consumeActivitySnapshot(forBridgeID: bridge.id)
                        var bank = self.metersByBridgeID[bridge.id] ?? []
                        let targetCount = max(2, snapshot.inputLevels.count)
                        if bank.count < targetCount {
                            bank.append(contentsOf: repeatElement(SmoothedChannelMeter(), count: targetCount - bank.count))
                        }
                        for i in snapshot.inputLevels.indices where i < bank.count {
                            bank[i].update(with: snapshot.inputLevels[i], now: now, deltaTime: dt)
                        }
                        self.metersByBridgeID[bridge.id] = bank
                    } else if var bank = self.metersByBridgeID[bridge.id] {
                        var stillActive = false
                        for i in bank.indices {
                            if bank[i].peakHoldDB > SmoothedChannelMeter.floorDB + 0.1 {
                                bank[i].decayToSilence(deltaTime: dt)
                                stillActive = true
                            }
                        }
                        if stillActive {
                            anyDecaying = true
                            self.metersByBridgeID[bridge.id] = bank
                        } else {
                            self.metersByBridgeID.removeValue(forKey: bridge.id)
                        }
                    }
                }

                if anyRunning {
                    try? await Task.sleep(for: .milliseconds(16))
                } else {
                    try? await Task.sleep(for: .milliseconds(anyDecaying ? 33 : 200))
                }
            }
        }
    }
}
