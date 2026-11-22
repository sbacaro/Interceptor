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
}
