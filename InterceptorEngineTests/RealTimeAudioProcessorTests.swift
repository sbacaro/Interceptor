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
}
