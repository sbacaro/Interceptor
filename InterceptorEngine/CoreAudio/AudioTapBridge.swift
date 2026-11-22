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
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false

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

                // Attach SubTap with Core Audio native drift compensation at maximum quality (0x7F = 127).
                let subTapDict: [String: Any] = [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMaxQuality
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

        // 3. Create the private Aggregate Device combining Destination (Clock Master) + SubTap(s).
        //    The source interface is NEVER added as a subdevice — its clock stays 100% isolated.
        let aggregateUID = CoreAudioDeviceCatalog.privateAggregateUIDPrefix + UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "Interceptor Private Monitor Bridge",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: destinationDevice.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: destinationDevice.uid
                ]
            ],
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

        // 4. Optional preferred buffer size on the private aggregate (never touches source interface).
        if let preferredFrames = preferredBufferFrames, preferredFrames >= 32 {
            try? aggregate.setBufferFrameSize(preferredFrames)
        }

        // 5. Inspect actual input/output stream layouts on the private aggregate device.
        //    When the monitor destination has its own input streams (e.g. a physical audio interface
        //    or virtual loopback driver), Core Audio places those input buffers BEFORE the SubTap
        //    input buffers. Skip them so logical channel 0 always maps directly to the first SubTap channel.
        let destInputConfig = (try? coreDest.inputStreamConfiguration) ?? []
        let destInputBufferCount = destInputConfig.count
        let inputConfig = (try? aggregate.inputStreamConfiguration) ?? []
        let outputConfig = (try? aggregate.outputStreamConfiguration) ?? []
        let inputLayout = RTBufferLayoutMap(
            streamConfiguration: inputConfig,
            skippingLeadingBuffers: destInputBufferCount
        )
        let outputLayout = RTBufferLayoutMap(streamConfiguration: outputConfig)

        guard inputLayout.channelCount > 0, outputLayout.channelCount > 0 else {
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.emptyAggregateStreams
        }

        let actualDestRate = (try? aggregate.nominalSampleRate) ?? destinationDevice.nominalSampleRate
        let actualSourceRate = (try? coreSource.nominalSampleRate) ?? sourceDevice.nominalSampleRate
        let actualBufferFrames = (try? aggregate.bufferFrameSize) ?? destinationDevice.bufferFrameSize
        let destOutputLatency = (try? aggregate.outputLatency) ?? destinationDevice.outputLatencyFrames
        let destSafetyOffset = (try? aggregate.outputSafetyOffset) ?? 0
        let totalLatencyFrames = actualBufferFrames + destOutputLatency + destSafetyOffset
        let latencyMs = actualDestRate > 0 ? (Double(totalLatencyFrames) / actualDestRate) * 1000.0 : 0.0

        // 6. Configure real-time DSP processor BEFORE starting IOProc.
        let initialSnapshot = RTRoutingSnapshot.build(
            routes: routes,
            sourceLogicalToTapChannel: { logicalToTapChannel[$0] }
        )
        processor.configure(
            inputLayout: inputLayout,
            outputLayout: outputLayout
        )
        processor.updateRouting(initialSnapshot)
        processor.meterBank.resetAll()

        // 7. Register C-function IOProc, disable unused destination input streams, and start Core Audio device.
        var createdIOProcID: AudioDeviceIOProcID?
        let clientData = Unmanaged.passUnretained(processor).toOpaque()
        let createStatus = AudioDeviceCreateIOProcID(
            aggregate.id,
            interceptorAudioDeviceIOProc,
            clientData,
            &createdIOProcID
        )
        guard createStatus == noErr, let validIOProcID = createdIOProcID else {
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.ioProcRegistrationFailed(createStatus)
        }

        let destInputStreamCount = ((try? coreDest.streams) ?? []).filter { (try? $0.direction) == .input }.count
        let aggInputStreamCount = ((try? aggregate.streams) ?? []).filter { (try? $0.direction) == .input }.count
        if destInputStreamCount > 0 && aggInputStreamCount > destInputStreamCount {
            configureTapOnlyInputStreamUsage(
                aggregateID: aggregate.id,
                ioProcID: validIOProcID,
                totalInputStreams: aggInputStreamCount,
                skippedLeadingStreams: destInputStreamCount
            )
        }

        let startStatus = AudioDeviceStart(aggregate.id, validIOProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate.id, validIOProcID)
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.deviceStartFailed(startStatus)
        }

        self.activeTaps = createdTaps
        self.aggregateDevice = aggregate
        self.ioProcID = validIOProcID
        self.isStarted = true

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
            bufferFrames: actualBufferFrames,
            estimatedLatencyMs: latencyMs,
            tappedStreamIndices: streamIndices,
            tappedInputChannels: inputLayout.channelCount,
            destinationOutputChannels: outputLayout.channelCount,
            logicalSourceToTapChannel: logicalToTapChannel
        )
        self.activeInfo = info

        let aggInSummary = inputConfig.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")
        let aggOutSummary = outputConfig.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")
        logger.info(
            "Started passive bridge: \(sourceDevice.name) (\(actualSourceRate) Hz, tap \(inputLayout.channelCount) ch, aggIn=[\(aggInSummary)], skippedDestInBufs=\(destInputBufferCount)) → \(destinationDevice.name) (\(actualDestRate) Hz, aggOut=[\(aggOutSummary)], \(actualBufferFrames) fr)"
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

    /// Stops audio I/O and destroys the private aggregate device and Core Audio tap(s) in strict order.
    public func stop() {
        detachDeviceListeners()

        if let aggregate = aggregateDevice, let procID = ioProcID {
            if isStarted {
                let stopStatus = AudioDeviceStop(aggregate.id, procID)
                if stopStatus != noErr {
                    logger.warning("AudioDeviceStop returned OSStatus \(stopStatus)")
                }
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregate.id, procID)
            if destroyStatus != noErr {
                logger.warning("AudioDeviceDestroyIOProcID returned OSStatus \(destroyStatus)")
            }
        }

        cleanupPartial(taps: activeTaps, aggregate: aggregateDevice)

        activeTaps.removeAll()
        aggregateDevice = nil
        ioProcID = nil
        isStarted = false
        activeInfo = nil
        processor.meterBank.resetAll()
    }

    // MARK: - Helpers

    /// Disables the monitor destination subdevice's own input streams on this IOProc so Core Audio
    /// only captures from the SubTap input streams (avoiding wasted DMA and unnecessary mic access).
    private func configureTapOnlyInputStreamUsage(
        aggregateID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        totalInputStreams: Int,
        skippedLeadingStreams: Int
    ) {
        guard totalInputStreams > 0 else { return }
        let byteSize = MemoryLayout<AudioHardwareIOProcStreamUsage>.size
            + max(0, totalInputStreams - 1) * MemoryLayout<UInt32>.size
        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: byteSize,
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { rawBuffer.deallocate() }

        let usage = rawBuffer.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(totalInputStreams)

        if let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) {
            let flags = rawBuffer.advanced(by: flagsOffset).assumingMemoryBound(to: UInt32.self)
            for i in 0..<totalInputStreams {
                flags[i] = i < skippedLeadingStreams ? 0 : 1
            }
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            aggregateID,
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
