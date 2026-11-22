import Foundation
import InterceptorEngine
import Testing

@Suite("Atomic Meter Bank")
struct AtomicMeterBankTests {
    @Test("Preserves maximum peak across multiple audio blocks until UI consumes snapshot")
    func preservesTransientPeakAcrossBlocks() {
        let bank = AtomicMeterBank()

        // Block 1: hot transient at 0.5 (-6.02 dBFS)
        bank.recordOutput(channel: 0, peak: 0.5, rms: 0.35)
        // Block 2: quieter block at 0.1 (-20 dBFS) before UI polls
        bank.recordOutput(channel: 0, peak: 0.1, rms: 0.07)

        let snap1 = bank.consumeSnapshot(inputChannelCount: 2, outputChannelCount: 2)
        #expect(abs(snap1.outputLevels[0].peakLinear - 0.5) < 1e-5)
        #expect(abs(snap1.outputLevels[0].peakDB - (-6.0206)) < 0.05)
        #expect(snap1.outputLevels[0].isClipped == false)

        // Subsequent consume without new audio resets peak accumulator to 0
        let snap2 = bank.consumeSnapshot(inputChannelCount: 2, outputChannelCount: 2)
        #expect(snap2.outputLevels[0].peakLinear == 0.0)
    }

    @Test("Latches clip indicator at >= 0 dBFS until explicitly cleared")
    func latchesAndClearsClipIndicator() {
        let bank = AtomicMeterBank()

        bank.recordOutput(channel: 1, peak: 1.05, rms: 0.707)
        let snap1 = bank.consumeSnapshot(inputChannelCount: 2, outputChannelCount: 2)
        #expect(snap1.outputLevels[1].isClipped == true)

        // Clip remains latched on subsequent frames even when signal drops
        bank.recordOutput(channel: 1, peak: 0.1, rms: 0.05)
        let snap2 = bank.consumeSnapshot(inputChannelCount: 2, outputChannelCount: 2)
        #expect(snap2.outputLevels[1].isClipped == true)

        bank.resetClips()
        let snap3 = bank.consumeSnapshot(inputChannelCount: 2, outputChannelCount: 2)
        #expect(snap3.outputLevels[1].isClipped == false)
    }
}
