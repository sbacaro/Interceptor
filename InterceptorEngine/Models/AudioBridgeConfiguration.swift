import Foundation

/// Represents a virtual passive routing bridge ("virtual device" organization unit)
/// that passively taps a source output interface and routes arbitrary mono channels
/// to a destination monitor interface.
public struct AudioBridgeConfiguration: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var sourceDeviceUID: String?
    public var sourceDeviceName: String?
    public var destinationDeviceUID: String?
    public var destinationDeviceName: String?
    public var processTarget: ProcessTarget
    public var routes: [ChannelRoute]

    public init(
        id: UUID = UUID(),
        name: String = "Main Monitor",
        sourceDeviceUID: String? = nil,
        sourceDeviceName: String? = nil,
        destinationDeviceUID: String? = nil,
        destinationDeviceName: String? = nil,
        processTarget: ProcessTarget = .allProcesses,
        routes: [ChannelRoute] = [
            ChannelRoute(label: "Channel 1", sourceChannel: 1, destinationChannel: 1),
            ChannelRoute(label: "Channel 2", sourceChannel: 2, destinationChannel: 2)
        ]
    ) {
        self.id = id
        self.name = name
        self.sourceDeviceUID = sourceDeviceUID
        self.sourceDeviceName = sourceDeviceName
        self.destinationDeviceUID = destinationDeviceUID
        self.destinationDeviceName = destinationDeviceName
        self.processTarget = processTarget
        self.routes = routes
    }

    public var routingSummary: String {
        let src = sourceDeviceName ?? String(localized: "No Source", bundle: .interceptorEngine)
        let dst = destinationDeviceName ?? String(localized: "No Destination", bundle: .interceptorEngine)
        return "\(src) → \(dst)"
    }
}
