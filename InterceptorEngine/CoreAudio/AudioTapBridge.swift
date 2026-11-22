import CoreAudio
import CoreAudioTypes
import Foundation
import os

/// Snapshot of runtime parameters for an active Core Audio passive tap bridge.
public struct ActiveBridgeInfo: Sendable {
    public let sourceSampleRate: Double
    public let destinationSampleRate: Double
    public let bufferFrames: Int
    public let estimatedLatencyMs: Double
    public let tappedStreamIndices: [Int]
    public let tappedInputChannels: Int
    public let destinationOutputChannels: Int
    public let logicalSourceToTapChannel: [Int: Int]
}

/// Manages the lifecycle of Core Audio passive device-stream tap(s), the private
/// clock-bridging aggregate device, and the real-time `AudioDeviceIOProc`.
public final class AudioTapBridge: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.interceptor.audio", category: "AudioTapBridge")
    private let deviceListenerQueue = DispatchQueue(label: "com.interceptor.audio.bridge-listeners", qos: .userInitiated)

    public let processor: RealTimeAudioProcessor
    private let tapHub: SharedSourceTapHub

    private var tapLease: SharedSourceTapHub.Lease?
    private var monitorOutputDeviceID: AudioObjectID?
    private var monitorOutputIOProcID: AudioDeviceIOProcID?
    private var isMonitorStarted = false

    private var monitoredSourceDevice: AudioHardwareDevice?
    private var monitoredDestinationDevice: AudioHardwareDevice?
    private var deviceListenerProxy: DeviceChangeListenerProxy?

    public private(set) var activeInfo: ActiveBridgeInfo?

    public init(
        processor: RealTimeAudioProcessor = RealTimeAudioProcessor(),
        tapHub: SharedSourceTapHub = .shared
    ) {
        self.processor = processor
        self.tapHub = tapHub
    }

    deinit {
        stop()
    }

    /// Attaches to a shared passive Core Audio tap on `sourceDevice` (zero unused-channel ASRC)
    /// and starts a direct native Core Audio output IOProc on `destinationDevice`, isolating
    /// clocks via `LockFreeAudioRingBuffer`.
    @discardableResult
    public func start(
        sourceDevice: AudioDeviceDescriptor,
        destinationDevice: AudioDeviceDescriptor,
        processTarget: ProcessTarget,
        routes: [ChannelRoute],
        preferredBufferFrames: Int?,
        driftBufferProfile: DriftBufferProfile = .balanced,
        selfProcessObjectID: AudioObjectID?,
        onDeviceInvalidated: @escaping @Sendable (_ role: DeviceRole) -> Void,
        onFormatChanged: @escaping @Sendable () -> Void
    ) throws -> ActiveBridgeInfo {
        stop()

        let system = AudioHardwareSystem.shared

        guard let coreSource = try? system.device(forUID: sourceDevice.uid) else {
            throw AudioTapBridgeError.sourceDeviceUnavailable(sourceDevice.name)
        }
        guard let coreDest = try? system.device(forUID: destinationDevice.uid) else {
            throw AudioTapBridgeError.destinationDeviceUnavailable(destinationDevice.name)
        }
        guard !sourceDevice.outputStreams.isEmpty else {
            throw AudioTapBridgeError.noOutputStreams(sourceDevice.name)
        }

        // 1. Optional preferred buffer size on the monitor destination (never touches source interface).
        if let preferredFrames = preferredBufferFrames, preferredFrames >= 32, coreDest.id != coreSource.id {
            try? coreDest.setBufferFrameSize(preferredFrames)
        }

        // 2. Inspect direct monitor output layout before acquiring the shared tap.
        let outputConfig = (try? coreDest.outputStreamConfiguration) ?? []
        let outputLayout = RTBufferLayoutMap(streamConfiguration: outputConfig)
        guard outputLayout.channelCount > 0 else {
            throw AudioTapBridgeError.emptyAggregateStreams
        }

        let coreSourceRate = (try? coreSource.nominalSampleRate) ?? sourceDevice.nominalSampleRate
        let actualDestRate = (try? coreDest.nominalSampleRate) ?? destinationDevice.nominalSampleRate
        let actualSourceFrames = (try? coreSource.bufferFrameSize) ?? sourceDevice.bufferFrameSize
        let actualDestFrames = (try? coreDest.bufferFrameSize) ?? destinationDevice.bufferFrameSize
        let sourceStreamSignature = ((try? coreSource.outputStreamConfiguration) ?? []).map(\.mNumberChannels)
        let destStreamSignature = outputConfig.map(\.mNumberChannels)
        let destOutputLatency = (try? coreDest.outputLatency) ?? destinationDevice.outputLatencyFrames
        let destSafetyOffset = (try? coreDest.outputSafetyOffset) ?? 0

        // 3. Determine required output streams on the source interface and acquire a shared tap lease.
        let requestedSourceChannels = routes
            .filter(\.isEnabled)
            .map(\.sourceChannel)
        let streamIndices = sourceDevice.requiredStreamIndices(forLogicalChannels: requestedSourceChannels)

        var initialSnapshot = RTRoutingSnapshot()
        let lease = try tapHub.acquire(
            sourceDevice: sourceDevice,
            coreSource: coreSource,
            streamIndices: streamIndices,
            processTarget: processTarget,
            selfProcessObjectID: selfProcessObjectID,
            processor: processor
        ) { metadata in
            // Prepare ring buffer, layouts, pre-faulted/mlock'd slots, and routing BEFORE the
            // shared tap IOProc ever dispatches a callback to `processor`.
            initialSnapshot = RTRoutingSnapshot.build(
                routes: routes,
                sourceLogicalToTapChannel: { metadata.logicalSourceToTapChannel[$0] }
            )
            processor.resetRuntimeState()
            processor.ringBuffer.configure(
                sourceSampleRate: metadata.sourceSampleRate,
                destinationSampleRate: actualDestRate,
                sourceBufferFrames: metadata.tapBufferFrames,
                destinationBufferFrames: actualDestFrames,
                profile: driftBufferProfile
            )
            processor.configure(
                inputLayout: metadata.inputLayout,
                outputLayout: outputLayout
            )
            processor.updateRouting(initialSnapshot)
        }

        let meta = lease.metadata
        let ringLatencyMs = processor.ringBuffer.estimatedBufferLatencyMs(sourceSampleRate: meta.sourceSampleRate)
        let destHardwareLatencyMs = actualDestRate > 0
            ? (Double(actualDestFrames + destOutputLatency + destSafetyOffset) / actualDestRate) * 1000.0
            : 0.0
        let latencyMs = ringLatencyMs + destHardwareLatencyMs

        // 4. Register direct monitor output IOProc (zero aggregate on monitor hardware).
        let clientData = Unmanaged.passUnretained(processor).toOpaque()
        var createdOutIOProcID: AudioDeviceIOProcID?
        let outCreateStatus = AudioDeviceCreateIOProcID(
            coreDest.id,
            interceptorMonitorOutputIOProc,
            clientData,
            &createdOutIOProcID
        )
        guard outCreateStatus == noErr, let validOutIOProcID = createdOutIOProcID else {
            lease.release()
            throw AudioTapBridgeError.ioProcRegistrationFailed(outCreateStatus)
        }

        // Disable all input streams on the monitor destination IOProc so Core Audio never captures mic/line-in.
        let destInputStreamCount = ((try? coreDest.streams) ?? []).filter { (try? $0.direction) == .input }.count
        if destInputStreamCount > 0 {
            disableAllInputStreams(deviceID: coreDest.id, ioProcID: validOutIOProcID, inputStreamCount: destInputStreamCount)
        }

        let outStartStatus = AudioDeviceStart(coreDest.id, validOutIOProcID)
        guard outStartStatus == noErr else {
            AudioDeviceDestroyIOProcID(coreDest.id, validOutIOProcID)
            lease.release()
            throw AudioTapBridgeError.deviceStartFailed(outStartStatus)
        }

        self.tapLease = lease
        self.monitorOutputDeviceID = coreDest.id
        self.monitorOutputIOProcID = validOutIOProcID
        self.isMonitorStarted = true

        attachDeviceListeners(
            source: coreSource,
            destination: coreDest,
            expectedSourceRate: coreSourceRate,
            expectedDestinationRate: actualDestRate,
            expectedSourceBufferFrames: actualSourceFrames,
            expectedDestBufferFrames: actualDestFrames,
            expectedSourceStreamSignature: sourceStreamSignature,
            expectedDestStreamSignature: destStreamSignature,
            onDeviceInvalidated: onDeviceInvalidated,
            onFormatChanged: { [tapHub, sourceUID = sourceDevice.uid] in
                tapHub.invalidateSessions(forSourceUID: sourceUID)
                onFormatChanged()
            }
        )

        let info = ActiveBridgeInfo(
            sourceSampleRate: meta.sourceSampleRate,
            destinationSampleRate: actualDestRate,
            bufferFrames: actualDestFrames,
            estimatedLatencyMs: latencyMs,
            tappedStreamIndices: streamIndices,
            tappedInputChannels: meta.inputLayout.channelCount,
            destinationOutputChannels: outputLayout.channelCount,
            logicalSourceToTapChannel: meta.logicalSourceToTapChannel
        )
        self.activeInfo = info

        let destOutSummary = outputConfig.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")
        logger.info(
            "Started decoupled passive bridge: \(sourceDevice.name) (\(meta.sourceSampleRate) Hz, sharedTap=[\(meta.inputConfigSummary)]) → \(destinationDevice.name) (\(actualDestRate) Hz, out=[\(destOutSummary)], \(actualDestFrames) fr, profile=\(driftBufferProfile.rawValue), activeRoutes=\(initialSnapshot.patchCount))"
        )
        return info
    }

    /// Updates mono channel patches lock-free while audio continues uninterrupted.
    public func updateLiveRoutes(_ routes: [ChannelRoute]) {
        guard let info = activeInfo else { return }
        let snapshot = RTRoutingSnapshot.build(
            routes: routes,
            sourceLogicalToTapChannel: { info.logicalSourceToTapChannel[$0] }
        )
        processor.updateRouting(snapshot)
    }

    /// Stops monitor output I/O and releases the shared tap lease in strict order.
    public func stop() {
        detachDeviceListeners()

        if let destID = monitorOutputDeviceID, let outProcID = monitorOutputIOProcID {
            if isMonitorStarted {
                let stopStatus = AudioDeviceStop(destID, outProcID)
                if stopStatus != noErr {
                    logger.warning("Monitor AudioDeviceStop returned OSStatus \(stopStatus)")
                }
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(destID, outProcID)
            if destroyStatus != noErr {
                logger.warning("Monitor AudioDeviceDestroyIOProcID returned OSStatus \(destroyStatus)")
            }
        }

        tapLease?.release()
        tapLease = nil
        monitorOutputDeviceID = nil
        monitorOutputIOProcID = nil
        isMonitorStarted = false
        activeInfo = nil
        processor.resetRuntimeState()
    }

    // MARK: - Helpers

    /// Disables all input streams on the direct monitor output IOProc so Core Audio never activates
    /// hardware microphone/line-in DMA or triggers unnecessary input permissions.
    private func disableAllInputStreams(
        deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        inputStreamCount: Int
    ) {
        guard inputStreamCount > 0 else { return }
        let byteSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
            + max(0, inputStreamCount - 1) * MemoryLayout<UInt32>.size
        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: byteSize,
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { rawBuffer.deallocate() }
        _ = rawBuffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteSize)

        let usage = rawBuffer.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(inputStreamCount)

        if let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) {
            let flags = rawBuffer.advanced(by: flagsOffset).assumingMemoryBound(to: UInt32.self)
            for i in 0..<inputStreamCount {
                flags[i] = 0
            }
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(byteSize),
            rawBuffer
        )
        if status != noErr {
            logger.warning("kAudioDevicePropertyIOProcStreamUsage returned OSStatus \(status)")
        }
    }

    private static var monitoredProperties: [AudioObjectPropertyAddress] {
        [
            PropertyAddress(kAudioDevicePropertyDeviceIsAlive),
            PropertyAddress(kAudioDevicePropertyNominalSampleRate),
            PropertyAddress(kAudioDevicePropertyBufferFrameSize),
            PropertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        ]
    }

    private func attachDeviceListeners(
        source: AudioHardwareDevice,
        destination: AudioHardwareDevice,
        expectedSourceRate: Double,
        expectedDestinationRate: Double,
        expectedSourceBufferFrames: Int,
        expectedDestBufferFrames: Int,
        expectedSourceStreamSignature: [UInt32],
        expectedDestStreamSignature: [UInt32],
        onDeviceInvalidated: @escaping @Sendable (_ role: DeviceRole) -> Void,
        onFormatChanged: @escaping @Sendable () -> Void
    ) {
        let proxy = DeviceChangeListenerProxy(
            sourceID: source.id,
            destinationID: destination.id,
            expectedSourceRate: expectedSourceRate,
            expectedDestinationRate: expectedDestinationRate,
            expectedSourceBufferFrames: expectedSourceBufferFrames,
            expectedDestBufferFrames: expectedDestBufferFrames,
            expectedSourceStreamSignature: expectedSourceStreamSignature,
            expectedDestStreamSignature: expectedDestStreamSignature,
            onDeviceInvalidated: onDeviceInvalidated,
            onFormatChanged: onFormatChanged
        )
        self.deviceListenerProxy = proxy
        self.monitoredSourceDevice = source
        self.monitoredDestinationDevice = destination

        let addresses = Self.monitoredProperties

        source.delegates.append(proxy)
        try? source.addListener(forProperties: addresses, dispatchQueue: deviceListenerQueue)

        if destination.id != source.id {
            destination.delegates.append(proxy)
            try? destination.addListener(forProperties: addresses, dispatchQueue: deviceListenerQueue)
        }
    }

    private func detachDeviceListeners() {
        guard let proxy = deviceListenerProxy else { return }
        let addresses = Self.monitoredProperties

        if let source = monitoredSourceDevice {
            try? source.removeListener(forProperties: addresses, dispatchQueue: deviceListenerQueue)
            source.delegates.removeAll { ($0 as AnyObject) === proxy }
        }
        if let dest = monitoredDestinationDevice, dest.id != monitoredSourceDevice?.id {
            try? dest.removeListener(forProperties: addresses, dispatchQueue: deviceListenerQueue)
            dest.delegates.removeAll { ($0 as AnyObject) === proxy }
        }

        monitoredSourceDevice = nil
        monitoredDestinationDevice = nil
        deviceListenerProxy = nil
    }
}

private final class DeviceChangeListenerProxy: PropertyListenerDelegate, @unchecked Sendable {
    private let sourceID: AudioObjectID
    private let destinationID: AudioObjectID
    private let expectedSourceRate: Double
    private let expectedDestinationRate: Double
    private let expectedSourceBufferFrames: Int
    private let expectedDestBufferFrames: Int
    private let expectedSourceStreamSignature: [UInt32]
    private let expectedDestStreamSignature: [UInt32]
    private let onDeviceInvalidated: @Sendable (_ role: DeviceRole) -> Void
    private let onFormatChanged: @Sendable () -> Void

    init(
        sourceID: AudioObjectID,
        destinationID: AudioObjectID,
        expectedSourceRate: Double,
        expectedDestinationRate: Double,
        expectedSourceBufferFrames: Int,
        expectedDestBufferFrames: Int,
        expectedSourceStreamSignature: [UInt32],
        expectedDestStreamSignature: [UInt32],
        onDeviceInvalidated: @escaping @Sendable (_ role: DeviceRole) -> Void,
        onFormatChanged: @escaping @Sendable () -> Void
    ) {
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.expectedSourceRate = expectedSourceRate
        self.expectedDestinationRate = expectedDestinationRate
        self.expectedSourceBufferFrames = expectedSourceBufferFrames
        self.expectedDestBufferFrames = expectedDestBufferFrames
        self.expectedSourceStreamSignature = expectedSourceStreamSignature
        self.expectedDestStreamSignature = expectedDestStreamSignature
        self.onDeviceInvalidated = onDeviceInvalidated
        self.onFormatChanged = onFormatChanged
    }

    func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        let sourceDevice = AudioHardwareDevice(id: sourceID)
        let destDevice = AudioHardwareDevice(id: destinationID)
        var formatChanged = false

        for prop in properties {
            switch prop.mSelector {
            case kAudioDevicePropertyDeviceIsAlive:
                if (try? sourceDevice.isAlive) != true {
                    onDeviceInvalidated(.source)
                    return
                }
                if (try? destDevice.isAlive) != true {
                    onDeviceInvalidated(.destination)
                    return
                }
            case kAudioDevicePropertyNominalSampleRate:
                let currentSourceRate = (try? sourceDevice.nominalSampleRate) ?? expectedSourceRate
                let currentDestRate = (try? destDevice.nominalSampleRate) ?? expectedDestinationRate
                if abs(currentSourceRate - expectedSourceRate) > 1.0 ||
                    abs(currentDestRate - expectedDestinationRate) > 1.0 {
                    formatChanged = true
                }
            case kAudioDevicePropertyBufferFrameSize:
                let currentSourceFrames = (try? sourceDevice.bufferFrameSize) ?? expectedSourceBufferFrames
                let currentDestFrames = (try? destDevice.bufferFrameSize) ?? expectedDestBufferFrames
                if currentSourceFrames != expectedSourceBufferFrames ||
                    currentDestFrames != expectedDestBufferFrames {
                    formatChanged = true
                }
            case kAudioDevicePropertyStreamConfiguration:
                let currentSourceSig = ((try? sourceDevice.outputStreamConfiguration) ?? []).map(\.mNumberChannels)
                let currentDestSig = ((try? destDevice.outputStreamConfiguration) ?? []).map(\.mNumberChannels)
                if (!currentSourceSig.isEmpty && currentSourceSig != expectedSourceStreamSignature) ||
                    (!currentDestSig.isEmpty && currentDestSig != expectedDestStreamSignature) {
                    formatChanged = true
                }
            default:
                break
            }
        }

        if formatChanged {
            onFormatChanged()
        }
    }
}
