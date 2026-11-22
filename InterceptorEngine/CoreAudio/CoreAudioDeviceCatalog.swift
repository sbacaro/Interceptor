import AppKit
import CoreAudio
import Foundation
import os

/// Live catalog of Core Audio output interfaces and client audio processes.
public final class CoreAudioDeviceCatalog: @unchecked Sendable {
    public static let privateAggregateUIDPrefix = "com.interceptor.audio.private-aggregate."

    private let logger = Logger(subsystem: "com.interceptor.audio", category: "DeviceCatalog")
    private let listenerQueue = DispatchQueue(label: "com.interceptor.audio.catalog-listener", qos: .userInitiated)
    private var listenerProxy: SystemPropertyListenerProxy?
    private var isObserving = false

    public init() {}

    deinit {
        stopObserving()
    }

    /// Returns all alive, non-hidden Core Audio devices that expose at least 1 output channel,
    /// excluding Interceptor's own private aggregate bridge devices.
    public func fetchOutputDevices() -> [AudioDeviceDescriptor] {
        let system = AudioHardwareSystem.shared
        guard let devices = try? system.devices else {
            logger.error("Failed to query Core Audio device list.")
            return []
        }

        var descriptors: [AudioDeviceDescriptor] = []
        descriptors.reserveCapacity(devices.count)

        for device in devices {
            guard let uid = try? device.uid,
                  !uid.hasPrefix(Self.privateAggregateUIDPrefix) else {
                continue
            }

            if (try? device.isHidden) == true {
                continue
            }

            let isAlive = (try? device.isAlive) ?? true
            guard isAlive else { continue }

            let allStreams = (try? device.streams) ?? []
            var outputStreams: [AudioStreamDescriptor] = []
            var outStreamIdx = 0
            var totalOutChannels = 0

            for stream in allStreams {
                guard let direction = try? stream.direction, direction == .output else {
                    continue
                }
                guard let vFormat = try? stream.virtualFormat else {
                    outStreamIdx += 1
                    continue
                }
                let chCount = Int(vFormat.mChannelsPerFrame)
                guard chCount > 0 else {
                    outStreamIdx += 1
                    continue
                }
                let startChannel = (try? stream.startingChannel) ?? (totalOutChannels + 1)
                let isInterleaved = (vFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
                outputStreams.append(
                    AudioStreamDescriptor(
                        streamIndex: outStreamIdx,
                        startingChannel: max(1, startChannel),
                        channelCount: chCount,
                        sampleRate: vFormat.mSampleRate,
                        isInterleaved: isInterleaved
                    )
                )
                totalOutChannels += chCount
                outStreamIdx += 1
            }

            guard totalOutChannels > 0 else { continue }

            let name = (try? device.name) ?? uid
            let manufacturer = (try? device.manufacturer) ?? ""
            let sampleRate = (try? device.nominalSampleRate) ?? outputStreams.first?.sampleRate ?? 48_000.0
            let bufferFrames = (try? device.bufferFrameSize) ?? 256
            let outputLatency = (try? device.outputLatency) ?? 0
            let rawTransport = (try? device.transportType) ?? 0
            let hogPID = (try? device.hogModePID) ?? -1

            descriptors.append(
                AudioDeviceDescriptor(
                    uid: uid,
                    objectID: device.id,
                    name: name,
                    manufacturer: manufacturer,
                    outputStreams: outputStreams,
                    totalOutputChannels: totalOutChannels,
                    nominalSampleRate: sampleRate,
                    bufferFrameSize: bufferFrames,
                    outputLatencyFrames: outputLatency,
                    transportType: AudioTransportKind(coreAudioTransportType: rawTransport),
                    isHogged: hogPID != -1 && hogPID != 0,
                    isAlive: isAlive
                )
            )
        }

        return descriptors.sorted { lhs, rhs in
            lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Returns user-facing macOS applications that are registered as Core Audio HAL clients
    /// (excluding system daemons, XPC/WebKit helpers, Siri/system utilities, idle embedded helpers,
    /// and Interceptor itself), using their official commercial display names.
    public func fetchAudioProcesses() -> [AudioProcessDescriptor] {
        let currentPID = getpid()
        let currentBundleID = Bundle.main.bundleIdentifier

        var resultsByBundleID: [String: AudioProcessDescriptor] = [:]

        if let processes = try? AudioHardwareSystem.shared.processes {
            for process in processes {
                guard let pid = try? process.pid, pid != currentPID else { continue }
                let runningOutput = (try? process.isRunningOutput) ?? false
                let isRunningAudio = runningOutput || ((try? process.isRunning) ?? false)

                guard let resolvedApp = resolveUserApplication(
                    forPID: pid,
                    isActivelyUsingAudio: isRunningAudio
                ) else {
                    continue
                }
                guard resolvedApp.bundleID != currentBundleID else { continue }

                if let existing = resultsByBundleID[resolvedApp.bundleID] {
                    // Preserve active output status and prefer the active process's objectID/pid.
                    if runningOutput && !existing.isRunningOutput {
                        resultsByBundleID[resolvedApp.bundleID] = AudioProcessDescriptor(
                            objectID: process.id,
                            pid: pid,
                            bundleID: resolvedApp.bundleID,
                            displayName: resolvedApp.displayName,
                            isRunningOutput: true
                        )
                    }
                } else {
                    resultsByBundleID[resolvedApp.bundleID] = AudioProcessDescriptor(
                        objectID: process.id,
                        pid: pid,
                        bundleID: resolvedApp.bundleID,
                        displayName: resolvedApp.displayName,
                        isRunningOutput: runningOutput
                    )
                }
            }
        }

        return resultsByBundleID.values.sorted { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput {
                return lhs.isRunningOutput && !rhs.isRunningOutput
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    /// Resolves a Core Audio client PID to a legitimate user-facing macOS application and its
    /// commercial name, filtering out system daemons, CoreServices agents, extensions, and idle helpers.
    private func resolveUserApplication(
        forPID pid: pid_t,
        isActivelyUsingAudio: Bool
    ) -> (bundleID: String, displayName: String)? {
        guard let runningApp = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        return resolveUserApplication(from: runningApp, isActivelyUsingAudio: isActivelyUsingAudio)
    }

    private func resolveUserApplication(
        from app: NSRunningApplication,
        isActivelyUsingAudio: Bool
    ) -> (bundleID: String, displayName: String)? {
        guard let rawBundleURL = app.bundleURL else { return nil }

        // If this is an embedded helper app inside a parent .app bundle (e.g., Electron/Chromium helper),
        // walk up to the enclosing commercial .app bundle.
        let topAppURL = enclosingTopLevelAppURL(for: rawBundleURL) ?? rawBundleURL
        let isEmbeddedHelper = topAppURL != rawBundleURL
        let path = topAppURL.path

        // Exclude system daemons, CoreServices, PrivateFrameworks, extensions, and XPC bundles.
        guard topAppURL.pathExtension == "app" else { return nil }
        if path.hasPrefix("/System/Library/") || path.hasPrefix("/Library/Application Support/") {
            return nil
        }

        // Only surface embedded Electron/Chromium helper processes when they are actively using audio,
        // preventing idle IDEs or non-audio web wrappers from cluttering the menu.
        if isEmbeddedHelper && !isActivelyUsingAudio {
            return nil
        }

        // Allow regular GUI apps anywhere outside /System/Library, and allow accessory menu-bar apps
        // only when installed in standard Applications folders (e.g. SoundID Reference, audio utilities).
        let isUserApplicationsLocation = path.hasPrefix("/Applications/") ||
            path.hasPrefix("/System/Applications/") ||
            path.contains("/Applications/")

        switch app.activationPolicy {
        case .regular:
            guard isUserApplicationsLocation || !path.hasPrefix("/System/") else { return nil }
        case .accessory:
            guard isUserApplicationsLocation, !isEmbeddedHelper else { return nil }
        case .prohibited:
            // Only accept a prohibited helper if it resolved upward to a genuine user app actively using audio.
            guard isEmbeddedHelper, isActivelyUsingAudio, isUserApplicationsLocation else { return nil }
        @unknown default:
            return nil
        }

        guard let bundle = Bundle(url: topAppURL),
              let bundleID = bundle.bundleIdentifier,
              !bundleID.isEmpty else {
            return nil
        }

        // Exclude macOS system assistants and non-audio desktop utilities.
        let excludedSystemBundleIDs: Set<String> = [
            "com.apple.Siri",
            "com.apple.controlcenter",
            "com.apple.dock",
            "com.apple.notificationcenterui",
            "com.apple.Spotlight",
            "com.apple.loginwindow",
            "com.apple.PowerChime",
            "com.apple.finder",
            "com.apple.systempreferences",
            "com.apple.ActivityMonitor",
            "com.apple.Terminal",
            "com.apple.clock",
            "com.apple.findmy",
            "com.apple.Home",
            "com.apple.journal",
            "com.apple.stocks",
            "com.apple.weather"
        ]
        if excludedSystemBundleIDs.contains(bundleID) {
            return nil
        }

        let commercialName = commercialDisplayName(for: bundle, fallbackApp: app)
        return (bundleID, commercialName)
    }

    private func enclosingTopLevelAppURL(for url: URL) -> URL? {
        var candidate: URL?
        var current = url.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                candidate = current
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return candidate
    }

    private func commercialDisplayName(for bundle: Bundle, fallbackApp: NSRunningApplication) -> String {
        if let localizedInfo = bundle.localizedInfoDictionary {
            if let displayName = localizedInfo["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                return displayName
            }
            if let name = localizedInfo["CFBundleName"] as? String, !name.isEmpty {
                return name
            }
        }
        if let info = bundle.infoDictionary {
            if let displayName = info["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                return displayName
            }
            if let name = info["CFBundleName"] as? String, !name.isEmpty {
                return name
            }
        }
        let fileDisplayName = FileManager.default.displayName(atPath: bundle.bundlePath)
        if !fileDisplayName.isEmpty {
            return fileDisplayName.hasSuffix(".app") ? String(fileDisplayName.dropLast(4)) : fileDisplayName
        }
        return fallbackApp.localizedName ?? bundle.bundleIdentifier ?? "Application"
    }

    /// Resolves Interceptor's own Core Audio process object ID (used to exclude ourselves from global device taps).
    public func currentAppProcessObjectID() -> AudioObjectID? {
        guard let proc = try? AudioHardwareSystem.shared.process(for: getpid()) else {
            return nil
        }
        return proc.id == kAudioObjectUnknown ? nil : proc.id
    }

    /// Starts listening for Core Audio hardware device changes, process list changes, and daemon restarts.
    public func startObserving(
        onDeviceListChanged: @escaping @Sendable () -> Void,
        onProcessListChanged: @escaping @Sendable () -> Void,
        onServiceRestarted: @escaping @Sendable () -> Void
    ) {
        guard !isObserving else { return }
        let proxy = SystemPropertyListenerProxy(
            onDeviceListChanged: onDeviceListChanged,
            onProcessListChanged: onProcessListChanged,
            onServiceRestarted: onServiceRestarted
        )
        self.listenerProxy = proxy

        let system = AudioHardwareSystem.shared
        system.delegates.append(proxy)
        let addresses = [
            PropertyAddress(kAudioHardwarePropertyDevices),
            PropertyAddress(kAudioHardwarePropertyProcessObjectList),
            PropertyAddress(kAudioHardwarePropertyServiceRestarted)
        ]
        do {
            try system.addListener(forProperties: addresses, dispatchQueue: listenerQueue)
            isObserving = true
        } catch {
            system.delegates.removeAll { ($0 as AnyObject) === proxy }
            self.listenerProxy = nil
            logger.error("Failed to attach Core Audio system listeners: \(error.localizedDescription)")
        }
    }

    public func stopObserving() {
        guard isObserving, let proxy = listenerProxy else { return }
        let system = AudioHardwareSystem.shared
        let addresses = [
            PropertyAddress(kAudioHardwarePropertyDevices),
            PropertyAddress(kAudioHardwarePropertyProcessObjectList),
            PropertyAddress(kAudioHardwarePropertyServiceRestarted)
        ]
        try? system.removeListener(forProperties: addresses, dispatchQueue: listenerQueue)
        system.delegates.removeAll { ($0 as AnyObject) === proxy }
        listenerProxy = nil
        isObserving = false
    }
}

private final class SystemPropertyListenerProxy: PropertyListenerDelegate, @unchecked Sendable {
    private let onDeviceListChanged: @Sendable () -> Void
    private let onProcessListChanged: @Sendable () -> Void
    private let onServiceRestarted: @Sendable () -> Void

    init(
        onDeviceListChanged: @escaping @Sendable () -> Void,
        onProcessListChanged: @escaping @Sendable () -> Void,
        onServiceRestarted: @escaping @Sendable () -> Void
    ) {
        self.onDeviceListChanged = onDeviceListChanged
        self.onProcessListChanged = onProcessListChanged
        self.onServiceRestarted = onServiceRestarted
    }

    func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        var devicesChanged = false
        var processesChanged = false
        var restarted = false

        for prop in properties {
            switch prop.mSelector {
            case kAudioHardwarePropertyServiceRestarted:
                restarted = true
            case kAudioHardwarePropertyDevices:
                devicesChanged = true
            case kAudioHardwarePropertyProcessObjectList:
                processesChanged = true
            default:
                break
            }
        }

        if restarted {
            onServiceRestarted()
        } else {
            if devicesChanged {
                onDeviceListChanged()
            }
            if processesChanged {
                onProcessListChanged()
            }
        }
    }
}
