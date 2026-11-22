import CoreAudio
import Foundation

/// Describes an active Core Audio client process on macOS.
public struct AudioProcessDescriptor: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bundleID ?? "pid-\(pid)" }

    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let displayName: String
    public let isRunningOutput: Bool

    public init(
        objectID: AudioObjectID,
        pid: pid_t,
        bundleID: String?,
        displayName: String,
        isRunningOutput: Bool
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.displayName = displayName
        self.isRunningOutput = isRunningOutput
    }
}

/// Scope of processes included in the passive Core Audio device-stream tap.
public enum ProcessTarget: Codable, Sendable, Hashable {
    /// Captures all processes outputting to the tapped device stream (always excluding Interceptor itself).
    case allProcesses
    /// Captures only the specified application by bundle identifier, auto-restoring if the app restarts.
    case application(bundleID: String, displayName: String)

    public var displayName: String {
        switch self {
        case .allProcesses:
            String(localized: "All Processes (Device Stream)", bundle: .interceptorEngine)
        case let .application(_, displayName):
            displayName
        }
    }

    public var shortDescription: String {
        switch self {
        case .allProcesses:
            String(localized: "All Processes", bundle: .interceptorEngine)
        case let .application(_, displayName):
            displayName
        }
    }
}
