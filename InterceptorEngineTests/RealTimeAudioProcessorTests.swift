import CoreAudioTypes
import Foundation
import InterceptorEngine
import Testing

@Suite("Real-Time Audio Processor")
struct RealTimeAudioProcessorTests {
    // MARK: - Helpers

    private func withInterleavedBuffers(
        inputChannels: Int,
        outputChannels: Int,
        frameCount: Int,
        fillInput: (UnsafeMutablePointer<Float>) -> Void,
        body: (UnsafePointer<AudioBufferList>, UnsafeMutablePointer<AudioBufferList>) -> Void
    ) -> [Float] {
        var inSamples = [Float](repeating: 0.0, count: inputChannels * frameCount)
        var outSamples = [Float](repeating: 99.0, count: outputChannels * frameCount)

        inSamples.withUnsafeMutableBufferPointer { inPtr in
            fillInput(inPtr.baseAddress!)
            outSamples.withUnsafeMutableBufferPointer { outPtr in
                var inABL = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(inputChannels),
                        mDataByteSize: UInt32(inPtr.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(inPtr.baseAddress!)
                    )
                )
                var outABL = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(outputChannels),
                        mDataByteSize: UInt32(outPtr.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(outPtr.baseAddress!)
                    )
                )
                withUnsafePointer(to: &inABL) { inABLPtr in
                    withUnsafeMutablePointer(to: &outABL) { outABLPtr in
                        body(inABLPtr, outABLPtr)
                    }
                }
            }
        }
        return outSamples
    }

    private func withNonInterleavedBuffers(
        inputChannels: Int,
        outputChannels: Int,
        frameCount: Int,
        fillInput: (_ channel: Int, _ buffer: UnsafeMutablePointer<Float>) -> Void,
        body: (UnsafePointer<AudioBufferList>, UnsafeMutablePointer<AudioBufferList>) -> Void
    ) -> [[Float]] {
        var inPlanes = (0..<inputChannels).map { _ in [Float](repeating: 0.0, count: frameCount) }
        var outPlanes = (0..<outputChannels).map { _ in [Float](repeating: 42.0, count: frameCount) }

        for ch in 0..<inputChannels {
            inPlanes[ch].withUnsafeMutableBufferPointer { ptr in
                fillInput(ch, ptr.baseAddress!)
            }
        }

        let inABL = AudioBufferList.allocate(maximumBuffers: inputChannels)
        let outABL = AudioBufferList.allocate(maximumBuffers: outputChannels)
        defer {
            free(inABL.unsafeMutablePointer)
            free(outABL.unsafeMutablePointer)
        }

        var inRawPtrs: [UnsafeMutablePointer<Float>] = []
        var outRawPtrs: [UnsafeMutablePointer<Float>] = []
        for ch in 0..<inputChannels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            p.initialize(from: inPlanes[ch], count: frameCount)
            inRawPtrs.append(p)
            inABL[ch] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(p)
            )
        }
        for ch in 0..<outputChannels {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
            p.initialize(from: outPlanes[ch], count: frameCount)
            outRawPtrs.append(p)
            outABL[ch] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frameCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(p)
            )
        }
        defer {
            for p in inRawPtrs { p.deallocate() }
            for p in outRawPtrs { p.deallocate() }
        }

        body(UnsafePointer(inABL.unsafePointer), outABL.unsafeMutablePointer)

        for ch in 0..<outputChannels {
            outPlanes[ch] = Array(UnsafeBufferPointer(start: outRawPtrs[ch], count: frameCount))
        }
        return outPlanes
    }

    // MARK: - Tests

    @Test("Routes discrete mono channels 63→1 and 64→2 bit-transparently and silences unrouted outputs")
    func routesHighChannelsInterleavedBitTransparent() {
        let frames = 64
        let routes = [
            ChannelRoute(label: "Monitor L", sourceChannel: 63, destinationChannel: 1),
            ChannelRoute(label: "Monitor R", sourceChannel: 64, destinationChannel: 2)
        ]
        let snapshot = RTRoutingSnapshot.build(routes: routes)

        let processor = RealTimeAudioProcessor(
            initialSnapshot: snapshot,
            inputLayout: .interleaved(channelCount: 64),
            outputLayout: .interleaved(channelCount: 4)
        )

        let output = withInterleavedBuffers(inputChannels: 64, outputChannels: 4, frameCount: frames) { inPtr in
            for f in 0..<frames {
                inPtr[f * 64 + 0] = 0.99
                inPtr[f * 64 + 62] = 0.50
                inPtr[f * 64 + 63] = -0.25
            }
        } body: { inABL, outABL in
            processor.process(inInputData: inABL, outOutputData: outABL, frameCount: frames)
        }

        for f in 0..<frames {
            #expect(output[f * 4 + 0] == 0.50)
            #expect(output[f * 4 + 1] == -0.25)
            #expect(output[f * 4 + 2] == 0.0)
            #expect(output[f * 4 + 3] == 0.0)
        }
    }

    @Test("Fans out a single non-interleaved mono channel to multiple outputs cleanly")
    func routesNonInterleavedMonoFanout() {
        let frames = 32
        let routes = [
            ChannelRoute(label: "Cue L", sourceChannel: 3, destinationChannel: 1),
            ChannelRoute(label: "Cue R", sourceChannel: 3, destinationChannel: 2)
        ]
        let snapshot = RTRoutingSnapshot.build(routes: routes)

        let processor = RealTimeAudioProcessor(
            initialSnapshot: snapshot,
            inputLayout: .nonInterleaved(channelCount: 4),
            outputLayout: .nonInterleaved(channelCount: 2)
        )

        let outputPlanes = withNonInterleavedBuffers(inputChannels: 4, outputChannels: 2, frameCount: frames) { ch, ptr in
            if ch == 2 {
                for f in 0..<frames { ptr[f] = 0.4 }
            }
        } body: { inABL, outABL in
            processor.process(inInputData: inABL, outOutputData: outABL, frameCount: frames)
        }

        for f in 0..<frames {
            #expect(outputPlanes[0][f] == 0.4)
            #expect(outputPlanes[1][f] == 0.4)
        }
    }

    @Test("Sums multiple mono channels targeting the same output and updates routes lock-free live")
    func sumsMultipleRoutesAndUpdatesLive() {
        let frames = 32
        let routes = [
            ChannelRoute(label: "A", sourceChannel: 1, destinationChannel: 1),
            ChannelRoute(label: "B", sourceChannel: 3, destinationChannel: 1)
        ]
        let processor = RealTimeAudioProcessor(
            initialSnapshot: RTRoutingSnapshot.build(routes: routes),
            inputLayout: .interleaved(channelCount: 4),
            outputLayout: .interleaved(channelCount: 2)
        )

        let summed = withInterleavedBuffers(inputChannels: 4, outputChannels: 2, frameCount: frames) { inPtr in
            for f in 0..<frames {
                inPtr[f * 4 + 0] = 0.3
                inPtr[f * 4 + 2] = 0.25
            }
        } body: { inABL, outABL in
            processor.process(inInputData: inABL, outOutputData: outABL, frameCount: frames)
        }

        for f in 0..<frames {
            #expect(abs(summed[f * 2 + 0] - 0.55) < 1e-6)
            #expect(summed[f * 2 + 1] == 0.0)
        }

        // Disable route B live via lock-free triple buffer
        let updatedRoutes = [
            ChannelRoute(label: "A", sourceChannel: 1, destinationChannel: 1),
            ChannelRoute(label: "B", isEnabled: false, sourceChannel: 3, destinationChannel: 1)
        ]
        processor.updateRouting(RTRoutingSnapshot.build(routes: updatedRoutes))

        let afterLiveUpdate = withInterleavedBuffers(inputChannels: 4, outputChannels: 2, frameCount: frames) { inPtr in
            for f in 0..<frames {
                inPtr[f * 4 + 0] = 0.3
                inPtr[f * 4 + 2] = 0.25
            }
        } body: { inABL, outABL in
            processor.process(inInputData: inABL, outOutputData: outABL, frameCount: frames)
        }

        for f in 0..<frames {
            #expect(abs(afterLiveUpdate[f * 2 + 0] - 0.3) < 1e-6)
        }
    }

    @Test("Skips monitor destination input buffers before a 64-channel SubTap without shifting or truncating channels")
    func skipsDestinationInputBuffersBeforeSubTap() {
        let frames = 32
        let destInputChannels = 8
        let tapChannels = 64
        let outChannels = 6

        // Aggregate inputStreamConfiguration: [buf0: 8ch monitor mic/line inputs, buf1: 64ch SubTap]
        let inputConfig = [
            AudioBuffer(mNumberChannels: UInt32(destInputChannels), mDataByteSize: 0, mData: nil),
            AudioBuffer(mNumberChannels: UInt32(tapChannels), mDataByteSize: 0, mData: nil)
        ]
        let inputLayout = RTBufferLayoutMap(streamConfiguration: inputConfig, skippingLeadingBuffers: 1)
        let outputLayout = RTBufferLayoutMap.interleaved(channelCount: outChannels)

        #expect(inputLayout.channelCount == 64)
        #expect(inputLayout[0] == RTChannelAddress(bufferIndex: 1, channelOffset: 0, stride: 64, isValid: true))
        #expect(inputLayout[2] == RTChannelAddress(bufferIndex: 1, channelOffset: 2, stride: 64, isValid: true))
        #expect(inputLayout[63] == RTChannelAddress(bufferIndex: 1, channelOffset: 63, stride: 64, isValid: true))

        // Patch discrete channels 3, 4, 5, 6, 7, 64 -> Out 1..6
        let routes = [
            ChannelRoute(label: "Ref L", sourceChannel: 3, destinationChannel: 1),
            ChannelRoute(label: "Ref R", sourceChannel: 4, destinationChannel: 2),
            ChannelRoute(label: "LFE 1", sourceChannel: 5, destinationChannel: 3),
            ChannelRoute(label: "LFE 2", sourceChannel: 6, destinationChannel: 4),
            ChannelRoute(label: "LFE 3", sourceChannel: 7, destinationChannel: 5),
            ChannelRoute(label: "High", sourceChannel: 64, destinationChannel: 6)
        ]
        let processor = RealTimeAudioProcessor(
            initialSnapshot: RTRoutingSnapshot.build(routes: routes),
            inputLayout: inputLayout,
            outputLayout: outputLayout
        )

        // Fill buffer 0 (monitor's own inputs) with loud 0.99 noise,
        // and buffer 1 (64-ch tap) with unique identifiable values per channel.
        let destInRaw = UnsafeMutablePointer<Float>.allocate(capacity: destInputChannels * frames)
        let tapInRaw = UnsafeMutablePointer<Float>.allocate(capacity: tapChannels * frames)
        let outRaw = UnsafeMutablePointer<Float>.allocate(capacity: outChannels * frames)
        defer {
            destInRaw.deallocate()
            tapInRaw.deallocate()
            outRaw.deallocate()
        }

        for i in 0..<(destInputChannels * frames) { destInRaw[i] = 0.99 }
        for f in 0..<frames {
            for c in 0..<tapChannels {
                tapInRaw[f * tapChannels + c] = Float(c + 1) * 0.01
            }
        }
        for i in 0..<(outChannels * frames) { outRaw[i] = -77.0 }

        let inABL = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(inABL.unsafeMutablePointer) }
        inABL[0] = AudioBuffer(
            mNumberChannels: UInt32(destInputChannels),
            mDataByteSize: UInt32(destInputChannels * frames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(destInRaw)
        )
        inABL[1] = AudioBuffer(
            mNumberChannels: UInt32(tapChannels),
            mDataByteSize: UInt32(tapChannels * frames * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(tapInRaw)
        )

        var outABL = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(outChannels),
                mDataByteSize: UInt32(outChannels * frames * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(outRaw)
            )
        )

        withUnsafeMutablePointer(to: &outABL) { outABLPtr in
            processor.process(
                inInputData: UnsafePointer(inABL.unsafePointer),
                outOutputData: outABLPtr,
                frameCount: frames
            )
        }

        for f in 0..<frames {
            #expect(abs(outRaw[f * outChannels + 0] - 0.03) < 1e-6) // Tap Ch 3 (NOT Ch 1!)
            #expect(abs(outRaw[f * outChannels + 1] - 0.04) < 1e-6) // Tap Ch 4 (NOT Ch 2!)
            #expect(abs(outRaw[f * outChannels + 2] - 0.05) < 1e-6) // Tap Ch 5
            #expect(abs(outRaw[f * outChannels + 3] - 0.06) < 1e-6) // Tap Ch 6
            #expect(abs(outRaw[f * outChannels + 4] - 0.07) < 1e-6) // Tap Ch 7
            #expect(abs(outRaw[f * outChannels + 5] - 0.64) < 1e-6) // Tap Ch 64 (not truncated!)
        }
    }

    @Test("Decoupled TapInput -> LockFreeAudioRingBuffer -> MonitorOutput isolates discrete channels with zero XRuns")
    func decoupledRingBufferRoutesDiscreteChannelsCleanly() {
        let frames = 256
        let tapChannels = 64
        let outChannels = 4

        let routes = [
            ChannelRoute(label: "Ref L", sourceChannel: 3, destinationChannel: 1),
            ChannelRoute(label: "Ref R", sourceChannel: 4, destinationChannel: 2),
            ChannelRoute(label: "LFE", sourceChannel: 64, destinationChannel: 3)
        ]

        let processor = RealTimeAudioProcessor(
            initialSnapshot: RTRoutingSnapshot.build(routes: routes),
            inputLayout: .interleaved(channelCount: tapChannels),
            outputLayout: .interleaved(channelCount: outChannels)
        )
        processor.ringBuffer.configure(
            sourceSampleRate: 48_000,
            destinationSampleRate: 48_000,
            sourceBufferFrames: frames,
            destinationBufferFrames: frames
        )

        var inSamples = [Float](repeating: 0.0, count: tapChannels * frames)
        for f in 0..<frames {
            inSamples[f * tapChannels + 0] = 0.99  // Ch 1 (unrouted, must not bleed)
            inSamples[f * tapChannels + 1] = -0.88 // Ch 2 (unrouted, must not bleed)
            inSamples[f * tapChannels + 2] = 0.25  // Ch 3 -> Out 1
            inSamples[f * tapChannels + 3] = -0.50 // Ch 4 -> Out 2
            inSamples[f * tapChannels + 63] = 0.75 // Ch 64 -> Out 3
        }

        // Prime the ring buffer with 6 blocks from the tap producer.
        inSamples.withUnsafeMutableBufferPointer { inPtr in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(tapChannels),
                    mDataByteSize: UInt32(inPtr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(inPtr.baseAddress!)
                )
            )
            withUnsafePointer(to: &inABL) { inABLPtr in
                for _ in 0..<6 {
                    processor.processTapInput(inInputData: inABLPtr, frameCount: frames)
                }
            }
        }

        // Pull 2 blocks on the monitor output consumer (block 1 fades in over 64 frames; block 2 is steady-state unity).
        var outSamples = [Float](repeating: 99.0, count: outChannels * frames)
        outSamples.withUnsafeMutableBufferPointer { outPtr in
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(outChannels),
                    mDataByteSize: UInt32(outPtr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(outPtr.baseAddress!)
                )
            )
            withUnsafeMutablePointer(to: &outABL) { outABLPtr in
                processor.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
                processor.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
            }
        }

        for f in 0..<frames {
            #expect(abs(outSamples[f * outChannels + 0] - 0.25) < 1e-4)
            #expect(abs(outSamples[f * outChannels + 1] - (-0.50)) < 1e-4)
            #expect(abs(outSamples[f * outChannels + 2] - 0.75) < 1e-4)
            #expect(outSamples[f * outChannels + 3] == 0.0)
        }
        let meters = processor.meterBank.consumeSnapshot(inputChannelCount: 64, outputChannelCount: 0)
        #expect(meters.xrunCount == 0)
        #expect(abs(meters.inputLevels[2].peakLinear - 0.25) < 1e-5)
        #expect(abs(meters.inputLevels[63].peakLinear - 0.75) < 1e-5)
    }

    @Test("Live route edits, muting all routes, and re-enabling cause zero cross-channel bleed and zero XRuns")
    func liveRouteEditsIsolateSlotsWithoutXRuns() {
        let frames = 256
        let tapChannels = 8
        let outChannels = 2

        let route0 = ChannelRoute(label: "A", sourceChannel: 1, destinationChannel: 1)
        let route1 = ChannelRoute(label: "B", sourceChannel: 3, destinationChannel: 2)
        let route2 = ChannelRoute(label: "C", isEnabled: false, sourceChannel: 5, destinationChannel: 1)

        let processor = RealTimeAudioProcessor(
            initialSnapshot: RTRoutingSnapshot.build(routes: [route0, route1, route2]),
            inputLayout: .interleaved(channelCount: tapChannels),
            outputLayout: .interleaved(channelCount: outChannels)
        )
        processor.ringBuffer.configure(
            sourceSampleRate: 48_000,
            destinationSampleRate: 48_000,
            sourceBufferFrames: frames,
            destinationBufferFrames: frames
        )

        var inSamples = [Float](repeating: 0.0, count: tapChannels * frames)
        for f in 0..<frames {
            inSamples[f * tapChannels + 0] = 0.25   // Ch 1
            inSamples[f * tapChannels + 2] = -0.60  // Ch 3
            inSamples[f * tapChannels + 4] = 0.45   // Ch 5
        }

        func pushInput(_ count: Int = 1) {
            inSamples.withUnsafeMutableBufferPointer { inPtr in
                var inABL = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(tapChannels),
                        mDataByteSize: UInt32(inPtr.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(inPtr.baseAddress!)
                    )
                )
                withUnsafePointer(to: &inABL) { inABLPtr in
                    for _ in 0..<count {
                        processor.processTapInput(inInputData: inABLPtr, frameCount: frames)
                    }
                }
            }
        }

        func pullOutput() -> [Float] {
            var outSamples = [Float](repeating: 99.0, count: outChannels * frames)
            outSamples.withUnsafeMutableBufferPointer { outPtr in
                var outABL = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(outChannels),
                        mDataByteSize: UInt32(outPtr.count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(outPtr.baseAddress!)
                    )
                )
                withUnsafeMutablePointer(to: &outABL) { outABLPtr in
                    processor.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
                }
            }
            return outSamples
        }

        // Prime and verify steady initial routes
        pushInput(6)
        _ = pullOutput()
        let steady = pullOutput()
        for f in 0..<frames {
            #expect(abs(steady[f * outChannels + 0] - 0.25) < 1e-4)
            #expect(abs(steady[f * outChannels + 1] - (-0.60)) < 1e-4)
        }

        // Disable route0 live -> Out 1 must immediately become silent (no stale Ch 1 tail)
        var disabledA = route0
        disabledA.isEnabled = false
        processor.updateRouting(RTRoutingSnapshot.build(routes: [disabledA, route1, route2]))
        pushInput(1)
        let afterDisable = pullOutput()
        for f in 0..<frames {
            #expect(afterDisable[f * outChannels + 0] == 0.0)
            #expect(abs(afterDisable[f * outChannels + 1] - (-0.60)) < 1e-4)
        }

        // Enable route2 (Ch 5 -> Out 1) live and pump until consumer catches up to newly activated frames
        var enabledC = route2
        enabledC.isEnabled = true
        processor.updateRouting(RTRoutingSnapshot.build(routes: [disabledA, route1, enabledC]))
        for _ in 0..<6 {
            pushInput(1)
            _ = pullOutput()
        }
        pushInput(1)
        let afterEnableC = pullOutput()
        for f in 0..<frames {
            #expect(abs(afterEnableC[f * outChannels + 0] - 0.45) < 1e-4)
            #expect(abs(afterEnableC[f * outChannels + 1] - (-0.60)) < 1e-4)
        }

        // Mute ALL routes for 10 blocks -> ring timeline stays locked with 0 XRuns
        processor.updateRouting(RTRoutingSnapshot())
        for _ in 0..<10 {
            pushInput(1)
            let mutedOut = pullOutput()
            for sample in mutedOut { #expect(sample == 0.0) }
        }

        // Re-enable Ch 1 -> Out 1 and advance past prime fill
        processor.updateRouting(RTRoutingSnapshot.build(routes: [route0]))
        for _ in 0..<6 {
            pushInput(1)
            _ = pullOutput()
        }
        pushInput(1)
        let resumed = pullOutput()
        for f in 0..<frames {
            #expect(abs(resumed[f * outChannels + 0] - 0.25) < 1e-4)
            #expect(resumed[f * outChannels + 1] == 0.0)
        }

        #expect(processor.meterBank.xrunCount == 0)
    }

    @Test("Supports >64 discrete channels (up to 128) and fans out cleanly in decoupled ring mode")
    func supports128ChannelDecoupledFanout() {
        let frames = 256
        let tapChannels = 128
        let outChannels = 4

        let routes = [
            ChannelRoute(label: "High Fan L", sourceChannel: 96, destinationChannel: 1),
            ChannelRoute(label: "High Fan R", sourceChannel: 96, destinationChannel: 2),
            ChannelRoute(label: "Top Ch", sourceChannel: 128, destinationChannel: 4)
        ]

        let processor = RealTimeAudioProcessor(
            initialSnapshot: RTRoutingSnapshot.build(routes: routes),
            inputLayout: .interleaved(channelCount: tapChannels),
            outputLayout: .interleaved(channelCount: outChannels)
        )
        processor.ringBuffer.configure(
            sourceSampleRate: 48_000,
            destinationSampleRate: 48_000,
            sourceBufferFrames: frames,
            destinationBufferFrames: frames
        )

        var inSamples = [Float](repeating: 0.0, count: tapChannels * frames)
        for f in 0..<frames {
            inSamples[f * tapChannels + 95] = 0.35
            inSamples[f * tapChannels + 127] = -0.80
        }

        inSamples.withUnsafeMutableBufferPointer { inPtr in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(tapChannels),
                    mDataByteSize: UInt32(inPtr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(inPtr.baseAddress!)
                )
            )
            withUnsafePointer(to: &inABL) { inABLPtr in
                for _ in 0..<6 {
                    processor.processTapInput(inInputData: inABLPtr, frameCount: frames)
                }
            }
        }

        var outSamples = [Float](repeating: 0.0, count: outChannels * frames)
        outSamples.withUnsafeMutableBufferPointer { outPtr in
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(outChannels),
                    mDataByteSize: UInt32(outPtr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(outPtr.baseAddress!)
                )
            )
            withUnsafeMutablePointer(to: &outABL) { outABLPtr in
                processor.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
                processor.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
            }
        }

        for f in 0..<frames {
            #expect(abs(outSamples[f * outChannels + 0] - 0.35) < 1e-4)
            #expect(abs(outSamples[f * outChannels + 1] - 0.35) < 1e-4)
            #expect(outSamples[f * outChannels + 2] == 0.0)
            #expect(abs(outSamples[f * outChannels + 3] - (-0.80)) < 1e-4)
        }
        #expect(processor.meterBank.xrunCount == 0)
    }

    @Test("Slow consumer startup after >capacityFrames pre-fill produces zero false overflow XRuns")
    func slowConsumerStartupHasZeroFalseXRuns() {
        let frames = 256
        let routes = [ChannelRoute(sourceChannel: 1, destinationChannel: 1)]

        let processor = RealTimeAudioProcessor(
            initialSnapshot: RTRoutingSnapshot.build(routes: routes),
            inputLayout: .interleaved(channelCount: 2),
            outputLayout: .interleaved(channelCount: 2)
        )
        processor.ringBuffer.configure(
            sourceSampleRate: 48_000,
            destinationSampleRate: 48_000,
            sourceBufferFrames: frames,
            destinationBufferFrames: frames
        )

        var inSamples = [Float](repeating: 0.0, count: 2 * frames)
        for f in 0..<frames { inSamples[f * 2] = 0.5 }

        // Simulate producer running well ahead of consumer (> capacityFrames) before first output callback
        let blocks = (LockFreeAudioRingBuffer.capacityFrames / frames) + 4
        inSamples.withUnsafeMutableBufferPointer { inPtr in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(inPtr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(inPtr.baseAddress!)
                )
            )
            withUnsafePointer(to: &inABL) { inABLPtr in
                for _ in 0..<blocks {
                    processor.processTapInput(inInputData: inABLPtr, frameCount: frames)
                }
            }
        }

        var outSamples = [Float](repeating: 0.0, count: 2 * frames)
        outSamples.withUnsafeMutableBufferPointer { outPtr in
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(outPtr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(outPtr.baseAddress!)
                )
            )
            withUnsafeMutablePointer(to: &outABL) { outABLPtr in
                processor.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
                processor.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
            }
        }

        #expect(processor.meterBank.xrunCount == 0)
        for f in 0..<frames {
            #expect(abs(outSamples[f * 2] - 0.5) < 1e-4)
        }
    }

    @Test("Sample-rate conversion (96 kHz -> 48 kHz and 192 kHz -> 48 kHz) renders cleanly with zero XRuns")
    func resamplesHighRatesWithoutXRuns() {
        for srcRate in [96_000.0, 192_000.0] {
            let dstRate = 48_000.0
            let ratio = Int(srcRate / dstRate)
            let srcFrames = 256 * ratio
            let dstFrames = 256

            let routes = [ChannelRoute(sourceChannel: 1, destinationChannel: 1)]
            let processor = RealTimeAudioProcessor(
                initialSnapshot: RTRoutingSnapshot.build(routes: routes),
                inputLayout: .interleaved(channelCount: 2),
                outputLayout: .interleaved(channelCount: 2)
            )
            processor.ringBuffer.configure(
                sourceSampleRate: srcRate,
                destinationSampleRate: dstRate,
                sourceBufferFrames: srcFrames,
                destinationBufferFrames: dstFrames
            )

            var phase = 0.0
            let phaseStep = 2.0 * Double.pi * 1000.0 / srcRate
            var inSamples = [Float](repeating: 0.0, count: 2 * srcFrames)
            var outSamples = [Float](repeating: 0.0, count: 2 * dstFrames)

            func pushSineBlock() {
                for f in 0..<srcFrames {
                    inSamples[f * 2] = Float(0.5 * sin(phase))
                    phase += phaseStep
                }
                inSamples.withUnsafeMutableBufferPointer { inPtr in
                    var inABL = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2,
                            mDataByteSize: UInt32(inPtr.count * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(inPtr.baseAddress!)
                        )
                    )
                    withUnsafePointer(to: &inABL) { inABLPtr in
                        processor.processTapInput(inInputData: inABLPtr, frameCount: srcFrames)
                    }
                }
            }

            // Prime enough source blocks, then stream 20 output blocks
            for _ in 0..<6 { pushSineBlock() }

            var maxAbsOut: Float = 0.0
            for _ in 0..<20 {
                pushSineBlock()
                outSamples.withUnsafeMutableBufferPointer { outPtr in
                    var outABL = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2,
                            mDataByteSize: UInt32(outPtr.count * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(outPtr.baseAddress!)
                        )
                    )
                    withUnsafeMutablePointer(to: &outABL) { outABLPtr in
                        processor.processMonitorOutput(outOutputData: outABLPtr, frameCount: dstFrames)
                    }
                }
                for f in 0..<dstFrames {
                    let s = outSamples[f * 2]
                    #expect(s.isFinite)
                    maxAbsOut = max(maxAbsOut, abs(s))
                }
            }

            #expect(processor.meterBank.xrunCount == 0)
            #expect(maxAbsOut > 0.4 && maxAbsOut < 0.6)
        }
    }

    @Test("Sanitizes NaN and Inf samples in both direct and decoupled paths")
    func sanitizesNonFiniteSamples() {
        let frames = 64
        let routes = [ChannelRoute(sourceChannel: 1, destinationChannel: 1)]

        // Direct path
        let directProcessor = RealTimeAudioProcessor(
            initialSnapshot: RTRoutingSnapshot.build(routes: routes),
            inputLayout: .interleaved(channelCount: 2),
            outputLayout: .interleaved(channelCount: 2)
        )
        let directOut = withInterleavedBuffers(inputChannels: 2, outputChannels: 2, frameCount: frames) { inPtr in
            for f in 0..<frames {
                inPtr[f * 2] = (f % 2 == 0) ? .nan : .infinity
            }
        } body: { inABL, outABL in
            directProcessor.process(inInputData: inABL, outOutputData: outABL, frameCount: frames)
        }
        for sample in directOut {
            #expect(sample == 0.0)
        }
        let directLevel = directProcessor.meterBank.consumeInputLevel(channel: 0)
        #expect(directLevel == .silent)

        // Decoupled path
        let decoupled = RealTimeAudioProcessor(
            initialSnapshot: RTRoutingSnapshot.build(routes: routes),
            inputLayout: .interleaved(channelCount: 2),
            outputLayout: .interleaved(channelCount: 2)
        )
        decoupled.ringBuffer.configure(
            sourceSampleRate: 48_000,
            destinationSampleRate: 48_000,
            sourceBufferFrames: frames,
            destinationBufferFrames: frames
        )
        var badSamples = [Float](repeating: -.infinity, count: 2 * frames)
        badSamples[0] = .nan
        badSamples.withUnsafeMutableBufferPointer { inPtr in
            var inABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(inPtr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(inPtr.baseAddress!)
                )
            )
            withUnsafePointer(to: &inABL) { inABLPtr in
                for _ in 0..<12 {
                    decoupled.processTapInput(inInputData: inABLPtr, frameCount: frames)
                }
            }
        }
        var outSamples = [Float](repeating: 99.0, count: 2 * frames)
        outSamples.withUnsafeMutableBufferPointer { outPtr in
            var outABL = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(outPtr.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(outPtr.baseAddress!)
                )
            )
            withUnsafeMutablePointer(to: &outABL) { outABLPtr in
                decoupled.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
                decoupled.processMonitorOutput(outOutputData: outABLPtr, frameCount: frames)
            }
        }
        for sample in outSamples {
            #expect(sample == 0.0)
        }
        let decoupledLevel = decoupled.meterBank.consumeInputLevel(channel: 0)
        #expect(decoupledLevel == .silent)
    }
}
