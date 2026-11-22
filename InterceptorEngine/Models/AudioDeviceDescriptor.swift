import CoreAudio
import Foundation

/// Transport category of a Core Audio output device.
public enum AudioTransportKind: String, Codable, Sendable, Hashable {
    case builtIn
    case usb
    case thunderbolt
    case pci
    case avb
    case network
    case virtual
    case aggregate
    case bluetooth
    case displayPort
    case hdmi
    case other

    public init(coreAudioTransportType: UInt32) {
        switch coreAudioTransportType {
        case kAudioDeviceTransportTypeBuiltIn:
            self = .builtIn
        case kAudioDeviceTransportTypeUSB:
            self = .usb
        case kAudioDeviceTransportTypeThunderbolt:
            self = .thunderbolt
        case kAudioDeviceTransportTypePCI:
            self = .pci
        case kAudioDeviceTransportTypeAVB:
            self = .avb
        case kAudioDeviceTransportTypeVirtual:
            self = .virtual
        case kAudioDeviceTransportTypeAggregate:
            self = .aggregate
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            self = .bluetooth
        case kAudioDeviceTransportTypeDisplayPort:
            self = .displayPort
        case kAudioDeviceTransportTypeHDMI:
            self = .hdmi
        default:
            // Network/IP transports (e.g., Dante, AES67) often use custom or unknown transport codes
            if coreAudioTransportType == kAudioDeviceTransportTypeAirPlay {
                self = .network
            } else {
                self = .other
            }
        }
    }

    public var displayName: String {
        switch self {
        case .builtIn: String(localized: "Built-in", bundle: .interceptorEngine)
        case .usb: String(localized: "USB", bundle: .interceptorEngine)
        case .thunderbolt: String(localized: "Thunderbolt", bundle: .interceptorEngine)
        case .pci: String(localized: "PCIe", bundle: .interceptorEngine)
        case .avb: String(localized: "AVB", bundle: .interceptorEngine)
        case .network: String(localized: "Network", bundle: .interceptorEngine)
        case .virtual: String(localized: "Virtual", bundle: .interceptorEngine)
        case .aggregate: String(localized: "Aggregate", bundle: .interceptorEngine)
        case .bluetooth: String(localized: "Bluetooth", bundle: .interceptorEngine)
        case .displayPort: String(localized: "DisplayPort", bundle: .interceptorEngine)
        case .hdmi: String(localized: "HDMI", bundle: .interceptorEngine)
        case .other: String(localized: "Audio Interface", bundle: .interceptorEngine)
        }
    }

    public var symbolName: String {
        switch self {
        case .builtIn: "laptopcomputer"
        case .usb: "cable.connector"
        case .thunderbolt: "bolt.horizontal.fill"
        case .pci: "cpu"
        case .avb, .network: "network"
        case .virtual: "waveform.path.ecg.rectangle"
        case .aggregate: "square.stack.3d.up"
        case .bluetooth: "headphones"
        case .displayPort, .hdmi: "display"
        case .other: "hifispeaker.2"
        }
    }
}

/// Describes a single output stream belonging to a Core Audio device.
public struct AudioStreamDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { streamIndex }

    /// Zero-based index among the device's output streams (passed to `CATapDescription`).
    public let streamIndex: Int

    /// One-based starting logical output channel on the parent device.
    public let startingChannel: Int

    /// Number of discrete channels carried by this stream.
    public let channelCount: Int

    /// Nominal sample rate reported by the stream.
    public let sampleRate: Double

    /// Whether the stream's virtual format is interleaved.
    public let isInterleaved: Bool

    public init(
        streamIndex: Int,
        startingChannel: Int,
        channelCount: Int,
        sampleRate: Double,
        isInterleaved: Bool
    ) {
        self.streamIndex = streamIndex
        self.startingChannel = startingChannel
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.isInterleaved = isInterleaved
    }

    /// Inclusive 1-based logical channel range covered by this stream.
    public var channelRange: ClosedRange<Int>? {
        guard channelCount > 0 else { return nil }
        return startingChannel...(startingChannel + channelCount - 1)
    }
}

/// Interface-agnostic descriptor of any Core Audio output device on macOS.
public struct AudioDeviceDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String { uid }

    public let uid: String
    public let objectID: AudioObjectID
    public let name: String
    public let manufacturer: String
    public let outputStreams: [AudioStreamDescriptor]
    public let totalOutputChannels: Int
    public let nominalSampleRate: Double
    public let bufferFrameSize: Int
    public let outputLatencyFrames: Int
    public let transportType: AudioTransportKind
    public let isHogged: Bool
    public let isAlive: Bool

    public init(
        uid: String,
        objectID: AudioObjectID,
        name: String,
        manufacturer: String,
        outputStreams: [AudioStreamDescriptor],
        totalOutputChannels: Int,
        nominalSampleRate: Double,
        bufferFrameSize: Int,
        outputLatencyFrames: Int,
        transportType: AudioTransportKind,
        isHogged: Bool = false,
        isAlive: Bool = true
    ) {
        self.uid = uid
        self.objectID = objectID
        self.name = name
        self.manufacturer = manufacturer
        self.outputStreams = outputStreams
        self.totalOutputChannels = totalOutputChannels
        self.nominalSampleRate = nominalSampleRate
        self.bufferFrameSize = bufferFrameSize
        self.outputLatencyFrames = outputLatencyFrames
        self.transportType = transportType
        self.isHogged = isHogged
        self.isAlive = isAlive
    }

    /// Resolves a 1-based logical output channel into its `(streamIndex, zeroBasedLocalChannel)`.
    public func streamLocation(forLogicalChannel logicalChannel: Int) -> (streamIndex: Int, localChannelIndex: Int)? {
        guard logicalChannel >= 1 else { return nil }
        for stream in outputStreams {
            guard let range = stream.channelRange else { continue }
            if range.contains(logicalChannel) {
                return (stream.streamIndex, logicalChannel - stream.startingChannel)
            }
        }
        return nil
    }

    /// Returns the sorted unique output stream indices needed to capture the given 1-based logical channels.
    public func requiredStreamIndices(forLogicalChannels channels: [Int]) -> [Int] {
        var indices = Set<Int>()
        for channel in channels {
            if let loc = streamLocation(forLogicalChannel: channel) {
                indices.insert(loc.streamIndex)
            }
        }
        if indices.isEmpty, let first = outputStreams.first {
            return [first.streamIndex]
        }
        return indices.sorted()
    }

    public var formattedSampleRate: String {
        let khz = nominalSampleRate / 1000.0
        if khz.truncatingRemainder(dividingBy: 1.0) == 0 {
            return String(format: "%.0f kHz", khz)
        }
        return String(format: "%.1f kHz", khz)
    }

    public var subtitle: String {
        let chLabel = totalOutputChannels == 1 ? "1 ch" : "\(totalOutputChannels) ch"
        return "\(chLabel) · \(formattedSampleRate) · \(transportType.displayName)"
    }
}

extension Bundle {
    /// Bundle anchor for InterceptorEngine localized resources.
    static let interceptorEngine: Bundle = {
        Bundle(for: EngineBundleToken.self)
    }()
}

private final class EngineBundleToken: NSObject {}
