import CoreAudio
import CoreAudioTypes

/// Exact memory indexing coordinates for one logical Float32 audio channel within an `AudioBufferList`.
public struct RTChannelAddress: Sendable, Equatable {
    public var bufferIndex: Int32
    public var channelOffset: Int32
    public var stride: Int32
    public var isValid: Bool

    public init(bufferIndex: Int32 = 0, channelOffset: Int32 = 0, stride: Int32 = 1, isValid: Bool = false) {
        self.bufferIndex = bufferIndex
        self.channelOffset = channelOffset
        self.stride = stride
        self.isValid = isValid
    }
}

/// Fixed-capacity value table mapping 0-based logical channels (`0..<128`) onto
/// arbitrary interleaved, non-interleaved, or multi-stream Core Audio `AudioBufferList`s.
public struct RTBufferLayoutMap: Sendable {
    public static let maxChannels = 128

    public var channelCount: Int
    public var bufferCount: Int
    public var channels: InlineArray<128, RTChannelAddress>

    public init() {
        self.channelCount = 0
        self.bufferCount = 0
        self.channels = InlineArray(repeating: RTChannelAddress())
    }

    /// Builds a layout map from a Core Audio stream configuration (`[AudioBuffer]`).
    /// Each `AudioBuffer` entry represents one buffer in `AudioBufferList` with `mNumberChannels`.
    ///
    /// - Parameter skippingLeadingBuffers: Number of leading `AudioBuffer`s in `buffers` to skip
    ///   (for example, the monitor destination subdevice's own input buffers inside a private
    ///   aggregate device, so logical index `0` maps directly to the first SubTap channel while
    ///   retaining each buffer's true `bufferIndex` inside `AudioBufferList`).
    public init(streamConfiguration buffers: [AudioBuffer], skippingLeadingBuffers: Int = 0) {
        self.init()
        self.bufferCount = buffers.count
        let startBuffer = max(0, min(skippingLeadingBuffers, buffers.count))
        var logicalIndex = 0

        for bufferIdx in startBuffer..<buffers.count {
            let chCount = Int(buffers[bufferIdx].mNumberChannels)
            guard chCount > 0 else { continue }
            for chOffset in 0..<chCount {
                guard logicalIndex < Self.maxChannels else { break }
                channels[logicalIndex] = RTChannelAddress(
                    bufferIndex: Int32(bufferIdx),
                    channelOffset: Int32(chOffset),
                    stride: Int32(chCount),
                    isValid: true
                )
                logicalIndex += 1
            }
        }
        self.channelCount = logicalIndex
    }

    /// Convenience initializer for unit tests and synthetic buffers.
    public static func interleaved(channelCount: Int) -> RTBufferLayoutMap {
        let clamped = max(0, min(maxChannels, channelCount))
        let buf = AudioBuffer(mNumberChannels: UInt32(clamped), mDataByteSize: 0, mData: nil)
        return RTBufferLayoutMap(streamConfiguration: clamped > 0 ? [buf] : [])
    }

    /// Convenience initializer for non-interleaved planar buffers (`1` channel per `AudioBuffer`).
    public static func nonInterleaved(channelCount: Int) -> RTBufferLayoutMap {
        let clamped = max(0, min(maxChannels, channelCount))
        let bufs = (0..<clamped).map { _ in
            AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        }
        return RTBufferLayoutMap(streamConfiguration: bufs)
    }

    @inline(__always)
    public subscript(logicalChannel: Int) -> RTChannelAddress {
        guard logicalChannel >= 0, logicalChannel < channelCount else {
            return RTChannelAddress()
        }
        return channels[logicalChannel]
    }
}
