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
    /// Whether this bridge was active before the app terminated or updated, used to auto-restore on launch.
    public var wasActive: Bool

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
        ],
        wasActive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.sourceDeviceUID = sourceDeviceUID
        self.sourceDeviceName = sourceDeviceName
        self.destinationDeviceUID = destinationDeviceUID
        self.destinationDeviceName = destinationDeviceName
        self.processTarget = processTarget
        self.routes = routes
        self.wasActive = wasActive
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case sourceDeviceUID
        case sourceDeviceName
        case destinationDeviceUID
        case destinationDeviceName
        case processTarget
        case routes
        case wasActive
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.sourceDeviceUID = try container.decodeIfPresent(String.self, forKey: .sourceDeviceUID)
        self.sourceDeviceName = try container.decodeIfPresent(String.self, forKey: .sourceDeviceName)
        self.destinationDeviceUID = try container.decodeIfPresent(String.self, forKey: .destinationDeviceUID)
        self.destinationDeviceName = try container.decodeIfPresent(String.self, forKey: .destinationDeviceName)
        self.processTarget = try container.decode(ProcessTarget.self, forKey: .processTarget)
        self.routes = try container.decode([ChannelRoute].self, forKey: .routes)
        self.wasActive = try container.decodeIfPresent(Bool.self, forKey: .wasActive) ?? false
    }

    public var routingSummary: String {
        let src = sourceDeviceName ?? String(localized: "No Source", bundle: .interceptorEngine)
        let dst = destinationDeviceName ?? String(localized: "No Destination", bundle: .interceptorEngine)
        return "\(src) → \(dst)"
    }
}
