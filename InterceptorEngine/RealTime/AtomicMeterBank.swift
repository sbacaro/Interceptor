import Foundation
import Synchronization

/// Single channel meter measurement consumed by the UI at 60 Hz.
public struct ChannelMeterLevel: Sendable, Equatable {
    public var peakLinear: Float
    public var rmsLinear: Float
    public var peakDB: Float
    public var rmsDB: Float
    public var isClipped: Bool

    public init(
        peakLinear: Float = 0,
        rmsLinear: Float = 0,
        isClipped: Bool = false
    ) {
        self.peakLinear = peakLinear
        self.rmsLinear = rmsLinear
        self.peakDB = Self.linearToDB(peakLinear)
        self.rmsDB = Self.linearToDB(rmsLinear)
        self.isClipped = isClipped
    }

    @inline(__always)
    public static func linearToDB(_ linear: Float) -> Float {
        guard linear > 1.584893e-5 else { return -96.0 }
        return 20.0 * log10f(linear)
    }

    public static let silent = ChannelMeterLevel()
}

/// Snapshot of input and output meter levels delivered to the UI.
public struct MeterFrameSnapshot: Sendable, Equatable {
    public var inputLevels: [ChannelMeterLevel]
    public var outputLevels: [ChannelMeterLevel]
    public var xrunCount: UInt64

    public init(
        inputLevels: [ChannelMeterLevel] = [],
        outputLevels: [ChannelMeterLevel] = [],
        xrunCount: UInt64 = 0
    ) {
        self.inputLevels = inputLevels
        self.outputLevels = outputLevels
        self.xrunCount = xrunCount
    }
}

/// Lock-free atomic bank of Peak, RMS, and Clip indicators bridging the real-time
/// audio thread and the 60 Hz SwiftUI meter renderer with zero allocations on the RT thread.
public final class AtomicMeterBank: @unchecked Sendable {
    public static let maxChannels = 64

    private let inputPeaks: UnsafeMutablePointer<Atomic<UInt32>>
    private let inputRMS: UnsafeMutablePointer<Atomic<UInt32>>
    private let inputClips: UnsafeMutablePointer<Atomic<UInt8>>

    private let outputPeaks: UnsafeMutablePointer<Atomic<UInt32>>
    private let outputRMS: UnsafeMutablePointer<Atomic<UInt32>>
    private let outputClips: UnsafeMutablePointer<Atomic<UInt8>>

    private let xruns: Atomic<UInt64>

    public init() {
        let count = Self.maxChannels
        inputPeaks = .allocate(capacity: count)
        inputRMS = .allocate(capacity: count)
        inputClips = .allocate(capacity: count)
        outputPeaks = .allocate(capacity: count)
        outputRMS = .allocate(capacity: count)
        outputClips = .allocate(capacity: count)

        for i in 0..<count {
            inputPeaks.advanced(by: i).initialize(to: Atomic<UInt32>(0))
            inputRMS.advanced(by: i).initialize(to: Atomic<UInt32>(0))
            inputClips.advanced(by: i).initialize(to: Atomic<UInt8>(0))
            outputPeaks.advanced(by: i).initialize(to: Atomic<UInt32>(0))
            outputRMS.advanced(by: i).initialize(to: Atomic<UInt32>(0))
            outputClips.advanced(by: i).initialize(to: Atomic<UInt8>(0))
        }
        xruns = Atomic<UInt64>(0)
    }

    deinit {
        let count = Self.maxChannels
        inputPeaks.deinitialize(count: count)
        inputRMS.deinitialize(count: count)
        inputClips.deinitialize(count: count)
        outputPeaks.deinitialize(count: count)
        outputRMS.deinitialize(count: count)
        outputClips.deinitialize(count: count)

        inputPeaks.deallocate()
        inputRMS.deallocate()
        inputClips.deallocate()
        outputPeaks.deallocate()
        outputRMS.deallocate()
        outputClips.deallocate()
    }

    /// Real-time audio thread: records peak and RMS for a 0-based input channel.
    @inline(__always)
    public func recordInput(channel: Int, peak: Float, rms: Float) {
        guard channel >= 0, channel < Self.maxChannels else { return }
        atomicStoreMax(inputPeaks.advanced(by: channel), candidate: peak)
        inputRMS.advanced(by: channel).pointee.store(rms.bitPattern, ordering: .relaxed)
        if peak >= 1.0 {
            inputClips.advanced(by: channel).pointee.store(1, ordering: .relaxed)
        }
    }

    /// Real-time audio thread: records peak and RMS for a 0-based output channel.
    @inline(__always)
    public func recordOutput(channel: Int, peak: Float, rms: Float) {
        guard channel >= 0, channel < Self.maxChannels else { return }
        atomicStoreMax(outputPeaks.advanced(by: channel), candidate: peak)
        outputRMS.advanced(by: channel).pointee.store(rms.bitPattern, ordering: .relaxed)
        if peak >= 1.0 {
            outputClips.advanced(by: channel).pointee.store(1, ordering: .relaxed)
        }
    }

    /// Real-time audio thread: increments the dropout / XRun counter.
    @inline(__always)
    public func recordXRun() {
        xruns.wrappingAdd(1, ordering: .relaxed)
    }

    /// UI thread: consumes accumulated peaks since the previous UI poll without losing transients.
    public func consumeSnapshot(inputChannelCount: Int, outputChannelCount: Int) -> MeterFrameSnapshot {
        let inCount = max(0, min(Self.maxChannels, inputChannelCount))
        let outCount = max(0, min(Self.maxChannels, outputChannelCount))

        var inLevels: [ChannelMeterLevel] = []
        inLevels.reserveCapacity(inCount)
        for i in 0..<inCount {
            let peakBits = inputPeaks.advanced(by: i).pointee.exchange(0, ordering: .relaxed)
            let rmsBits = inputRMS.advanced(by: i).pointee.load(ordering: .relaxed)
            let clipped = inputClips.advanced(by: i).pointee.load(ordering: .relaxed) != 0
            inLevels.append(
                ChannelMeterLevel(
                    peakLinear: Float(bitPattern: peakBits),
                    rmsLinear: Float(bitPattern: rmsBits),
                    isClipped: clipped
                )
            )
        }

        var outLevels: [ChannelMeterLevel] = []
        outLevels.reserveCapacity(outCount)
        for i in 0..<outCount {
            let peakBits = outputPeaks.advanced(by: i).pointee.exchange(0, ordering: .relaxed)
            let rmsBits = outputRMS.advanced(by: i).pointee.load(ordering: .relaxed)
            let clipped = outputClips.advanced(by: i).pointee.load(ordering: .relaxed) != 0
            outLevels.append(
                ChannelMeterLevel(
                    peakLinear: Float(bitPattern: peakBits),
                    rmsLinear: Float(bitPattern: rmsBits),
                    isClipped: clipped
                )
            )
        }

        return MeterFrameSnapshot(
            inputLevels: inLevels,
            outputLevels: outLevels,
            xrunCount: xruns.load(ordering: .relaxed)
        )
    }

    /// Clears all latched clip indicators.
    public func resetClips() {
        for i in 0..<Self.maxChannels {
            inputClips.advanced(by: i).pointee.store(0, ordering: .relaxed)
            outputClips.advanced(by: i).pointee.store(0, ordering: .relaxed)
        }
    }

    /// Clears all peaks, RMS values, clips, and XRuns (e.g. when stopping the engine).
    public func resetAll() {
        for i in 0..<Self.maxChannels {
            inputPeaks.advanced(by: i).pointee.store(0, ordering: .relaxed)
            inputRMS.advanced(by: i).pointee.store(0, ordering: .relaxed)
            inputClips.advanced(by: i).pointee.store(0, ordering: .relaxed)
            outputPeaks.advanced(by: i).pointee.store(0, ordering: .relaxed)
            outputRMS.advanced(by: i).pointee.store(0, ordering: .relaxed)
            outputClips.advanced(by: i).pointee.store(0, ordering: .relaxed)
        }
        xruns.store(0, ordering: .relaxed)
    }

    @inline(__always)
    private func atomicStoreMax(_ atomic: UnsafeMutablePointer<Atomic<UInt32>>, candidate: Float) {
        guard candidate.isFinite, candidate > 0 else { return }
        var currentBits = atomic.pointee.load(ordering: .relaxed)
        while Float(bitPattern: currentBits) < candidate {
            let (exchanged, original) = atomic.pointee.compareExchange(
                expected: currentBits,
                desired: candidate.bitPattern,
                ordering: .relaxed
            )
            if exchanged { return }
            currentBits = original
        }
    }
}
