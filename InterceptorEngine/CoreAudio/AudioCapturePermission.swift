import AppKit
import CoreAudio
import Foundation

/// Errors thrown by the Core Audio passive tap bridge.
public enum AudioTapBridgeError: LocalizedError, Sendable {
    case sourceDeviceUnavailable(String)
    case destinationDeviceUnavailable(String)
    case noOutputStreams(String)
    case permissionDenied(OSStatus)
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcRegistrationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case emptyAggregateStreams

    public var errorDescription: String? {
        switch self {
        case let .sourceDeviceUnavailable(name):
            String(localized: "Source audio interface \"\(name)\" is not currently connected.", bundle: .interceptorEngine)
        case let .destinationDeviceUnavailable(name):
            String(localized: "Monitor audio interface \"\(name)\" is not currently connected.", bundle: .interceptorEngine)
        case let .noOutputStreams(name):
            String(localized: "Audio interface \"\(name)\" does not expose any output streams.", bundle: .interceptorEngine)
        case .permissionDenied:
            String(
                localized: "System Audio Recording permission is required to passively tap audio output streams. Enable Interceptor in System Settings → Privacy & Security → System Audio Recording Only.",
                bundle: .interceptorEngine
            )
        case let .tapCreationFailed(status):
            String(localized: "Failed to create passive Core Audio tap (OSStatus \(status)).", bundle: .interceptorEngine)
        case let .aggregateCreationFailed(status):
            String(localized: "Failed to create private monitor bridge aggregate device (OSStatus \(status)).", bundle: .interceptorEngine)
        case let .ioProcRegistrationFailed(status):
            String(localized: "Failed to register real-time audio callback (OSStatus \(status)).", bundle: .interceptorEngine)
        case let .deviceStartFailed(status):
            String(localized: "Failed to start monitor audio bridge (OSStatus \(status)).", bundle: .interceptorEngine)
        case .emptyAggregateStreams:
            String(localized: "The private monitor bridge reported no active audio streams.", bundle: .interceptorEngine)
        }
    }
}

/// Utilities for inspecting System Audio Recording TCC permission state and opening System Settings.
public enum AudioCapturePermission {
    /// Deep link to System Settings → Privacy & Security → System Audio Recording Only.
    public static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
    )

    /// Opens the macOS Privacy & Security pane directly to System Audio Recording settings.
    @MainActor
    public static func openSystemSettings() {
        guard let url = systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Heuristic check mapping Core Audio OSStatus codes commonly returned when TCC denies audio capture.
    public static func isPermissionError(_ status: OSStatus) -> Bool {
        // Common TCC/CoreAudio status codes when System Audio Recording permission is denied
        status == kAudioHardwareIllegalOperationError ||
            status == kAudioHardwareNotReadyError ||
            status == -66748 || // kAudioHardwareBadObjectError variant in TCC denial
            status == OSStatus(EPERM)
    }
}
