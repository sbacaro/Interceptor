import Foundation
import InterceptorEngine
import Testing

@Suite("Route Validation & Multi-Stream Mapping")
struct RouteValidationTests {
    private func makeDevice(
        uid: String,
        streams: [(start: Int, count: Int)]
    ) -> AudioDeviceDescriptor {
        let streamDescs = streams.enumerated().map { idx, spec in
            AudioStreamDescriptor(
                streamIndex: idx,
                startingChannel: spec.start,
                channelCount: spec.count,
                sampleRate: 48_000,
                isInterleaved: true
            )
        }
        let total = streams.reduce(0) { $0 + $1.count }
        return AudioDeviceDescriptor(
            uid: uid,
            objectID: 1,
            name: uid,
            manufacturer: "Test",
            outputStreams: streamDescs,
            totalOutputChannels: total,
            nominalSampleRate: 48_000,
            bufferFrameSize: 128,
            outputLatencyFrames: 64,
            transportType: .other
        )
    }

    @Test("Flags out-of-range source and destination mono channels accurately")
    func detectsOutOfRangeChannels() {
        let src = makeDevice(uid: "src-16", streams: [(1, 16)])
        let dst = makeDevice(uid: "dst-2", streams: [(1, 2)])

        let badSourceRoute = ChannelRoute(sourceChannel: 17, destinationChannel: 1)
        let badDestRoute = ChannelRoute(sourceChannel: 1, destinationChannel: 3)
        let goodRoute = ChannelRoute(sourceChannel: 16, destinationChannel: 2)

        let issues = RouteValidator.validate(
            routes: [badSourceRoute, badDestRoute, goodRoute],
            sourceDevice: src,
            destinationDevice: dst
        )

        #expect(issues[badSourceRoute.id] == [.sourceChannelOutOfRange(requested: 17, available: 16)])
        #expect(issues[badDestRoute.id] == [.destinationChannelOutOfRange(requested: 3, available: 2)])
        #expect(issues[goodRoute.id] == nil)
    }

    @Test("Warns when source and destination target the same channel on the same interface")
    func warnsOnSameDeviceChannelOverlap() {
        let shared = makeDevice(uid: "shared-8", streams: [(1, 8)])
        let overlapping = ChannelRoute(sourceChannel: 2, destinationChannel: 2)
        let disjoint = ChannelRoute(sourceChannel: 7, destinationChannel: 1)

        let issues = RouteValidator.validate(
            routes: [overlapping, disjoint],
            sourceDevice: shared,
            destinationDevice: shared
        )

        #expect(issues[overlapping.id] == [.sameDeviceChannelOverlap(channel: 2)])
        #expect(issues[disjoint.id] == nil)
    }

    @Test("Resolves multi-stream logical channels to exact Core Audio output stream indices")
    func resolvesMultiStreamSourceChannels() {
        let multiStreamDevice = makeDevice(uid: "multi-16", streams: [(1, 8), (9, 8)])

        let loc1 = multiStreamDevice.streamLocation(forLogicalChannel: 8)
        let loc2 = multiStreamDevice.streamLocation(forLogicalChannel: 9)
        #expect(loc1?.streamIndex == 0 && loc1?.localChannelIndex == 7)
        #expect(loc2?.streamIndex == 1 && loc2?.localChannelIndex == 0)

        let required = multiStreamDevice.requiredStreamIndices(forLogicalChannels: [7, 8, 9, 10])
        #expect(required == [0, 1])
    }

    @Test("Clamps non-positive channel indices when decoding persisted routes")
    func clampsDecodedChannelIndices() throws {
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "label": "Corrupt Channel",
            "isEnabled": true,
            "sourceChannel": 0,
            "destinationChannel": -3
        }
        """
        let decoded = try JSONDecoder().decode(ChannelRoute.self, from: Data(json.utf8))
        #expect(decoded.sourceChannel == 1)
        #expect(decoded.destinationChannel == 1)
    }

    @Test("Flags logical channels falling in gaps between non-contiguous output streams")
    func detectsMultiStreamChannelGaps() {
        let gappedDevice = makeDevice(uid: "gapped", streams: [(1, 4), (9, 4)])
        let dst = makeDevice(uid: "dst-2", streams: [(1, 2)])

        let gapRoute = ChannelRoute(sourceChannel: 5, destinationChannel: 1)
        let validRoute = ChannelRoute(sourceChannel: 9, destinationChannel: 2)

        let issues = RouteValidator.validate(
            routes: [gapRoute, validRoute],
            sourceDevice: gappedDevice,
            destinationDevice: dst
        )

        #expect(issues[gapRoute.id] == [.sourceChannelOutOfRange(requested: 5, available: 12)])
        #expect(issues[validRoute.id] == nil)
    }
}
