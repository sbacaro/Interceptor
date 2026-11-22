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

    private var activeTaps: [AudioHardwareTap] = []
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var tapInputIOProcID: AudioDeviceIOProcID?
    private var monitorOutputDeviceID: AudioObjectID?
    private var monitorOutputIOProcID: AudioDeviceIOProcID?
    private var isTapStarted = false
    private var isMonitorStarted = false

    private var monitoredSourceDevice: AudioHardwareDevice?
    private var monitoredDestinationDevice: AudioHardwareDevice?
    private var deviceListenerProxy: DeviceChangeListenerProxy?

    public private(set) var activeInfo: ActiveBridgeInfo?

    public init(processor: RealTimeAudioProcessor = RealTimeAudioProcessor()) {
        self.processor = processor
    }

    deinit {
        stop()
    }

    /// Creates passive non-exclusive Core Audio tap(s) on `sourceDevice`, binds them with
    /// native `coreaudiod` SubTap Drift Compensation to `destinationDevice` inside a private
    /// aggregate device, and starts the real-time zero-allocation IOProc.
    @discardableResult
    public func start(
        sourceDevice: AudioDeviceDescriptor,
        destinationDevice: AudioDeviceDescriptor,
        processTarget: ProcessTarget,
        routes: [ChannelRoute],
        preferredBufferFrames: Int?,
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

        // 1. Determine which output stream indices on the source interface need to be tapped.
        let requestedSourceChannels = routes
            .filter(\.isEnabled)
            .map(\.sourceChannel)
        let streamIndices = sourceDevice.requiredStreamIndices(forLogicalChannels: requestedSourceChannels)

        // 2. Create passive, unmuted, private Core Audio Tap(s) for each required output stream.
        var createdTaps: [AudioHardwareTap] = []
        var tapDicts: [[String: Any]] = []
        var logicalToTapChannel: [Int: Int] = [:]
        var tapChannelCursor = 0

        do {
            for streamIndex in streamIndices {
                let tapDescription = makeTapDescription(
                    sourceUID: sourceDevice.uid,
                    streamIndex: streamIndex,
                    processTarget: processTarget,
                    selfProcessObjectID: selfProcessObjectID
                )

                guard let tap = try system.makeProcessTap(description: tapDescription) else {
                    throw AudioTapBridgeError.tapCreationFailed(kAudioHardwareUnspecifiedError)
                }
                createdTaps.append(tap)

                let tapUID = try tap.uid
                let tapFormat = try? tap.format
                let streamChannelCount: Int = {
                    if let fmtCh = tapFormat?.mChannelsPerFrame, fmtCh > 0 {
                        return Int(fmtCh)
                    }
                    return sourceDevice.outputStreams.first(where: { $0.streamIndex == streamIndex })?.channelCount ?? 2
                }()

                if let streamDesc = sourceDevice.outputStreams.first(where: { $0.streamIndex == streamIndex }) {
                    for localIdx in 0..<streamChannelCount {
                        logicalToTapChannel[streamDesc.startingChannel + localIdx] = tapChannelCursor + localIdx
                    }
                }
                tapChannelCursor += streamChannelCount

                // Tap-Only capture with Core Audio SubTap drift compensation DISABLED so Core Audio
                // never wastes CPU resampling 64+ unused hardware channels. Drift compensation & SRC
                // run exclusively on the active routed mono channels inside `LockFreeAudioRingBuffer`.
                let subTapDict: [String: Any] = [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: false
                ]
                tapDicts.append(subTapDict)
            }
        } catch let hwErr as AudioHardwareError {
            cleanupPartial(taps: createdTaps, aggregate: nil)
            if AudioCapturePermission.isPermissionError(hwErr.error) {
                throw AudioTapBridgeError.permissionDenied(hwErr.error)
            }
            throw AudioTapBridgeError.tapCreationFailed(hwErr.error)
        } catch {
            cleanupPartial(taps: createdTaps, aggregate: nil)
            throw error
        }

        // 3. Create a Tap-Only private Aggregate Device (zero subdevices, zero unused-channel ASRC).
        //    The source interface clock stays 100% isolated, and no monitor mic/line inputs enter the tap.
        let aggregateUID = CoreAudioDeviceCatalog.privateAggregateUIDPrefix + UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "Interceptor Private Tap Capture",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: tapDicts
        ]

        let aggregate: AudioHardwareAggregateDevice
        do {
            guard let createdAggregate = try system.makeAggregateDevice(description: aggregateDescription) else {
                cleanupPartial(taps: createdTaps, aggregate: nil)
                throw AudioTapBridgeError.aggregateCreationFailed(kAudioHardwareUnspecifiedError)
            }
            aggregate = createdAggregate
        } catch let hwErr as AudioHardwareError {
            cleanupPartial(taps: createdTaps, aggregate: nil)
            throw AudioTapBridgeError.aggregateCreationFailed(hwErr.error)
        } catch {
            cleanupPartial(taps: createdTaps, aggregate: nil)
            throw error
        }

        // 4. Optional preferred buffer size on the monitor destination (never touches source interface).
        if let preferredFrames = preferredBufferFrames, preferredFrames >= 32, coreDest.id != coreSource.id {
            try? coreDest.setBufferFrameSize(preferredFrames)
        }

        // 5. Inspect actual tap input layout and direct monitor output layout.
        let inputConfig = (try? aggregate.inputStreamConfiguration) ?? []
        let outputConfig = (try? coreDest.outputStreamConfiguration) ?? []
        let inputLayout = RTBufferLayoutMap(streamConfiguration: inputConfig)
        let outputLayout = RTBufferLayoutMap(streamConfiguration: outputConfig)

        guard inputLayout.channelCount > 0, outputLayout.channelCount > 0 else {
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.emptyAggregateStreams
        }

        let actualSourceRate = (try? aggregate.nominalSampleRate)
            ?? (try? coreSource.nominalSampleRate)
            ?? sourceDevice.nominalSampleRate
        let actualDestRate = (try? coreDest.nominalSampleRate) ?? destinationDevice.nominalSampleRate
        let actualTapFrames = (try? aggregate.bufferFrameSize) ?? sourceDevice.bufferFrameSize
        let actualDestFrames = (try? coreDest.bufferFrameSize) ?? destinationDevice.bufferFrameSize
        let destOutputLatency = (try? coreDest.outputLatency) ?? destinationDevice.outputLatencyFrames
        let destSafetyOffset = (try? coreDest.outputSafetyOffset) ?? 0

        // 6. Configure lock-free ring buffer (active-channel-only drift compensation) and DSP layouts BEFORE start.
        let initialSnapshot = RTRoutingSnapshot.build(
            routes: routes,
            sourceLogicalToTapChannel: { logicalToTapChannel[$0] }
        )
        processor.ringBuffer.configure(
            sourceSampleRate: actualSourceRate,
            destinationSampleRate: actualDestRate,
            sourceBufferFrames: actualTapFrames,
            destinationBufferFrames: actualDestFrames
        )
        processor.configure(
            inputLayout: inputLayout,
            outputLayout: outputLayout
        )
        processor.updateRouting(initialSnapshot)
        processor.meterBank.resetAll()

        let ringLatencyMs = processor.ringBuffer.estimatedBufferLatencyMs(sourceSampleRate: actualSourceRate)
        let destHardwareLatencyMs = actualDestRate > 0
            ? (Double(actualDestFrames + destOutputLatency + destSafetyOffset) / actualDestRate) * 1000.0
            : 0.0
        let latencyMs = ringLatencyMs + destHardwareLatencyMs

        // 7. Register decoupled C-function IOProcs (Tap Input on private aggregate + Output directly on monitor).
        let clientData = Unmanaged.passUnretained(processor).toOpaque()

        var createdTapIOProcID: AudioDeviceIOProcID?
        let tapCreateStatus = AudioDeviceCreateIOProcID(
            aggregate.id,
            interceptorTapInputIOProc,
            clientData,
            &createdTapIOProcID
        )
        guard tapCreateStatus == noErr, let validTapIOProcID = createdTapIOProcID else {
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.ioProcRegistrationFailed(tapCreateStatus)
        }

        var createdOutIOProcID: AudioDeviceIOProcID?
        let outCreateStatus = AudioDeviceCreateIOProcID(
            coreDest.id,
            interceptorMonitorOutputIOProc,
            clientData,
            &createdOutIOProcID
        )
        guard outCreateStatus == noErr, let validOutIOProcID = createdOutIOProcID else {
            AudioDeviceDestroyIOProcID(aggregate.id, validTapIOProcID)
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.ioProcRegistrationFailed(outCreateStatus)
        }

        // Disable all input streams on the monitor destination IOProc so Core Audio never captures mic/line-in.
        let destInputStreamCount = ((try? coreDest.streams) ?? []).filter { (try? $0.direction) == .input }.count
        if destInputStreamCount > 0 {
            disableAllInputStreams(deviceID: coreDest.id, ioProcID: validOutIOProcID, inputStreamCount: destInputStreamCount)
        }

        let tapStartStatus = AudioDeviceStart(aggregate.id, validTapIOProcID)
        guard tapStartStatus == noErr else {
            AudioDeviceDestroyIOProcID(coreDest.id, validOutIOProcID)
            AudioDeviceDestroyIOProcID(aggregate.id, validTapIOProcID)
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.deviceStartFailed(tapStartStatus)
        }

        let outStartStatus = AudioDeviceStart(coreDest.id, validOutIOProcID)
        guard outStartStatus == noErr else {
            AudioDeviceStop(aggregate.id, validTapIOProcID)
            AudioDeviceDestroyIOProcID(coreDest.id, validOutIOProcID)
            AudioDeviceDestroyIOProcID(aggregate.id, validTapIOProcID)
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.deviceStartFailed(outStartStatus)
        }

        self.activeTaps = createdTaps
        self.aggregateDevice = aggregate
        self.tapInputIOProcID = validTapIOProcID
        self.monitorOutputDeviceID = coreDest.id
        self.monitorOutputIOProcID = validOutIOProcID
        self.isTapStarted = true
        self.isMonitorStarted = true

        attachDeviceListeners(
            source: coreSource,
            destination: coreDest,
            expectedSourceRate: actualSourceRate,
            expectedDestinationRate: actualDestRate,
            onDeviceInvalidated: onDeviceInvalidated,
            onFormatChanged: onFormatChanged
        )

        let info = ActiveBridgeInfo(
            sourceSampleRate: actualSourceRate,
            destinationSampleRate: actualDestRate,
            bufferFrames: actualDestFrames,
            estimatedLatencyMs: latencyMs,
            tappedStreamIndices: streamIndices,
            tappedInputChannels: inputLayout.channelCount,
            destinationOutputChannels: outputLayout.channelCount,
            logicalSourceToTapChannel: logicalToTapChannel
        )
        self.activeInfo = info

        let aggInSummary = inputConfig.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")
        let destOutSummary = outputConfig.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")
        logger.info(
            "Started decoupled passive bridge: \(sourceDevice.name) (\(actualSourceRate) Hz, tap=[\(aggInSummary)]) → \(destinationDevice.name) (\(actualDestRate) Hz, out=[\(destOutSummary)], \(actualDestFrames) fr, activeRoutes=\(initialSnapshot.patchCount))"
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

    /// Stops audio I/O and destroys the monitor IOProc, private tap aggregate, and Core Audio tap(s) in strict order.
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

        if let aggregate = aggregateDevice, let tapProcID = tapInputIOProcID {
            if isTapStarted {
                let stopStatus = AudioDeviceStop(aggregate.id, tapProcID)
                if stopStatus != noErr {
                    logger.warning("Tap AudioDeviceStop returned OSStatus \(stopStatus)")
                }
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregate.id, tapProcID)
            if destroyStatus != noErr {
                logger.warning("Tap AudioDeviceDestroyIOProcID returned OSStatus \(destroyStatus)")
            }
        }

        cleanupPartial(taps: activeTaps, aggregate: aggregateDevice)

        activeTaps.removeAll()
        aggregateDevice = nil
        tapInputIOProcID = nil
        monitorOutputDeviceID = nil
        monitorOutputIOProcID = nil
        isTapStarted = false
        isMonitorStarted = false
        activeInfo = nil
        processor.ringBuffer.reset()
        processor.meterBank.resetAll()
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

    private func makeTapDescription(
        sourceUID: String,
        streamIndex: Int,
        processTarget: ProcessTarget,
        selfProcessObjectID: AudioObjectID?
    ) -> CATapDescription {
        let description: CATapDescription

        switch processTarget {
        case .allProcesses:
            let excluded: [AudioObjectID] = selfProcessObjectID.map { [$0] } ?? []
            description = CATapDescription(
                excludingProcesses: excluded,
                deviceUID: sourceUID,
                stream: UInt(streamIndex)
            )
            description.isExclusive = true

        case let .application(bundleID, _):
            description = CATapDescription()
            description.deviceUID = sourceUID
            description.stream = UInt(streamIndex)
            description.isExclusive = false
            description.bundleIDs = [bundleID]
            description.isProcessRestoreEnabled = true
        }

        // Critical invariant: ALWAYS passive, unmuted, private tap — never interrupts or mutes original audio.
        description.muteBehavior = .unmuted
        description.isPrivate = true
        description.name = "Interceptor Passive Tap"
        return description
    }

    private func cleanupPartial(taps: [AudioHardwareTap], aggregate: AudioHardwareAggregateDevice?) {
        let system = AudioHardwareSystem.shared
        if let aggregate {
            try? system.destroyAggregateDevice(aggregate)
        }
        for tap in taps {
            try? system.destroyProcessTap(tap)
        }
    }

    private func attachDeviceListeners(
        source: AudioHardwareDevice,
        destination: AudioHardwareDevice,
        expectedSourceRate: Double,
        expectedDestinationRate: Double,
        onDeviceInvalidated: @escaping @Sendable (_ role: DeviceRole) -> Void,
        onFormatChanged: @escaping @Sendable () -> Void
    ) {
        let proxy = DeviceChangeListenerProxy(
            sourceID: source.id,
            destinationID: destination.id,
            expectedSourceRate: expectedSourceRate,
            expectedDestinationRate: expectedDestinationRate,
            onDeviceInvalidated: onDeviceInvalidated,
            onFormatChanged: onFormatChanged
        )
        self.deviceListenerProxy = proxy
        self.monitoredSourceDevice = source
        self.monitoredDestinationDevice = destination

        let addresses = [
            PropertyAddress(kAudioDevicePropertyDeviceIsAlive),
            PropertyAddress(kAudioDevicePropertyNominalSampleRate)
        ]

        source.delegates.append(proxy)
        try? source.addListener(forProperties: addresses, dispatchQueue: deviceListenerQueue)

        if destination.id != source.id {
            destination.delegates.append(proxy)
            try? destination.addListener(forProperties: addresses, dispatchQueue: deviceListenerQueue)
        }
    }

    private func detachDeviceListeners() {
        guard let proxy = deviceListenerProxy else { return }
        let addresses = [
            PropertyAddress(kAudioDevicePropertyDeviceIsAlive),
            PropertyAddress(kAudioDevicePropertyNominalSampleRate)
        ]

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
    private let onDeviceInvalidated: @Sendable (_ role: DeviceRole) -> Void
    private let onFormatChanged: @Sendable () -> Void

    init(
        sourceID: AudioObjectID,
        destinationID: AudioObjectID,
        expectedSourceRate: Double,
        expectedDestinationRate: Double,
        onDeviceInvalidated: @escaping @Sendable (_ role: DeviceRole) -> Void,
        onFormatChanged: @escaping @Sendable () -> Void
    ) {
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.expectedSourceRate = expectedSourceRate
        self.expectedDestinationRate = expectedDestinationRate
        self.onDeviceInvalidated = onDeviceInvalidated
        self.onFormatChanged = onFormatChanged
    }

    func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        for prop in properties {
            switch prop.mSelector {
            case kAudioDevicePropertyDeviceIsAlive:
                let sourceDevice = AudioHardwareDevice(id: sourceID)
                let destDevice = AudioHardwareDevice(id: destinationID)
                if (try? sourceDevice.isAlive) == false {
                    onDeviceInvalidated(.source)
                    return
                }
                if (try? destDevice.isAlive) == false {
                    onDeviceInvalidated(.destination)
                    return
                }
            case kAudioDevicePropertyNominalSampleRate:
                let currentSourceRate = (try? AudioHardwareDevice(id: sourceID).nominalSampleRate) ?? expectedSourceRate
                let currentDestRate = (try? AudioHardwareDevice(id: destinationID).nominalSampleRate) ?? expectedDestinationRate
                if abs(currentSourceRate - expectedSourceRate) > 1.0 || abs(currentDestRate - expectedDestinationRate) > 1.0 {
                    onFormatChanged()
                    return
                }
            default:
                break
            }
        }
    }
}
