import CoreAudio
import CoreAudioTypes
import Foundation
import os
import Synchronization

/// Uniquely identifies a shareable Core Audio passive capture tap configuration.
public struct SharedTapKey: Hashable, Sendable {
    public let sourceUID: String
    public let streamIndices: [Int]
    public let processTarget: ProcessTarget

    public init(sourceUID: String, streamIndices: [Int], processTarget: ProcessTarget) {
        self.sourceUID = sourceUID
        self.streamIndices = streamIndices
        self.processTarget = processTarget
    }
}

/// Realized Core Audio stream metadata for an active shared passive tap.
public struct SharedTapMetadata: Sendable {
    public let inputLayout: RTBufferLayoutMap
    public let logicalSourceToTapChannel: [Int: Int]
    public let sourceSampleRate: Double
    public let tapBufferFrames: Int
    public let inputConfigSummary: String
}

/// Fixed-capacity wait-free snapshot of `RealTimeAudioProcessor` consumers fanned out
/// from a single shared Core Audio tap IOProc callback.
public struct TapConsumerSnapshot: @unchecked Sendable {
    public static let maxConsumers = 16

    public var count: Int
    public var processors: InlineArray<16, UnsafeMutableRawPointer?>

    public init() {
        self.count = 0
        self.processors = InlineArray(repeating: nil)
    }
}

/// Wait-free fan-out dispatcher invoked directly on the single shared Core Audio tap thread.
public final class SharedTapConsumerDispatcher: @unchecked Sendable {
    private let snapshotBuffer = LockFreeTripleBuffer(initialValue: TapConsumerSnapshot())

    public init() {}

    /// Publishes the active list of consumer processors from the control thread.
    public func publish(_ processors: [RealTimeAudioProcessor]) {
        var snapshot = TapConsumerSnapshot()
        let limit = min(processors.count, TapConsumerSnapshot.maxConsumers)
        for i in 0..<limit {
            snapshot.processors[i] = Unmanaged.passUnretained(processors[i]).toOpaque()
        }
        snapshot.count = limit
        snapshotBuffer.write(snapshot)
    }

    /// Real-time audio thread: fans out `inInputData` to all attached bridge processors
    /// with zero heap allocations, zero locks, and zero ARC traffic.
    @inline(__always)
    public func dispatch(inInputData: UnsafePointer<AudioBufferList>, frameCount: Int) {
        let ptr = snapshotBuffer.readLatestPointer()
        let count = ptr.pointee.count
        for i in 0..<count {
            if let raw = ptr.pointee.processors[i] {
                let processor = Unmanaged<RealTimeAudioProcessor>.fromOpaque(raw).takeUnretainedValue()
                processor.processTapInput(inInputData: inInputData, frameCount: frameCount)
            }
        }
    }
}

/// C-compatible Core Audio IOProc for a shared Tap-Only Private Aggregate device.
public func interceptorSharedTapInputIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else { return noErr }
    let dispatcher = Unmanaged<SharedTapConsumerDispatcher>.fromOpaque(clientData).takeUnretainedValue()

    let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    var frameCount = 0
    for b in 0..<inBuffers.count {
        let ch = Int(inBuffers[b].mNumberChannels)
        if ch > 0 && inBuffers[b].mDataByteSize > 0 && inBuffers[b].mData != nil {
            frameCount = Int(inBuffers[b].mDataByteSize) / (MemoryLayout<Float>.size * ch)
            break
        }
    }

    if frameCount > 0 {
        dispatcher.dispatch(inInputData: inInputData, frameCount: frameCount)
    }
    return noErr
}

/// Coordinates shared Tap-Only Private Aggregate capture sessions so multiple Virtual Devices
/// tapping the same source interface (e.g. DVS → Reference + DVS → LFE) reuse ONE single Core Audio
/// tap and ONE single capture IOProc thread, eliminating duplicate `coreaudiod` IPC and CPU work.
public final class SharedSourceTapHub: @unchecked Sendable {
    public static let shared = SharedSourceTapHub()

    public final class Lease: @unchecked Sendable {
        public let metadata: SharedTapMetadata
        private let onRelease: @Sendable () -> Void
        private let released = Atomic<Bool>(false)

        fileprivate init(metadata: SharedTapMetadata, onRelease: @escaping @Sendable () -> Void) {
            self.metadata = metadata
            self.onRelease = onRelease
        }

        deinit {
            release()
        }

        public func release() {
            let (exchanged, _) = released.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing)
            if exchanged {
                onRelease()
            }
        }
    }

    private final class Session: @unchecked Sendable {
        let key: SharedTapKey
        let taps: [AudioHardwareTap]
        let aggregate: AudioHardwareAggregateDevice
        let ioProcID: AudioDeviceIOProcID
        let dispatcher: SharedTapConsumerDispatcher
        let metadata: SharedTapMetadata
        var consumers: [(id: UUID, processor: RealTimeAudioProcessor)] = []
        var isInvalidated = false
        var isStopped = false

        init(
            key: SharedTapKey,
            taps: [AudioHardwareTap],
            aggregate: AudioHardwareAggregateDevice,
            ioProcID: AudioDeviceIOProcID,
            dispatcher: SharedTapConsumerDispatcher,
            metadata: SharedTapMetadata
        ) {
            self.key = key
            self.taps = taps
            self.aggregate = aggregate
            self.ioProcID = ioProcID
            self.dispatcher = dispatcher
            self.metadata = metadata
        }

        func teardown(logger: Logger) {
            guard !isStopped else { return }
            isStopped = true
            dispatcher.publish([])

            let stopStatus = AudioDeviceStop(aggregate.id, ioProcID)
            if stopStatus != noErr {
                logger.warning("Shared tap AudioDeviceStop returned OSStatus \(stopStatus)")
            }
            let destroyStatus = AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
            if destroyStatus != noErr {
                logger.warning("Shared tap AudioDeviceDestroyIOProcID returned OSStatus \(destroyStatus)")
            }

            let system = AudioHardwareSystem.shared
            try? system.destroyAggregateDevice(aggregate)
            for tap in taps {
                try? system.destroyProcessTap(tap)
            }
        }
    }

    private let logger = Logger(subsystem: "com.interceptor.audio", category: "SharedSourceTapHub")
    private let lock = Mutex<Void>(())
    private var sessions: [SharedTapKey: Session] = [:]
    private var retiredGraceProcessors: [RealTimeAudioProcessor] = []
    private let graceQueue = DispatchQueue(label: "com.interceptor.audio.tap-grace", qos: .utility)

    public init() {}

    /// Attaches `processor` to an existing shared capture tap for `key` (or creates a new one if needed).
    /// Calls `prepareProcessor(metadata)` BEFORE exposing `processor` to the real-time tap thread.
    public func acquire(
        sourceDevice: AudioDeviceDescriptor,
        coreSource: AudioHardwareDevice,
        streamIndices: [Int],
        processTarget: ProcessTarget,
        selfProcessObjectID: AudioObjectID?,
        processor: RealTimeAudioProcessor,
        prepareProcessor: (SharedTapMetadata) throws -> Void
    ) throws -> Lease {
        let key = SharedTapKey(
            sourceUID: sourceDevice.uid,
            streamIndices: streamIndices,
            processTarget: processTarget
        )

        let session: Session = try lock.withLock { _ in
            if let existing = sessions[key],
               !existing.isInvalidated,
               existing.consumers.count < TapConsumerSnapshot.maxConsumers {
                return existing
            }
            let created = try createSession(
                key: key,
                sourceDevice: sourceDevice,
                coreSource: coreSource,
                selfProcessObjectID: selfProcessObjectID
            )
            sessions[key] = created
            return created
        }

        do {
            try prepareProcessor(session.metadata)
        } catch {
            cleanupIfUnused(session: session)
            throw error
        }

        let leaseID = UUID()
        lock.withLock { _ in
            session.consumers.append((id: leaseID, processor: processor))
            session.dispatcher.publish(session.consumers.map(\.processor))
            logger.info(
                "Attached consumer to shared tap [\(sourceDevice.name), consumers=\(session.consumers.count)]"
            )
        }

        return Lease(metadata: session.metadata) { [weak self] in
            self?.releaseLease(leaseID: leaseID, session: session)
        }
    }

    /// Marks any existing shared session for `sourceUID` stale so subsequent restarts create a fresh tap
    /// (e.g. after a source sample rate or stream configuration change).
    public func invalidateSessions(forSourceUID sourceUID: String) {
        lock.withLock { _ in
            for (_, session) in sessions where session.key.sourceUID == sourceUID {
                session.isInvalidated = true
            }
        }
    }

    // MARK: - Internal

    private func cleanupIfUnused(session: Session) {
        let shouldTeardown: Bool = lock.withLock { _ in
            guard session.consumers.isEmpty else { return false }
            if sessions[session.key] === session {
                sessions.removeValue(forKey: session.key)
            }
            return true
        }
        if shouldTeardown {
            session.teardown(logger: logger)
        }
    }

    private func releaseLease(leaseID: UUID, session: Session) {
        var detachedProcessor: RealTimeAudioProcessor?
        var shouldTeardown = false

        lock.withLock { _ in
            if let idx = session.consumers.firstIndex(where: { $0.id == leaseID }) {
                detachedProcessor = session.consumers.remove(at: idx).processor
            }
            session.dispatcher.publish(session.consumers.map(\.processor))

            if session.consumers.isEmpty {
                if sessions[session.key] === session {
                    sessions.removeValue(forKey: session.key)
                }
                shouldTeardown = true
            } else if let detached = detachedProcessor {
                // Keep detached processor strongly alive for a short grace window so an in-flight
                // RT callback on another core can finish safely without ever locking the audio thread.
                retiredGraceProcessors.append(detached)
            }
        }

        if shouldTeardown {
            session.teardown(logger: logger)
            logger.info("Stopped unused shared tap [\(session.key.sourceUID)]")
        } else if let detached = detachedProcessor {
            graceQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.lock.withLock { _ in
                    if let idx = self?.retiredGraceProcessors.firstIndex(where: { $0 === detached }) {
                        self?.retiredGraceProcessors.remove(at: idx)
                    }
                }
            }
        }
    }

    private func createSession(
        key: SharedTapKey,
        sourceDevice: AudioDeviceDescriptor,
        coreSource: AudioHardwareDevice,
        selfProcessObjectID: AudioObjectID?
    ) throws -> Session {
        let system = AudioHardwareSystem.shared
        var createdTaps: [AudioHardwareTap] = []
        var tapDicts: [[String: Any]] = []
        var tapStreamMeta: [(streamIndex: Int, fallbackChannels: Int)] = []

        do {
            for streamIndex in key.streamIndices {
                let tapDescription = makeTapDescription(
                    sourceUID: sourceDevice.uid,
                    streamIndex: streamIndex,
                    processTarget: key.processTarget,
                    selfProcessObjectID: selfProcessObjectID
                )

                guard let tap = try system.makeProcessTap(description: tapDescription) else {
                    throw AudioTapBridgeError.tapCreationFailed(kAudioHardwareUnspecifiedError)
                }
                createdTaps.append(tap)

                let tapUID = try tap.uid
                let tapFormat = try? tap.format
                let fallbackChannels: Int = {
                    if let fmtCh = tapFormat?.mChannelsPerFrame, fmtCh > 0 {
                        return Int(fmtCh)
                    }
                    return sourceDevice.outputStreams.first(where: { $0.streamIndex == streamIndex })?.channelCount ?? 2
                }()
                tapStreamMeta.append((streamIndex: streamIndex, fallbackChannels: fallbackChannels))

                tapDicts.append([
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: false
                ])
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

        let aggregateUID = CoreAudioDeviceCatalog.privateAggregateUIDPrefix + UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "Interceptor Shared Tap Capture",
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

        let inputConfig = (try? aggregate.inputStreamConfiguration) ?? []
        let inputLayout = RTBufferLayoutMap(streamConfiguration: inputConfig)
        guard inputLayout.channelCount > 0 else {
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.emptyAggregateStreams
        }

        var logicalToTapChannel: [Int: Int] = [:]
        var tapChannelCursor = 0
        let useActualInputConfig = inputConfig.count == tapStreamMeta.count
        for (idx, meta) in tapStreamMeta.enumerated() {
            let actualStreamChannels = useActualInputConfig
                ? Int(inputConfig[idx].mNumberChannels)
                : meta.fallbackChannels
            if let streamDesc = sourceDevice.outputStreams.first(where: { $0.streamIndex == meta.streamIndex }) {
                let mappedCount = min(actualStreamChannels, streamDesc.channelCount)
                for localIdx in 0..<mappedCount {
                    logicalToTapChannel[streamDesc.startingChannel + localIdx] = tapChannelCursor + localIdx
                }
            }
            tapChannelCursor += actualStreamChannels
        }

        let coreSourceRate = (try? coreSource.nominalSampleRate) ?? sourceDevice.nominalSampleRate
        let actualSourceRate = (try? aggregate.nominalSampleRate) ?? coreSourceRate
        let actualTapFrames = (try? aggregate.bufferFrameSize) ?? sourceDevice.bufferFrameSize
        let inputSummary = inputConfig.map { "\($0.mNumberChannels)ch" }.joined(separator: "+")

        let dispatcher = SharedTapConsumerDispatcher()
        let clientData = Unmanaged.passUnretained(dispatcher).toOpaque()

        var createdIOProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcID(
            aggregate.id,
            interceptorSharedTapInputIOProc,
            clientData,
            &createdIOProcID
        )
        guard createStatus == noErr, let validIOProcID = createdIOProcID else {
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.ioProcRegistrationFailed(createStatus)
        }

        let startStatus = AudioDeviceStart(aggregate.id, validIOProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregate.id, validIOProcID)
            cleanupPartial(taps: createdTaps, aggregate: aggregate)
            throw AudioTapBridgeError.deviceStartFailed(startStatus)
        }

        let metadata = SharedTapMetadata(
            inputLayout: inputLayout,
            logicalSourceToTapChannel: logicalToTapChannel,
            sourceSampleRate: actualSourceRate,
            tapBufferFrames: actualTapFrames,
            inputConfigSummary: inputSummary
        )

        return Session(
            key: key,
            taps: createdTaps,
            aggregate: aggregate,
            ioProcID: validIOProcID,
            dispatcher: dispatcher,
            metadata: metadata
        )
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
            description.bundleIDs = [Bundle.main.bundleIdentifier ?? "com.interceptor.audio"]

        case let .application(bundleID, _):
            description = CATapDescription()
            description.deviceUID = sourceUID
            description.stream = UInt(streamIndex)
            description.isExclusive = false
            description.bundleIDs = [bundleID]
            description.isProcessRestoreEnabled = true
        }

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
}
