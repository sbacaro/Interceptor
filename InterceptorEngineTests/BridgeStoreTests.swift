import Foundation
import InterceptorEngine
import Testing

@Suite("Bridge Store Persistence")
struct BridgeStoreTests {
    @Test("Round-trips virtual bridge configurations with discrete mono routes")
    func roundTripsBridgesToDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = BridgeStore(fileURL: tempDir.appendingPathComponent("bridges.json"))
        #expect(store.loadBridges().isEmpty)

        let bridgeA = AudioBridgeConfiguration(
            name: "Studio Monitors",
            sourceDeviceUID: "com.example.playback",
            sourceDeviceName: "Multichannel Interface",
            destinationDeviceUID: "com.example.dac",
            destinationDeviceName: "Studio DAC",
            processTarget: .application(bundleID: "com.avid.ProTools", displayName: "Pro Tools"),
            routes: [
                ChannelRoute(label: "Monitor L", sourceChannel: 63, destinationChannel: 1),
                ChannelRoute(label: "Monitor R", sourceChannel: 64, destinationChannel: 2)
            ]
        )

        let bridgeB = AudioBridgeConfiguration(
            name: "Headphones",
            sourceDeviceUID: "com.example.playback",
            sourceDeviceName: "Multichannel Interface",
            destinationDeviceUID: "com.apple.speakers",
            destinationDeviceName: "MacBook Pro Speakers",
            processTarget: .allProcesses,
            routes: [
                ChannelRoute(label: "Cue L", sourceChannel: 11, destinationChannel: 1),
                ChannelRoute(label: "Cue R", isEnabled: false, sourceChannel: 12, destinationChannel: 2)
            ]
        )

        try store.saveBridges([bridgeA, bridgeB])
        let loaded = store.loadBridges()

        #expect(loaded.count == 2)
        #expect(loaded[0].name == "Studio Monitors")
        #expect(loaded[0].routes[0].sourceChannel == 63)
        #expect(loaded[0].processTarget == .application(bundleID: "com.avid.ProTools", displayName: "Pro Tools"))
        #expect(loaded[1].name == "Headphones")
        #expect(loaded[1].routes[1].isEnabled == false)
    }

    @Test("Backs up corrupt JSON instead of silently discarding user bridge configuration")
    func backsUpCorruptStoreFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let storeURL = tempDir.appendingPathComponent("bridges.json")
        let corruptPayload = Data("{not valid json".utf8)
        try corruptPayload.write(to: storeURL)

        let store = BridgeStore(fileURL: storeURL)
        let loaded = store.loadBridges()
        #expect(loaded.isEmpty)

        let contents = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let backups = contents.filter { $0.hasPrefix("bridges.corrupt-") && $0.hasSuffix(".json") }
        #expect(backups.count == 1)
    }
}
