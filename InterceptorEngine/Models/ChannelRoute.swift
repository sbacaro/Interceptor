import Foundation

/// Defines a single discrete mono channel-to-channel patch from a tapped source output
/// channel (`1...N`) to a monitor destination output channel (`1...M`).
/// Signal pass-through is strictly unity gain (bit-transparent when 1-to-1).
public struct ChannelRoute: Codable, Sendable, Hashable, Identifiable {
    public static let maxChannelLimit = 128

    public var id: UUID
    public var label: String
    public var isEnabled: Bool
    /// 1-based discrete output channel on the tapped source interface.
    public var sourceChannel: Int
    /// 1-based discrete output channel on the monitor destination interface.
    public var destinationChannel: Int

    public init(
        id: UUID = UUID(),
        label: String = "Channel 1",
        isEnabled: Bool = true,
        sourceChannel: Int = 1,
        destinationChannel: Int = 1
    ) {
        self.id = id
        self.label = label
        self.isEnabled = isEnabled
        self.sourceChannel = max(1, sourceChannel)
        self.destinationChannel = max(1, destinationChannel)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case isEnabled
        case sourceChannel
        case destinationChannel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.label = try container.decode(String.self, forKey: .label)
        self.isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        let decodedSource = try container.decode(Int.self, forKey: .sourceChannel)
        let decodedDest = try container.decode(Int.self, forKey: .destinationChannel)
        self.sourceChannel = max(1, decodedSource)
        self.destinationChannel = max(1, decodedDest)
    }

    public var sourceChannelDescription: String { "Ch \(sourceChannel)" }
    public var destinationChannelDescription: String { "Out \(destinationChannel)" }
}

/// Validation diagnostics for a `ChannelRoute` against currently selected source and destination interfaces.
public enum RouteValidationIssue: Sendable, Equatable, Hashable {
    case sourceChannelOutOfRange(requested: Int, available: Int)
    case destinationChannelOutOfRange(requested: Int, available: Int)
    case sameDeviceChannelOverlap(channel: Int)

    public var isWarningOnly: Bool {
        switch self {
        case .sameDeviceChannelOverlap: true
        case .sourceChannelOutOfRange, .destinationChannelOutOfRange: false
        }
    }

    public var localizedMessage: String {
        switch self {
        case let .sourceChannelOutOfRange(requested, available):
            return String(
                localized: "Source channel \(requested) exceeds available output channels (\(available)).",
                bundle: .interceptorEngine
            )
        case let .destinationChannelOutOfRange(requested, available):
            return String(
                localized: "Destination channel \(requested) exceeds available output channels (\(available)).",
                bundle: .interceptorEngine
            )
        case let .sameDeviceChannelOverlap(channel):
            return String(
                localized: "Source and destination both target channel \(channel) on the same interface. Interceptor excludes its own process from the tap, but double monitoring may occur.",
                bundle: .interceptorEngine
            )
        }
    }
}

/// Pure route validation helper for discrete mono channel patches.
public enum RouteValidator {
    public static func validate(
        routes: [ChannelRoute],
        sourceDevice: AudioDeviceDescriptor?,
        destinationDevice: AudioDeviceDescriptor?
    ) -> [UUID: [RouteValidationIssue]] {
        var results: [UUID: [RouteValidationIssue]] = [:]
        let sameDevice: Bool = {
            guard let src = sourceDevice?.uid, let dst = destinationDevice?.uid else { return false }
            return src == dst
        }()

        for route in routes {
            var issues: [RouteValidationIssue] = []

            if let src = sourceDevice {
                let isSourceValid = src.outputStreams.isEmpty
                    ? (route.sourceChannel >= 1 && route.sourceChannel <= src.totalOutputChannels)
                    : (src.streamLocation(forLogicalChannel: route.sourceChannel) != nil)
                if !isSourceValid {
                    issues.append(
                        .sourceChannelOutOfRange(
                            requested: route.sourceChannel,
                            available: src.maxLogicalOutputChannel
                        )
                    )
                }
            }

            if let dst = destinationDevice,
               route.destinationChannel < 1 || route.destinationChannel > dst.totalOutputChannels {
                issues.append(
                    .destinationChannelOutOfRange(
                        requested: route.destinationChannel,
                        available: dst.totalOutputChannels
                    )
                )
            }

            if sameDevice && route.sourceChannel == route.destinationChannel {
                issues.append(.sameDeviceChannelOverlap(channel: route.sourceChannel))
            }

            if !issues.isEmpty {
                results[route.id] = issues
            }
        }

        return results
    }
}
