import CoreAudio
import CoreAudioTypes
import Foundation

/// Single flattened mono channel-to-channel patch evaluated inside the real-time audio callback.
public struct RTChannelPatch: Sendable, Equatable {
    /// Zero-based logical channel index inside the tapped input `AudioBufferList`.
    public var sourceChannel: Int16
    /// Zero-based logical channel index inside the monitor destination `AudioBufferList`.
    public var destinationChannel: Int16
    /// Active flag.
    public var isActive: Bool

    public init(
        sourceChannel: Int16 = 0,
        destinationChannel: Int16 = 0,
        isActive: Bool = false
    ) {
        self.sourceChannel = sourceChannel
        self.destinationChannel = destinationChannel
        self.isActive = isActive
    }
}

/// Complete lock-free routing snapshot published to the real-time audio thread.
public struct RTRoutingSnapshot: Sendable {
    public static let maxPatches = 64

    public var patchCount: Int
    public var patches: InlineArray<64, RTChannelPatch>

    public init() {
        self.patchCount = 0
        self.patches = InlineArray(repeating: RTChannelPatch())
    }

    /// Compiles high-level mono `ChannelRoute` models into a real-time patch snapshot.
    public static func build(
        routes: [ChannelRoute],
        sourceLogicalToTapChannel: ((Int) -> Int?)? = nil
    ) -> RTRoutingSnapshot {
        var snapshot = RTRoutingSnapshot()
        var idx = 0

        for route in routes where route.isEnabled {
            guard idx < maxPatches else { break }
            let tapZeroBased: Int
            if let resolver = sourceLogicalToTapChannel {
                guard let resolved = resolver(route.sourceChannel) else { continue }
                tapZeroBased = resolved
            } else {
                tapZeroBased = route.sourceChannel - 1
            }
            let dstZeroBased = route.destinationChannel - 1
            guard tapZeroBased >= 0, tapZeroBased < RTBufferLayoutMap.maxChannels,
                  dstZeroBased >= 0, dstZeroBased < RTBufferLayoutMap.maxChannels else {
                continue
            }
            snapshot.patches[idx] = RTChannelPatch(
                sourceChannel: Int16(tapZeroBased),
                destinationChannel: Int16(dstZeroBased),
                isActive: true
            )
            idx += 1
        }

        snapshot.patchCount = idx
        return snapshot
    }
}

/// Pure, zero-allocation, lock-free real-time unity-gain audio router invoked directly
/// by Core Audio's `AudioDeviceIOProc`s.
///
/// Supports both single-device loopback (`process`) and decoupled pro-audio tap-to-monitor
/// operation (`processTapInput` + `processMonitorOutput`) through `ringBuffer`, resampling
/// ONLY the active routed mono channels instead of 64+ unused hardware tap channels.
public final class RealTimeAudioProcessor: @unchecked Sendable {
    public let routingBuffer: LockFreeTripleBuffer<RTRoutingSnapshot>
    public let inputRoutingBuffer: LockFreeTripleBuffer<RTRoutingSnapshot>
    public let ringBuffer: LockFreeAudioRingBuffer
    public let meterBank: AtomicMeterBank

    /// Configured before `AudioDeviceStart`; read-only while IOProcs are running.
    public private(set) var inputLayout: RTBufferLayoutMap
    public private(set) var outputLayout: RTBufferLayoutMap

    public init(
        initialSnapshot: RTRoutingSnapshot = RTRoutingSnapshot(),
        inputLayout: RTBufferLayoutMap = RTBufferLayoutMap(),
        outputLayout: RTBufferLayoutMap = RTBufferLayoutMap()
    ) {
        self.routingBuffer = LockFreeTripleBuffer(initialValue: initialSnapshot)
        self.inputRoutingBuffer = LockFreeTripleBuffer(initialValue: initialSnapshot)
        self.ringBuffer = LockFreeAudioRingBuffer()
        self.meterBank = AtomicMeterBank()
        self.inputLayout = inputLayout
        self.outputLayout = outputLayout
    }

    /// Updates buffer layouts while the audio devices are stopped.
    public func configure(
        inputLayout: RTBufferLayoutMap,
        outputLayout: RTBufferLayoutMap
    ) {
        self.inputLayout = inputLayout
        self.outputLayout = outputLayout
    }

    /// Publishes updated mono channel patches to both real-time threads without stopping audio.
    public func updateRouting(_ snapshot: RTRoutingSnapshot) {
        inputRoutingBuffer.write(snapshot)
        routingBuffer.write(snapshot)
    }

    /// Producer audio thread (Tap-Only Private Aggregate, zero ASRC):
    /// extracts ONLY active routed mono channels into `ringBuffer` and tracks lightweight visual peak gain.
    @inline(__always)
    public func processTapInput(
        inInputData: UnsafePointer<AudioBufferList>?,
        frameCount: Int
    ) {
        guard frameCount > 0, let inABL = inInputData else { return }
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inABL))
        let inBufCount = inBuffers.count

        let snapshotPtr = inputRoutingBuffer.readLatestPointer()
        let patchCount = min(snapshotPtr.pointee.patchCount, LockFreeAudioRingBuffer.maxChannels)
        guard patchCount > 0 else { return }

        let baseWriteFrame = ringBuffer.beginWrite(frameCount: frameCount)

        for p in 0..<patchCount {
            let patch = snapshotPtr.pointee.patches[p]
            guard patch.isActive else {
                for f in 0..<frameCount {
                    ringBuffer.storeSample(0.0, slot: p, frame: baseWriteFrame &+ UInt64(f))
                }
                continue
            }

            let srcChannel = Int(patch.sourceChannel)
            let srcAddr = inputLayout[srcChannel]
            guard srcAddr.isValid else {
                for f in 0..<frameCount {
                    ringBuffer.storeSample(0.0, slot: p, frame: baseWriteFrame &+ UInt64(f))
                }
                continue
            }

            let srcBufIdx = Int(srcAddr.bufferIndex)
            let srcStride = Int(srcAddr.stride)
            let srcOffset = Int(srcAddr.channelOffset)
            guard srcBufIdx < inBufCount,
                  Int(inBuffers[srcBufIdx].mNumberChannels) == srcStride,
                  let srcRaw = inBuffers[srcBufIdx].mData else {
                for f in 0..<frameCount {
                    ringBuffer.storeSample(0.0, slot: p, frame: baseWriteFrame &+ UInt64(f))
                }
                continue
            }

            let srcMax = Int(inBuffers[srcBufIdx].mDataByteSize) / MemoryLayout<Float>.size
            guard srcOffset + (frameCount - 1) * srcStride < srcMax else {
                for f in 0..<frameCount {
                    ringBuffer.storeSample(0.0, slot: p, frame: baseWriteFrame &+ UInt64(f))
                }
                continue
            }

            let srcPtr = srcRaw.assumingMemoryBound(to: Float.self)
            var sIdx = srcOffset
            var peak: Float = 0.0

            for f in 0..<frameCount {
                let sample = srcPtr[sIdx]
                ringBuffer.storeSample(sample, slot: p, frame: baseWriteFrame &+ UInt64(f))
                let mag = fabsf(sample)
                if mag > peak { peak = mag }
                sIdx += srcStride
            }

            // Visual gain peak only (zero sqrtf RMS overhead on the real-time audio thread).
            meterBank.recordInput(channel: srcChannel, peak: peak, rms: peak * 0.70710678)
        }

        ringBuffer.commitWrite(newWriteIndex: baseWriteFrame &+ UInt64(frameCount))
    }

    /// Consumer audio thread (Direct Monitor Output Device):
    /// reads ONLY active routed channels from `ringBuffer` with PI drift compensation + cubic Hermite
    /// resampling and sums each slot into its patched monitor output channel.
    @inline(__always)
    public func processMonitorOutput(
        outOutputData: UnsafeMutablePointer<AudioBufferList>?,
        frameCount: Int
    ) {
        guard frameCount > 0, let outABL = outOutputData else { return }

        let outBuffers = UnsafeMutableAudioBufferListPointer(outABL)
        let outBufCount = outBuffers.count

        for b in 0..<outBufCount {
            let byteCount = Int(outBuffers[b].mDataByteSize)
            if let data = outBuffers[b].mData, byteCount > 0 {
                memset(data, 0, byteCount)
            }
        }

        let snapshotPtr = routingBuffer.readLatestPointer()
        let patchCount = min(snapshotPtr.pointee.patchCount, LockFreeAudioRingBuffer.maxChannels)
        guard patchCount > 0 else { return }

        _ = ringBuffer.readResampled(
            activeSlots: patchCount,
            outputFrameCount: frameCount,
            onXRun: { [meterBank] in
                meterBank.recordXRun()
            }
        ) { slot, frame, sample in
            let patch = snapshotPtr.pointee.patches[slot]
            guard patch.isActive else { return }
            let dstChannel = Int(patch.destinationChannel)
            let dstAddr = outputLayout[dstChannel]
            guard dstAddr.isValid else { return }

            let dstBufIdx = Int(dstAddr.bufferIndex)
            let dstStride = Int(dstAddr.stride)
            let dstOffset = Int(dstAddr.channelOffset)
            guard dstBufIdx < outBufCount,
                  Int(outBuffers[dstBufIdx].mNumberChannels) == dstStride,
                  let dstRaw = outBuffers[dstBufIdx].mData else { return }

            let dstMax = Int(outBuffers[dstBufIdx].mDataByteSize) / MemoryLayout<Float>.size
            let dIdx = dstOffset + frame * dstStride
            guard dIdx < dstMax else { return }

            dstRaw.assumingMemoryBound(to: Float.self)[dIdx] += sample
        }
    }

    /// Core real-time render routine: zero heap allocations, zero locks, bit-transparent unity routing.
    @inline(__always)
    public func process(
        inInputData: UnsafePointer<AudioBufferList>?,
        outOutputData: UnsafeMutablePointer<AudioBufferList>?,
        frameCount: Int
    ) {
        guard frameCount > 0, let outABL = outOutputData else { return }

        let outBuffers = UnsafeMutableAudioBufferListPointer(outABL)
        let outBufCount = outBuffers.count

        // 1. Always clear every output buffer to silence first so unrouted channels never leak noise.
        for b in 0..<outBufCount {
            let byteCount = Int(outBuffers[b].mDataByteSize)
            if let data = outBuffers[b].mData, byteCount > 0 {
                memset(data, 0, byteCount)
            }
        }

        guard let inABL = inInputData else { return }
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inABL))
        let inBufCount = inBuffers.count

        // 2. Fetch the latest wait-free routing snapshot.
        let snapshotPtr = routingBuffer.readLatestPointer()
        let patchCount = snapshotPtr.pointee.patchCount

        // 3. Route active mono patches (unity gain pass-through) and track subtle signal activity.
        for p in 0..<patchCount {
            let patch = snapshotPtr.pointee.patches[p]
            guard patch.isActive else { continue }
            let srcChannel = Int(patch.sourceChannel)
            let dstChannel = Int(patch.destinationChannel)
            let srcAddr = inputLayout[srcChannel]
            let dstAddr = outputLayout[dstChannel]
            guard srcAddr.isValid, dstAddr.isValid else { continue }

            let srcBufIdx = Int(srcAddr.bufferIndex)
            let dstBufIdx = Int(dstAddr.bufferIndex)
            guard srcBufIdx < inBufCount, dstBufIdx < outBufCount,
                  let srcRaw = inBuffers[srcBufIdx].mData,
                  let dstRaw = outBuffers[dstBufIdx].mData else { continue }

            let srcStride = Int(srcAddr.stride)
            let srcOffset = Int(srcAddr.channelOffset)
            let dstStride = Int(dstAddr.stride)
            let dstOffset = Int(dstAddr.channelOffset)

            // Verify runtime channel stride matches the precomputed buffer layout before indexing.
            guard Int(inBuffers[srcBufIdx].mNumberChannels) == srcStride,
                  Int(outBuffers[dstBufIdx].mNumberChannels) == dstStride else { continue }

            let srcMax = Int(inBuffers[srcBufIdx].mDataByteSize) / MemoryLayout<Float>.size
            let dstMax = Int(outBuffers[dstBufIdx].mDataByteSize) / MemoryLayout<Float>.size
            guard srcOffset + (frameCount - 1) * srcStride < srcMax,
                  dstOffset + (frameCount - 1) * dstStride < dstMax else { continue }

            let srcPtr = srcRaw.assumingMemoryBound(to: Float.self)
            let dstPtr = dstRaw.assumingMemoryBound(to: Float.self)

            var sIdx = srcOffset
            var dIdx = dstOffset
            var peak: Float = 0.0
            var sumSq: Float = 0.0
            for _ in 0..<frameCount {
                let sample = srcPtr[sIdx]
                dstPtr[dIdx] += sample
                let mag = fabsf(sample)
                if mag > peak { peak = mag }
                sumSq += sample * sample
                sIdx += srcStride
                dIdx += dstStride
            }

            let rms = sqrtf(sumSq / Float(frameCount))
            meterBank.recordInput(channel: srcChannel, peak: peak, rms: rms)
        }
    }
}

/// C-compatible Core Audio IOProc trampoline (no Swift closure capture, zero ARC overhead).
public func interceptorAudioDeviceIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else { return noErr }
    let processor = Unmanaged<RealTimeAudioProcessor>.fromOpaque(clientData).takeUnretainedValue()

    let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
    var frameCount = 0
    for b in 0..<outBuffers.count {
        let ch = Int(outBuffers[b].mNumberChannels)
        if ch > 0 && outBuffers[b].mDataByteSize > 0 {
            frameCount = Int(outBuffers[b].mDataByteSize) / (MemoryLayout<Float>.size * ch)
            break
        }
    }

    if frameCount > 0 {
        processor.process(inInputData: inInputData, outOutputData: outOutputData, frameCount: frameCount)
    }
    return noErr
}

/// C-compatible Core Audio IOProc for the Tap-Only Private Aggregate input thread (zero ASRC).
public func interceptorTapInputIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else { return noErr }
    let processor = Unmanaged<RealTimeAudioProcessor>.fromOpaque(clientData).takeUnretainedValue()

    let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    var frameCount = 0
    for b in 0..<inBuffers.count {
        let ch = Int(inBuffers[b].mNumberChannels)
        if ch > 0 && inBuffers[b].mDataByteSize > 0 {
            frameCount = Int(inBuffers[b].mDataByteSize) / (MemoryLayout<Float>.size * ch)
            break
        }
    }

    if frameCount > 0 {
        processor.processTapInput(inInputData: inInputData, frameCount: frameCount)
    }
    return noErr
}

/// C-compatible Core Audio IOProc for the direct Monitor Output device thread.
public func interceptorMonitorOutputIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else { return noErr }
    let processor = Unmanaged<RealTimeAudioProcessor>.fromOpaque(clientData).takeUnretainedValue()

    let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
    var frameCount = 0
    for b in 0..<outBuffers.count {
        let ch = Int(outBuffers[b].mNumberChannels)
        if ch > 0 && outBuffers[b].mDataByteSize > 0 {
            frameCount = Int(outBuffers[b].mDataByteSize) / (MemoryLayout<Float>.size * ch)
            break
        }
    }

    if frameCount > 0 {
        processor.processMonitorOutput(outOutputData: outOutputData, frameCount: frameCount)
    }
    return noErr
}
