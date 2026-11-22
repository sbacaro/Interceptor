import AppKit
import Foundation
import Observation
import os

/// Lightweight semantic version parser supporting tags like `v1.0.3` or `1.2.0`.
public struct SemanticVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing raw: String) {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "v" || $0 == "V" })
            .split(separator: "-", maxSplits: 1)
            .first
            .map(String.init) ?? ""

        let parts = cleaned.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        self.major = parts[0]
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

/// Metadata for a newer release published on GitHub Releases.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: SemanticVersion
    public let tagName: String
    public let title: String
    public let releaseNotes: String
    public let htmlURL: URL?
    public let downloadURL: URL
    public let assetName: String
    public let assetSizeBytes: Int64
}

/// Observable update lifecycle state for Settings and in-app notifications.
public enum UpdateCheckState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case updateAvailable(AvailableUpdate)
    case downloading(progress: Double)
    case installing
    case error(String)
}

/// Directly checks public GitHub Releases for `sbacaro/Interceptor`, downloads the signed `.zip`
/// release asset with live progress, verifies the extracted bundle and code signature, replaces
/// the installed app (prompting for administrator password via macOS native dialog if required),
/// and relaunches cleanly.
@MainActor
@Observable
public final class GitHubReleaseUpdater {
    public static let repositoryOwner = "sbacaro"
    public static let repositoryName = "Interceptor"

    private enum DefaultsKey {
        static let autoCheckUpdates = "com.interceptor.pref.autoCheckUpdates"
        static let lastCheckTimestamp = "com.interceptor.pref.lastUpdateCheck"
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.interceptor.audio", category: "Updater")

    public private(set) var state: UpdateCheckState = .idle
    public private(set) var lastCheckedDate: Date?
    public var isBannerDismissed: Bool = false

    public var autoCheckEnabled: Bool {
        didSet {
            defaults.set(autoCheckEnabled, forKey: DefaultsKey.autoCheckUpdates)
        }
    }

    public var currentVersionString: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0.0"
    }

    public var currentVersion: SemanticVersion {
        SemanticVersion(parsing: currentVersionString) ?? SemanticVersion(major: 1, minor: 0, patch: 0)
    }

    public var availableUpdate: AvailableUpdate? {
        if case let .updateAvailable(update) = state {
            return update
        }
        return nil
    }

    public var shouldShowInAppBanner: Bool {
        guard !isBannerDismissed else { return false }
        switch state {
        case .updateAvailable, .downloading, .installing:
            return true
        default:
            return false
        }
    }

    private var activeTask: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [DefaultsKey.autoCheckUpdates: true])
        self.autoCheckEnabled = defaults.bool(forKey: DefaultsKey.autoCheckUpdates)
        let savedTimestamp = defaults.double(forKey: DefaultsKey.lastCheckTimestamp)
        if savedTimestamp > 0 {
            self.lastCheckedDate = Date(timeIntervalSince1970: savedTimestamp)
        }
    }

    // MARK: - Check for Updates

    /// Runs a quiet background update check at launch when automatic checks are enabled.
    public func checkAutomaticallyIfNeeded() {
        guard autoCheckEnabled else { return }
        if let last = lastCheckedDate, Date().timeIntervalSince(last) < 60 * 30 {
            return
        }
        checkForUpdates(userInitiated: false)
    }

    public func checkForUpdates(userInitiated: Bool) {
        if case .downloading = state { return }
        if case .installing = state { return }
        startCheck(userInitiated: userInitiated)
    }

    private func startCheck(userInitiated: Bool) {
        activeTask?.cancel()
        state = .checking

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let release = try await self.fetchLatestRelease()
                guard !Task.isCancelled else { return }

                let now = Date()
                self.lastCheckedDate = now
                self.defaults.set(now.timeIntervalSince1970, forKey: DefaultsKey.lastCheckTimestamp)

                guard let remoteVersion = SemanticVersion(parsing: release.tagName) else {
                    self.state = .error("Unrecognized release version tag: \(release.tagName)")
                    return
                }

                guard remoteVersion > self.currentVersion else {
                    self.state = .upToDate
                    return
                }

                guard let zipAsset = release.assets.first(where: {
                    $0.name.lowercased().hasSuffix(".zip")
                }), let downloadURL = URL(string: zipAsset.browserDownloadURL) else {
                    self.state = .error("Release \(release.tagName) does not contain a macOS .zip asset.")
                    return
                }

                let update = AvailableUpdate(
                    version: remoteVersion,
                    tagName: release.tagName,
                    title: release.name?.isEmpty == false ? release.name! : "Interceptor \(release.tagName)",
                    releaseNotes: release.body ?? "",
                    htmlURL: release.htmlURL.flatMap(URL.init(string:)),
                    downloadURL: downloadURL,
                    assetName: zipAsset.name,
                    assetSizeBytes: zipAsset.size
                )
                self.isBannerDismissed = false
                self.state = .updateAvailable(update)
            } catch is CancellationError {
                return
            } catch {
                self.logger.error("Update check failed: \(error.localizedDescription)")
                if userInitiated {
                    self.state = .error(error.localizedDescription)
                } else {
                    self.state = .idle
                }
            }
        }
    }

    // MARK: - Download & Install

    public func installUpdate(_ update: AvailableUpdate, onBeforeReplace: @escaping @MainActor () -> Void) {
        activeTask?.cancel()
        state = .downloading(progress: 0.0)

        activeTask = Task { [weak self] in
            guard let self else { return }
            let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("InterceptorUpdate-\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                let zipURL = tempRoot.appendingPathComponent(update.assetName)

                try await self.downloadAsset(
                    from: update.downloadURL,
                    expectedBytes: update.assetSizeBytes,
                    destination: zipURL
                )
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: tempRoot)
                    return
                }

                self.state = .installing

                let extractDir = tempRoot.appendingPathComponent("extracted", isDirectory: true)
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                let extractedAppURL = try await Task.detached(priority: .userInitiated) {
                    try Self.extractAndVerifyApp(zipURL: zipURL, extractDir: extractDir)
                }.value

                let targetAppURL = self.resolvedInstallDestination()
                let needsAdmin = self.requiresAdministratorPrivileges(for: targetAppURL)

                // Gracefully stop all Core Audio taps/aggregates and let any dismissed sheet close cleanly.
                onBeforeReplace()
                try? await Task.sleep(for: .milliseconds(150))

                if needsAdmin {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try Self.installWithAdministratorPrompt(
                            sourceApp: extractedAppURL,
                            targetApp: targetAppURL
                        )
                    }.value

                    if result == .cancelled {
                        try? FileManager.default.removeItem(at: tempRoot)
                        self.state = .updateAvailable(update)
                        return
                    }

                    Self.spawnDetachedRelaunch(targetApp: targetAppURL, tempRoot: tempRoot, currentPID: getpid())
                    exit(0)
                } else {
                    Self.spawnDetachedReplaceAndRelaunch(
                        sourceApp: extractedAppURL,
                        targetApp: targetAppURL,
                        tempRoot: tempRoot,
                        currentPID: getpid()
                    )
                    exit(0)
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: tempRoot)
                self.state = .updateAvailable(update)
            } catch {
                try? FileManager.default.removeItem(at: tempRoot)
                self.logger.error("Update installation failed: \(error.localizedDescription)")
                self.state = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Networking Helpers

    private func fetchLatestRelease() async throws -> GitHubReleaseDTO {
        let urlString = "https://api.github.com/repos/\(Self.repositoryOwner)/\(Self.repositoryName)/releases/latest"
        guard let url = URL(string: urlString) else {
            throw UpdaterError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Interceptor/\(currentVersionString)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdaterError.networkError("Invalid response from GitHub.")
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        case 403:
            throw UpdaterError.rateLimited
        case 404:
            throw UpdaterError.notFound
        default:
            throw UpdaterError.networkError("GitHub API returned HTTP \(http.statusCode).")
        }
    }

    private func downloadAsset(
        from downloadURL: URL,
        expectedBytes: Int64,
        destination: URL
    ) async throws {
        var request = URLRequest(url: downloadURL)
        request.setValue("Interceptor/\(currentVersionString)", forHTTPHeaderField: "User-Agent")

        let delegate = FastAssetDownloadDelegate(
            expectedBytes: expectedBytes,
            destination: destination,
            onProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.state = .downloading(progress: progress)
                }
            }
        )

        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await withTaskCancellationHandler {
            try await delegate.start(with: session, request: request)
        } onCancel: {
            delegate.cancel()
        }
        state = .downloading(progress: 1.0)
    }

    // MARK: - Verification & Install Helpers

    private func resolvedInstallDestination() -> URL {
        let currentBundle = Bundle.main.bundleURL
        let path = currentBundle.path
        if currentBundle.pathExtension == "app",
           !path.contains("/DerivedData/"),
           !path.hasPrefix("/var/folders/"),
           !path.hasPrefix("/private/var/folders/") {
            return currentBundle
        }
        return URL(fileURLWithPath: "/Applications/Interceptor.app", isDirectory: true)
    }

    private func requiresAdministratorPrivileges(for targetApp: URL) -> Bool {
        let fm = FileManager.default
        let parentPath = targetApp.deletingLastPathComponent().path
        guard fm.isWritableFile(atPath: parentPath) else { return true }
        if fm.fileExists(atPath: targetApp.path) {
            return !fm.isWritableFile(atPath: targetApp.path)
        }
        return false
    }

    private nonisolated static func extractAndVerifyApp(zipURL: URL, extractDir: URL) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", zipURL.path, extractDir.path]
        let dittoErr = Pipe()
        ditto.standardError = dittoErr
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            let msg = String(data: dittoErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw UpdaterError.installFailed("Failed to extract update archive: \(msg)")
        }

        let extractedApp = extractDir.appendingPathComponent("Interceptor.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: extractedApp.path) else {
            throw UpdaterError.installFailed("Interceptor.app was not found inside the release archive.")
        }

        guard let bundle = Bundle(url: extractedApp),
              bundle.bundleIdentifier == "com.interceptor.audio" else {
            throw UpdaterError.installFailed("Downloaded application bundle identifier does not match Interceptor.")
        }

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", extractedApp.path]
        let signErr = Pipe()
        codesign.standardError = signErr
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw UpdaterError.installFailed("Downloaded application failed code signature verification.")
        }

        return extractedApp
    }

    private enum AdminInstallOutcome: Sendable {
        case installed
        case cancelled
    }

    private nonisolated static func installWithAdministratorPrompt(
        sourceApp: URL,
        targetApp: URL
    ) throws -> AdminInstallOutcome {
        let src = shellQuoted(sourceApp.path)
        let dst = shellQuoted(targetApp.path)
        let shellCmd = "rm -rf \(dst) && /usr/bin/ditto \(src) \(dst) && (/usr/bin/xattr -dr com.apple.quarantine \(dst) 2>/dev/null || true)"
        let escapedForAppleScript = shellCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedForAppleScript)\" with administrator privileges with prompt \"Interceptor needs your permission to install the update.\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            return .installed
        }

        let errOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if errOutput.contains("-128") || errOutput.localizedCaseInsensitiveContains("User canceled") {
            return .cancelled
        }
        throw UpdaterError.installFailed(errOutput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private nonisolated static func spawnDetachedReplaceAndRelaunch(
        sourceApp: URL,
        targetApp: URL,
        tempRoot: URL,
        currentPID: pid_t
    ) {
        let script = """
        PID="$1"
        SRC="$2"
        DST="$3"
        TMP="$4"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 50 ]; do
            sleep 0.2
            i=$((i + 1))
        done
        rm -rf "$DST"
        /usr/bin/ditto "$SRC" "$DST"
        /usr/bin/xattr -dr com.apple.quarantine "$DST" 2>/dev/null || true
        /usr/bin/open "$DST"
        rm -rf "$TMP"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "_", "\(currentPID)", sourceApp.path, targetApp.path, tempRoot.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    private nonisolated static func spawnDetachedRelaunch(
        targetApp: URL,
        tempRoot: URL,
        currentPID: pid_t
    ) {
        let script = """
        PID="$1"
        DST="$2"
        TMP="$3"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 50 ]; do
            sleep 0.2
            i=$((i + 1))
        done
        /usr/bin/open -n "$DST"
        rm -rf "$TMP"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "_", "\(currentPID)", targetApp.path, tempRoot.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }

    private nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Native Background Download Delegate

/// Streams the GitHub release `.zip` straight to disk via `URLSessionDownloadTask` at full
/// wire speed (zero per-byte main-actor hops) while reporting throttled progress updates.
private final class FastAssetDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let destination: URL
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var lastReportedProgress: Double = -1.0
    private var didMoveFile = false

    init(
        expectedBytes: Int64,
        destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.expectedBytes = expectedBytes
        self.destination = destination
        self.onProgress = onProgress
    }

    func start(with session: URLSession, request: URLRequest) async throws {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            continuation = cont
            let downloadTask = session.downloadTask(with: request)
            task = downloadTask
            lock.unlock()
            downloadTask.resume()
        }
    }

    func cancel() {
        lock.lock()
        let active = task
        lock.unlock()
        active?.cancel()
    }

    private func finish(with result: Result<Void, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        task = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        guard total > 0 else { return }
        let progress = min(1.0, Double(totalBytesWritten) / Double(total))
        lock.lock()
        let shouldReport = progress - lastReportedProgress >= 0.03 || progress >= 1.0
        if shouldReport { lastReportedProgress = progress }
        lock.unlock()
        if shouldReport {
            onProgress(progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(with: .failure(UpdaterError.networkError("Release download failed (HTTP \(http.statusCode)).")))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            didMoveFile = true
            lock.unlock()
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(with: .failure(error))
            return
        }
        lock.lock()
        let moved = didMoveFile
        lock.unlock()
        if moved {
            finish(with: .success(()))
        } else {
            finish(with: .failure(UpdaterError.networkError("Release download finished without writing file.")))
        }
    }
}

// MARK: - GitHub API DTOs & Errors

private struct GitHubReleaseDTO: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: String?
    let assets: [GitHubAssetDTO]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubAssetDTO: Decodable, Sendable {
    let name: String
    let browserDownloadURL: String
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

private enum UpdaterError: LocalizedError {
    case invalidURL
    case rateLimited
    case notFound
    case networkError(String)
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid GitHub release URL."
        case .rateLimited:
            "GitHub API rate limit reached. Please try again in a few minutes."
        case .notFound:
            "No published GitHub releases were found."
        case let .networkError(msg):
            msg
        case let .installFailed(msg):
            msg.isEmpty ? "Could not complete update installation." : msg
        }
    }
}
