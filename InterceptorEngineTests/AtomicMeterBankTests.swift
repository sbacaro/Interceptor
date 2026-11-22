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

    @Test("Resets RMS to zero on consume and returns silent input levels once signal stops")
    func resetsRMSOnConsume() {
        let bank = AtomicMeterBank()

        bank.recordInput(channel: 0, peak: 0.5, rms: 0.35)
        let first = bank.consumeInputLevel(channel: 0)
        #expect(abs(first.peakLinear - 0.5) < 1e-5)
        #expect(abs(first.rmsLinear - 0.35) < 1e-5)

        let second = bank.consumeInputLevel(channel: 0)
        #expect(second == .silent)

        bank.recordOutput(channel: 0, peak: 0.4, rms: 0.25)
        let snap1 = bank.consumeSnapshot(inputChannelCount: 1, outputChannelCount: 1)
        #expect(abs(snap1.outputLevels[0].rmsLinear - 0.25) < 1e-5)

        let snap2 = bank.consumeSnapshot(inputChannelCount: 1, outputChannelCount: 1)
        #expect(snap2.outputLevels[0].peakLinear == 0.0)
        #expect(snap2.outputLevels[0].rmsLinear == 0.0)
    }

    @Test("Reads cumulative XRun count non-destructively and ignores NaN/Inf values")
    func readsXRunCountAndSanitizesNonFinite() {
        let bank = AtomicMeterBank()

        bank.recordInput(channel: 0, peak: 0.5, rms: 0.25)
        bank.recordXRun()
        bank.recordXRun()

        #expect(bank.xrunCount == 2)
        // Peak was not consumed by reading xrunCount
        let level = bank.consumeInputLevel(channel: 0)
        #expect(abs(level.peakLinear - 0.5) < 1e-5)

        // NaN and +/-Infinity must be sanitized and never latch clips
        bank.recordInput(channel: 1, peak: .nan, rms: .infinity)
        bank.recordInput(channel: 2, peak: .infinity, rms: -.infinity)
        let ch1 = bank.consumeInputLevel(channel: 1)
        let ch2 = bank.consumeInputLevel(channel: 2)
        #expect(ch1 == .silent)
        #expect(ch2 == .silent)
    }

    @Test("Tracks underruns and overruns separately while summing total XRuns and resetting cleanly")
    func tracksUnderrunsAndOverrunsSeparatelyAndResets() {
        let bank = AtomicMeterBank()

        bank.recordUnderrun()
        bank.recordUnderrun()
        bank.recordOverrun()

        #expect(bank.underrunCount == 2)
        #expect(bank.overrunCount == 1)
        #expect(bank.xrunCount == 3)

        bank.resetAll()
        #expect(bank.underrunCount == 0)
        #expect(bank.overrunCount == 0)
        #expect(bank.xrunCount == 0)
    }
}
