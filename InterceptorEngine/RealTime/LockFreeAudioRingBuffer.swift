import Foundation
import Synchronization

/// Wait-free Single-Producer Single-Consumer (SPSC) planar audio ring buffer with
/// integrated PI-controlled 4-point cubic Hermite drift compensation and sample-rate conversion.
///
/// Designed for pro-audio decoupling: each active source channel writes to its own dedicated
/// planar slot (`0..<128`), completely eliminating cross-channel pops or stale-frame reads when
/// routes are edited, fanned out, or muted live.
public final class LockFreeAudioRingBuffer: @unchecked Sendable {
    public static let maxChannels = 128
    public static let capacityFrames = 16_384
    private static let mask: UInt64 = UInt64(capacityFrames - 1)
    private static let slotMicroFadeLength: UInt64 = 32

    /// Immutable per-block consumer render parameters computed once per output callback in `beginRead`.
    public struct ReadBlockPlan: Sendable {
        public let startFrame: UInt64
        public let fractionalPhase: Double
        public let stepRatio: Double
        public let outputFrameCount: Int
        public let fadeInRemaining: Int
        public let fadeInLength: Int
        public let canUseExactCopy: Bool
        public let endFrame: UInt64
        public let endFractionalPhase: Double
        public let endFadeInRemaining: Int
    }

    public enum ReadBeginResult: Sendable {
        case notReady(xrun: Bool)
        case ready(plan: ReadBlockPlan, xrun: Bool)
    }

    /// Contiguous planar storage: channel `c` occupies `[c * capacityFrames ..< (c + 1) * capacityFrames]`.
    /// Allocated with `calloc` so unused virtual channel slots consume zero physical RAM pages.
    private let storage: UnsafeMutablePointer<Float>

    /// Per-slot monotonic frame fence (`UInt64.max` when inactive).
    private let slotValidFromFrame: UnsafeMutablePointer<Atomic<UInt64>>

    /// Monotonic frame counters (only producer writes `writeIndex`, only consumer writes `readIndex`).
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)

    /// Consumer-only resampler & PI drift-tracking state (touched exclusively on the output audio thread).
    private var fractionalPhase: Double = 0.0
    private var baseRatio: Double = 1.0
    private var integralError: Double = 0.0
    private var targetFillFrames: Double = 1024.0
    private var isPrimed: Bool = false
    private var fadeInRemaining: Int = 0
    private let fadeInLength: Int = 64

    public init() {
        let totalFloats = Self.maxChannels * Self.capacityFrames
        guard let raw = calloc(totalFloats, MemoryLayout<Float>.size) else {
            fatalError("Failed to allocate LockFreeAudioRingBuffer storage")
        }
        storage = raw.bindMemory(to: Float.self, capacity: totalFloats)

        slotValidFromFrame = .allocate(capacity: Self.maxChannels)
        for slot in 0..<Self.maxChannels {
            slotValidFromFrame.advanced(by: slot).initialize(to: Atomic<UInt64>(UInt64.max))
        }
    }

    deinit {
        slotValidFromFrame.deinitialize(count: Self.maxChannels)
        slotValidFromFrame.deallocate()
        free(storage)
    }

    /// Configures nominal sample rates and target latency fill while audio I/O is stopped.
    public func configure(
        sourceSampleRate: Double,
        destinationSampleRate: Double,
        sourceBufferFrames: Int,
        destinationBufferFrames: Int
    ) {
        let srcRate = sourceSampleRate > 0 ? sourceSampleRate : 48_000.0
        let dstRate = destinationSampleRate > 0 ? destinationSampleRate : 48_000.0
        baseRatio = srcRate / dstRate

        // Keep enough safety headroom for jitter between independent hardware/software clocks
        // while staying low-latency (~10–30 ms depending on host buffer size).
        let maxBuf = max(64, max(sourceBufferFrames, destinationBufferFrames))
        let scaledBuf = Int(ceil(Double(maxBuf) * max(1.0, baseRatio)))
        let desired = max(512, min(Self.capacityFrames / 2, scaledBuf * 2 + 128))
        targetFillFrames = Double(desired)
        reset()
    }

    /// Resets cursors and invalidates all channel slots (call only when stopped).
    public func reset() {
        writeIndex.store(0, ordering: .relaxed)
        readIndex.store(0, ordering: .relaxed)
        for slot in 0..<Self.maxChannels {
            slotValidFromFrame.advanced(by: slot).pointee.store(UInt64.max, ordering: .relaxed)
        }
        fractionalPhase = 0.0
        integralError = 0.0
        isPrimed = false
        fadeInRemaining = 0
    }

    /// Current estimated latency of the drift buffer in milliseconds at the source sample rate.
    public func estimatedBufferLatencyMs(sourceSampleRate: Double) -> Double {
        guard sourceSampleRate > 0 else { return 0 }
        return (targetFillFrames / sourceSampleRate) * 1000.0
    }

    // MARK: - Producer (Tap Input IOProc Thread)

    /// Returns the starting frame index for writing `frameCount` frames into planar channel slots.
    /// Call `commitWrite(newWriteIndex:)` after populating active channel slots.
    @inline(__always)
    public func beginWrite(frameCount: Int) -> UInt64 {
        writeIndex.load(ordering: .relaxed)
    }

    /// Writes a single sample into planar slot `slot` at monotonic frame `frame`.
    @inline(__always)
    public func storeSample(_ sample: Float, slot: Int, frame: UInt64) {
        let idx = slot * Self.capacityFrames + Int(frame & Self.mask)
        storage[idx] = sample
    }

    /// Marks `slot` as containing valid audio starting from monotonic frame `frame`.
    @inline(__always)
    public func markSlotActive(_ slot: Int, validFrom frame: UInt64) {
        guard slot >= 0, slot < Self.maxChannels else { return }
        slotValidFromFrame.advanced(by: slot).pointee.store(frame, ordering: .releasing)
    }

    /// Marks `slot` inactive (`UInt64.max`) so consumers immediately stop reading stale tail frames.
    @inline(__always)
    public func markSlotInactive(_ slot: Int) {
        guard slot >= 0, slot < Self.maxChannels else { return }
        slotValidFromFrame.advanced(by: slot).pointee.store(UInt64.max, ordering: .releasing)
    }

    /// Reads the monotonic frame from which `slot` holds valid producer samples (`UInt64.max` if inactive).
    @inline(__always)
    public func slotValidFrom(_ slot: Int) -> UInt64 {
        guard slot >= 0, slot < Self.maxChannels else { return UInt64.max }
        return slotValidFromFrame.advanced(by: slot).pointee.load(ordering: .acquiring)
    }

    /// Publishes newly written frames to the consumer thread.
    @inline(__always)
    public func commitWrite(newWriteIndex: UInt64) {
        writeIndex.store(newWriteIndex, ordering: .releasing)
    }

    // MARK: - Consumer (Monitor Output IOProc Thread)

    /// Prepares a read plan for `outputFrameCount` frames on the consumer audio thread,
    /// handling initial priming, overflow/underflow XRun recovery, and PI drift tracking.
    @inline(__always)
    public func beginRead(outputFrameCount: Int) -> ReadBeginResult {
        guard outputFrameCount > 0 else {
            return .notReady(xrun: false)
        }

        let wPos = writeIndex.load(ordering: .acquiring)
        var rPos = readIndex.load(ordering: .relaxed)

        let maxStepRatio = baseRatio * 1.004
        let neededSourceFrames = Int(ceil(Double(outputFrameCount) * maxStepRatio)) + 4
        let primeThreshold = max(Int(targetFillFrames), neededSourceFrames + 64)

        // 1. Initial prime: wait until buffer has enough frames to stay safely centered without immediate underflow.
        if !isPrimed {
            let available = wPos >= rPos ? Int(wPos - rPos) : 0
            if available >= primeThreshold {
                rPos = wPos &- UInt64(primeThreshold)
                readIndex.store(rPos, ordering: .relaxed)
                fractionalPhase = 0.0
                integralError = 0.0
                isPrimed = true
                fadeInRemaining = fadeInLength
            } else {
                return .notReady(xrun: false)
            }
        }

        // 2. Overflow protection (e.g. consumer stalled or wake from sleep): snap back cleanly.
        var didXRun = false
        let maxAllowedFill = Self.capacityFrames - 512
        let currentFill = wPos >= rPos ? Int(wPos - rPos) : 0
        if currentFill > maxAllowedFill {
            let snapFill = min(maxAllowedFill, max(Int(targetFillFrames), neededSourceFrames + 64))
            rPos = wPos &- UInt64(snapFill)
            readIndex.store(rPos, ordering: .relaxed)
            fractionalPhase = 0.0
            integralError = 0.0
            fadeInRemaining = fadeInLength
            didXRun = true
        }

        // 3. Underflow protection (e.g. source stopped or paused): re-prime silently without clicks.
        let currentAvailable = wPos >= rPos ? Double(wPos - rPos) - fractionalPhase : 0.0
        if currentAvailable < Double(neededSourceFrames) {
            isPrimed = false
            integralError = 0.0
            return .notReady(xrun: true)
        }

        // 4. Smooth PI controller adjusts resampling ratio by tiny inaudible ppm increments
        //    to keep ring fill locked to `targetFillFrames` across independent clock domains.
        let fillError = currentAvailable - targetFillFrames
        let kp = 0.0000035
        let ki = 0.00000004
        integralError = max(-8000.0, min(8000.0, integralError + fillError))
        let correction = max(-0.004, min(0.004, fillError * kp + integralError * ki))
        let stepRatio = baseRatio * (1.0 + correction)

        let canUseExactCopy = abs(stepRatio - 1.0) < 1e-6 && fractionalPhase < 1e-5 && fadeInRemaining == 0

        let endFrame: UInt64
        let endFractionalPhase: Double
        let endFadeInRemaining: Int

        if canUseExactCopy {
            endFrame = rPos &+ UInt64(outputFrameCount)
            endFractionalPhase = fractionalPhase
            endFadeInRemaining = 0
        } else {
            var intPos = rPos
            var phase = fractionalPhase
            for _ in 0..<outputFrameCount {
                phase += stepRatio
                let whole = UInt64(phase)
                if whole > 0 {
                    intPos &+= whole
                    phase -= Double(whole)
                }
            }
            endFrame = intPos
            endFractionalPhase = phase
            endFadeInRemaining = max(0, fadeInRemaining - outputFrameCount)
        }

        let plan = ReadBlockPlan(
            startFrame: rPos,
            fractionalPhase: fractionalPhase,
            stepRatio: stepRatio,
            outputFrameCount: outputFrameCount,
            fadeInRemaining: fadeInRemaining,
            fadeInLength: fadeInLength,
            canUseExactCopy: canUseExactCopy,
            endFrame: endFrame,
            endFractionalPhase: endFractionalPhase,
            endFadeInRemaining: endFadeInRemaining
        )
        return .ready(plan: plan, xrun: didXRun)
    }

    /// Renders `slot` according to `plan`, summing directly into `dstPtr` with stride `dstStride`
    /// starting at `dstOffset` (zero heap allocations, zero closures).
    @inline(__always)
    public func renderSlot(
        _ slot: Int,
        plan: ReadBlockPlan,
        into dstPtr: UnsafeMutablePointer<Float>,
        dstOffset: Int,
        dstStride: Int
    ) {
        guard slot >= 0, slot < Self.maxChannels else { return }
        let validFrom = slotValidFrom(slot)
        guard validFrom != UInt64.max, plan.endFrame > validFrom else { return }

        let base = slot * Self.capacityFrames
        var dIdx = dstOffset

        if plan.canUseExactCopy {
            for f in 0..<plan.outputFrameCount {
                let frame = plan.startFrame &+ UInt64(f)
                if frame >= validFrom {
                    var sample = storage[base + Int(frame & Self.mask)]
                    let age = frame &- validFrom
                    if age < Self.slotMicroFadeLength {
                        sample *= Float(age) / Float(Self.slotMicroFadeLength)
                    }
                    dstPtr[dIdx] += sample
                }
                dIdx += dstStride
            }
            return
        }

        var intPos = plan.startFrame
        var phase = plan.fractionalPhase
        var localFade = plan.fadeInRemaining
        let invFadeLength = Float(1.0) / Float(plan.fadeInLength)

        for _ in 0..<plan.outputFrameCount {
            if intPos >= validFrom {
                let idx1 = Int(intPos & Self.mask)
                let idx2 = Int((intPos &+ 1) & Self.mask)
                let idx3 = Int((intPos &+ 2) & Self.mask)

                let y0: Float = intPos > validFrom
                    ? storage[base + Int((intPos &- 1) & Self.mask)]
                    : 0.0
                let y1 = storage[base + idx1]
                let y2 = storage[base + idx2]
                let y3 = storage[base + idx3]

                let t = Float(phase)
                let c0 = y1
                let c1 = 0.5 * (y2 - y0)
                let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
                let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
                var sample = ((c3 * t + c2) * t + c1) * t + c0

                let age = intPos &- validFrom
                if age < Self.slotMicroFadeLength {
                    sample *= Float(age) / Float(Self.slotMicroFadeLength)
                }
                if localFade > 0 {
                    let gain = Float(plan.fadeInLength - localFade) * invFadeLength
                    sample *= gain
                }
                dstPtr[dIdx] += sample
            }

            if localFade > 0 {
                localFade -= 1
            }

            phase += plan.stepRatio
            let whole = UInt64(phase)
            if whole > 0 {
                intPos &+= whole
                phase -= Double(whole)
            }
            dIdx += dstStride
        }
    }

    /// Commits the consumer read cursor and resampler state after rendering all active routes.
    @inline(__always)
    public func commitRead(plan: ReadBlockPlan) {
        fractionalPhase = plan.endFractionalPhase
        fadeInRemaining = plan.endFadeInRemaining
        readIndex.store(plan.endFrame, ordering: .releasing)
    }
}
