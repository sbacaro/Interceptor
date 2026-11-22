import Foundation
import Synchronization

/// Wait-free Single-Producer Single-Consumer (SPSC) planar audio ring buffer with
/// integrated PI-controlled 4-point cubic Hermite drift compensation and sample-rate conversion.
///
/// Designed for pro-audio decoupling: only the **active routed mono channels** (`1...N`)
/// are written and resampled, avoiding wasted ASRC across 64+ unused hardware tap channels.
public final class LockFreeAudioRingBuffer: @unchecked Sendable {
    public static let maxChannels = 64
    public static let capacityFrames = 8192
    private static let mask: UInt64 = UInt64(capacityFrames - 1)

    /// Contiguous planar storage: channel `c` occupies `[c * capacityFrames ..< (c + 1) * capacityFrames]`.
    private let storage: UnsafeMutablePointer<Float>

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
        storage = .allocate(capacity: totalFloats)
        storage.initialize(repeating: 0.0, count: totalFloats)
    }

    deinit {
        storage.deinitialize(count: Self.maxChannels * Self.capacityFrames)
        storage.deallocate()
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
        // while staying low-latency (~10–25 ms depending on host buffer size).
        let maxBuf = max(64, max(sourceBufferFrames, destinationBufferFrames))
        let scaledBuf = Int(ceil(Double(maxBuf) * max(1.0, baseRatio)))
        let desired = max(512, min(Self.capacityFrames / 2, scaledBuf * 2 + 128))
        targetFillFrames = Double(desired)
        reset()
    }

    /// Resets cursors and zeroes storage (call only when stopped).
    public func reset() {
        writeIndex.store(0, ordering: .relaxed)
        readIndex.store(0, ordering: .relaxed)
        fractionalPhase = 0.0
        integralError = 0.0
        isPrimed = false
        fadeInRemaining = 0
        memset(storage, 0, Self.maxChannels * Self.capacityFrames * MemoryLayout<Float>.size)
    }

    /// Current estimated latency of the drift buffer in milliseconds at the source sample rate.
    public func estimatedBufferLatencyMs(sourceSampleRate: Double) -> Double {
        guard sourceSampleRate > 0 else { return 0 }
        return (targetFillFrames / sourceSampleRate) * 1000.0
    }

    // MARK: - Producer (Tap Input IOProc Thread)

    /// Returns the starting frame index for writing `frameCount` frames into planar channel slots.
    /// Call `commitWrite(frames:)` after populating channel slots `0..<activeChannelCount`.
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

    /// Publishes `frameCount` newly written frames to the consumer thread.
    @inline(__always)
    public func commitWrite(newWriteIndex: UInt64) {
        writeIndex.store(newWriteIndex, ordering: .releasing)
    }

    // MARK: - Consumer (Monitor Output IOProc Thread)

    /// Reads `outputFrameCount` frames for `activeSlots` channels (`0..<activeSlots`), applying
    /// PI drift compensation and 4-point cubic Hermite interpolation, and delivers each sample
    /// through `consume(slot, outputFrame, sample)`.
    ///
    /// Returns `true` if audio was rendered, or `false` if waiting to prime / recovering from XRun.
    @inline(__always)
    public func readResampled(
        activeSlots: Int,
        outputFrameCount: Int,
        onXRun: () -> Void,
        consume: (_ slot: Int, _ frame: Int, _ sample: Float) -> Void
    ) -> Bool {
        guard activeSlots > 0, activeSlots <= Self.maxChannels, outputFrameCount > 0 else {
            return false
        }

        let wPos = writeIndex.load(ordering: .acquiring)
        var rPos = readIndex.load(ordering: .relaxed)

        let available = wPos >= rPos ? Int(wPos - rPos) : 0
        let neededSourceFrames = Int(ceil(Double(outputFrameCount) * baseRatio)) + 6

        // 1. Initial prime: wait until buffer has enough frames to stay safely centered without immediate underflow.
        let primeThreshold = max(Int(targetFillFrames), neededSourceFrames + 64)
        if !isPrimed {
            if available >= primeThreshold {
                let targetStart = wPos &- UInt64(primeThreshold)
                rPos = targetStart
                readIndex.store(rPos, ordering: .relaxed)
                fractionalPhase = 0.0
                integralError = 0.0
                isPrimed = true
                fadeInRemaining = fadeInLength
            } else {
                return false
            }
        }

        // 2. Overflow protection (e.g. consumer stalled or wake from sleep): snap back to targetFill.
        let maxAllowedFill = Self.capacityFrames - 256
        if available > maxAllowedFill {
            rPos = wPos &- UInt64(Int(targetFillFrames))
            readIndex.store(rPos, ordering: .relaxed)
            fractionalPhase = 0.0
            integralError = 0.0
            fadeInRemaining = fadeInLength
            onXRun()
        }

        // 3. Underflow protection (e.g. source stopped or paused): re-prime silently without clicks.
        let currentAvailable = wPos >= rPos ? Double(wPos - rPos) - fractionalPhase : 0.0
        if currentAvailable < Double(neededSourceFrames) {
            isPrimed = false
            integralError = 0.0
            onXRun()
            return false
        }

        // 4. Smooth PI controller adjusts resampling ratio by tiny inaudible ppm increments
        //    to keep ring fill locked to `targetFillFrames` across independent clock domains.
        let fillError = currentAvailable - targetFillFrames
        let kp = 0.0000035
        let ki = 0.00000004
        integralError = max(-8000.0, min(8000.0, integralError + fillError))
        let correction = max(-0.004, min(0.004, fillError * kp + integralError * ki))
        let stepRatio = baseRatio * (1.0 + correction)

        // Ensure we have 1 history sample before rPos for 4-point Hermite interpolation.
        let canUseExactCopy = abs(stepRatio - 1.0) < 1e-6 && fractionalPhase < 1e-5 && fadeInRemaining == 0

        if canUseExactCopy {
            // Bit-transparent 1:1 unity copy fast path when clocks match cleanly.
            for slot in 0..<activeSlots {
                let base = slot * Self.capacityFrames
                for f in 0..<outputFrameCount {
                    let sIdx = Int((rPos &+ UInt64(f)) & Self.mask)
                    consume(slot, f, storage[base + sIdx])
                }
            }
            rPos &+= UInt64(outputFrameCount)
            readIndex.store(rPos, ordering: .releasing)
            return true
        }

        // 4-point cubic Hermite interpolation (studio-grade smoothness, negligible CPU for routed slots).
        var localFade = fadeInRemaining
        var phase = fractionalPhase
        var intPos = rPos

        // Precompute integer positions & fractional weights once per output frame? Even simpler:
        // outer loop over slots with same phase progression is cache-friendly & branch-minimal.
        let initialIntPos = intPos
        let initialPhase = phase
        let initialFade = localFade

        for slot in 0..<activeSlots {
            let base = slot * Self.capacityFrames
            intPos = initialIntPos
            phase = initialPhase
            localFade = initialFade

            for f in 0..<outputFrameCount {
                let idx0 = Int((intPos &- 1) & Self.mask)
                let idx1 = Int(intPos & Self.mask)
                let idx2 = Int((intPos &+ 1) & Self.mask)
                let idx3 = Int((intPos &+ 2) & Self.mask)

                let y0 = storage[base + idx0]
                let y1 = storage[base + idx1]
                let y2 = storage[base + idx2]
                let y3 = storage[base + idx3]

                let t = Float(phase)
                let c0 = y1
                let c1 = 0.5 * (y2 - y0)
                let c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
                let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
                var sample = ((c3 * t + c2) * t + c1) * t + c0

                if localFade > 0 {
                    let gain = Float(fadeInLength - localFade) / Float(fadeInLength)
                    sample *= gain
                    localFade -= 1
                }

                consume(slot, f, sample)

                phase += stepRatio
                let whole = UInt64(phase)
                if whole > 0 {
                    intPos &+= whole
                    phase -= Double(whole)
                }
            }
        }

        fractionalPhase = phase
        fadeInRemaining = localFade
        readIndex.store(intPos, ordering: .releasing)
        return true
    }
}
