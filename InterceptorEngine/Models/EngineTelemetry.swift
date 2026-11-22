import Foundation

/// Role of a device in the signal bridge.
public enum DeviceRole: String, Codable, Sendable {
    case source
    case destination

    public var displayName: String {
        switch self {
        case .source:
            String(localized: "Source Interface", bundle: .interceptorEngine)
        case .destination:
            String(localized: "Monitor Interface", bundle: .interceptorEngine)
        }
    }
}

/// Lifecycle state of the Interceptor audio engine.
public enum EngineState: Sendable, Equatable {
    case idle
    case starting
    case running
    case waitingForDevice(role: DeviceRole, deviceName: String)
    case permissionRequired
    case error(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isActiveOrPending: Bool {
        switch self {
        case .starting, .running, .waitingForDevice: true
        case .idle, .permissionRequired, .error: false
        }
    }

    public var statusTitle: String {
        switch self {
        case .idle:
            String(localized: "Standby", bundle: .interceptorEngine)
        case .starting:
            String(localized: "Starting…", bundle: .interceptorEngine)
        case .running:
            String(localized: "Intercepting", bundle: .interceptorEngine)
        case let .waitingForDevice(_, name):
            String(localized: "Waiting for \(name)", bundle: .interceptorEngine)
        case .permissionRequired:
            String(localized: "Permission Required", bundle: .interceptorEngine)
        case .error:
            String(localized: "Audio Error", bundle: .interceptorEngine)
        }
    }
}

/// Live clock, drift compensation, and performance telemetry exposed to the UI Inspector.
public struct EngineTelemetry: Sendable, Equatable {
    public var state: EngineState
    public var sourceSampleRate: Double
    public var destinationSampleRate: Double
    public var bufferFrames: Int
    public var estimatedLatencyMs: Double
    public var driftCompensationActive: Bool
    public var driftCompensationQuality: UInt32
    public var xrunCount: UInt64
    public var isSourceExclusive: Bool
    public var tappedStreamCount: Int
    public var activeRouteCount: Int
    public var activeOutputChannelCount: Int

    public init(
        state: EngineState = .idle,
        sourceSampleRate: Double = 0,
        destinationSampleRate: Double = 0,
        bufferFrames: Int = 0,
        estimatedLatencyMs: Double = 0,
        driftCompensationActive: Bool = false,
        driftCompensationQuality: UInt32 = 127,
        xrunCount: UInt64 = 0,
        isSourceExclusive: Bool = false,
        tappedStreamCount: Int = 0,
        activeRouteCount: Int = 0,
        activeOutputChannelCount: Int = 0
    ) {
        self.state = state
        self.sourceSampleRate = sourceSampleRate
        self.destinationSampleRate = destinationSampleRate
        self.bufferFrames = bufferFrames
        self.estimatedLatencyMs = estimatedLatencyMs
        self.driftCompensationActive = driftCompensationActive
        self.driftCompensationQuality = driftCompensationQuality
        self.xrunCount = xrunCount
        self.isSourceExclusive = isSourceExclusive
        self.tappedStreamCount = tappedStreamCount
        self.activeRouteCount = activeRouteCount
        self.activeOutputChannelCount = activeOutputChannelCount
    }

    public var isSampleRateConverted: Bool {
        sourceSampleRate > 0 && destinationSampleRate > 0 && abs(sourceSampleRate - destinationSampleRate) > 1.0
    }
}
