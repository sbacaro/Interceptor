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
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.first == "v" || cleaned.first == "V" {
            cleaned.removeFirst()
        }
        if let plusIdx = cleaned.firstIndex(of: "+") {
            cleaned = String(cleaned[..<plusIdx])
        }
        // Reject prerelease tags (e.g. 1.0.6-beta.1) so they are never treated as stable releases.
        guard !cleaned.isEmpty, !cleaned.contains("-") else { return nil }

        let rawParts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(rawParts.count) else { return nil }

        var nums: [Int] = []
        nums.reserveCapacity(rawParts.count)
        for part in rawParts {
            guard !part.isEmpty, let value = Int(part), value >= 0 else { return nil }
            nums.append(value)
        }

        self.major = nums[0]
        self.minor = nums.count > 1 ? nums[1] : 0
        self.patch = nums.count > 2 ? nums[2] : 0
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
    @ObservationIgnored
    public var onError: (@MainActor (String) -> Void)?

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
                    self.setError("Unrecognized release version tag: \(release.tagName)")
                    return
                }

                guard remoteVersion > self.currentVersion else {
                    self.state = .upToDate
                    return
                }

                guard let zipAsset = release.assets.first(where: {
                    $0.name.lowercased().hasSuffix(".zip")
                }), let downloadURL = URL(string: zipAsset.browserDownloadURL),
                   Self.isTrustedGitHubURL(downloadURL) else {
                    self.setError("Release \(release.tagName) does not contain a valid macOS .zip asset.")
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
                    self.setError(error.localizedDescription)
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
                guard Self.isTrustedGitHubURL(update.downloadURL) else {
                    throw UpdaterError.installFailed("Untrusted release download URL.")
                }

                try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
                let zipURL = tempRoot.appendingPathComponent("update.zip")

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
                    try Self.extractAndVerifyApp(
                        zipURL: zipURL,
                        extractDir: extractDir,
                        expectedVersion: update.version
                    )
                }.value

                let targetAppURL = self.resolvedInstallDestination()
                let needsAdmin = self.requiresAdministratorPrivileges(for: targetAppURL)

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

                    onBeforeReplace()
                    try? await Task.sleep(for: .milliseconds(150))

                    try Self.spawnDetachedRelaunch(targetApp: targetAppURL, tempRoot: tempRoot, currentPID: getpid())
                    exit(0)
                } else {
                    onBeforeReplace()
                    try? await Task.sleep(for: .milliseconds(150))

                    try Self.spawnDetachedReplaceAndRelaunch(
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
                self.setError(error.localizedDescription)
            }
        }
    }

    private func setError(_ message: String) {
        state = .error(message)
        onError?(message)
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
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdaterError.networkError("Invalid response from GitHub.")
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(GitHubReleaseDTO.self, from: data)
        case 403, 429:
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
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(progress: progress)
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
        if case .downloading = state {
            state = .downloading(progress: 1.0)
        }
    }

    // MARK: - Verification & Install Helpers

    private nonisolated static func isTrustedGitHubURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        return host == "github.com" ||
            host.hasSuffix(".github.com") ||
            host.hasSuffix(".githubusercontent.com")
    }

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

    private nonisolated static func readErrorAndWait(_ process: Process, errorPipe: Pipe) -> (status: Int32, stderr: String) {
        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let msg = String(data: errData, encoding: .utf8) ?? ""
        return (process.terminationStatus, msg)
    }

    private nonisolated static func findAppBundle(in extractDir: URL) -> URL? {
        let fm = FileManager.default
        let directApp = extractDir.appendingPathComponent("Interceptor.app", isDirectory: true)
        if fm.fileExists(atPath: directApp.path) {
            return directApp
        }

        guard let topEntries = try? fm.contentsOfDirectory(
            at: extractDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for entry in topEntries where entry.lastPathComponent != "__MACOSX" {
            if entry.pathExtension == "app", entry.lastPathComponent == "Interceptor.app" {
                return entry
            }
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let nested = entry.appendingPathComponent("Interceptor.app", isDirectory: true)
                if fm.fileExists(atPath: nested.path) {
                    return nested
                }
            }
        }
        return nil
    }

    private nonisolated static func extractAndVerifyApp(
        zipURL: URL,
        extractDir: URL,
        expectedVersion: SemanticVersion
    ) throws -> URL {
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-xk", zipURL.path, extractDir.path]
        let dittoErr = Pipe()
        ditto.standardError = dittoErr
        try ditto.run()
        let dittoResult = readErrorAndWait(ditto, errorPipe: dittoErr)
        guard dittoResult.status == 0 else {
            throw UpdaterError.installFailed("Failed to extract update archive: \(dittoResult.stderr)")
        }

        guard let extractedApp = findAppBundle(in: extractDir) else {
            throw UpdaterError.installFailed("Interceptor.app was not found inside the release archive.")
        }

        guard let bundle = Bundle(url: extractedApp),
              bundle.bundleIdentifier == "com.interceptor.audio" else {
            throw UpdaterError.installFailed("Downloaded application bundle identifier does not match Interceptor.")
        }

        guard let versionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let bundleVersion = SemanticVersion(parsing: versionString),
              bundleVersion >= expectedVersion else {
            throw UpdaterError.installFailed("Downloaded application version does not match release \(expectedVersion.description).")
        }

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["--verify", "--deep", "--strict", extractedApp.path]
        let signErr = Pipe()
        codesign.standardError = signErr
        try codesign.run()
        let signResult = readErrorAndWait(codesign, errorPipe: signErr)
        guard signResult.status == 0 else {
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
        let dstNew = shellQuoted(targetApp.path + ".new")
        let dstBak = shellQuoted(targetApp.path + ".backup")
        let shellCmd = """
        rm -rf \(dstNew) \(dstBak) && \
        /usr/bin/ditto \(src) \(dstNew) && \
        (/usr/bin/xattr -dr com.apple.quarantine \(dstNew) 2>/dev/null || true) && \
        ( [ ! -e \(dst) ] || mv \(dst) \(dstBak) ) && \
        ( mv \(dstNew) \(dst) || ( [ -e \(dstBak) ] && mv \(dstBak) \(dst); exit 1 ) ) && \
        rm -rf \(dstBak)
        """
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
        let result = readErrorAndWait(process, errorPipe: errPipe)

        if result.status == 0 {
            return .installed
        }

        if result.stderr.contains("-128") || result.stderr.localizedCaseInsensitiveContains("User canceled") {
            return .cancelled
        }
        throw UpdaterError.installFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private nonisolated static func spawnDetachedReplaceAndRelaunch(
        sourceApp: URL,
        targetApp: URL,
        tempRoot: URL,
        currentPID: pid_t
    ) throws {
        let script = """
        PID="$1"
        SRC="$2"
        DST="$3"
        TMP="$4"
        DST_NEW="${DST}.new"
        DST_BAK="${DST}.backup"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 50 ]; do
            sleep 0.2
            i=$((i + 1))
        done
        rm -rf "$DST_NEW" "$DST_BAK"
        if /usr/bin/ditto "$SRC" "$DST_NEW"; then
            /usr/bin/xattr -dr com.apple.quarantine "$DST_NEW" 2>/dev/null || true
            if [ ! -e "$DST" ] || mv "$DST" "$DST_BAK"; then
                if mv "$DST_NEW" "$DST"; then
                    rm -rf "$DST_BAK"
                else
                    [ -e "$DST_BAK" ] && mv "$DST_BAK" "$DST"
                fi
            fi
        fi
        /usr/bin/open -n "$DST"
        rm -rf "$TMP" "$DST_NEW"
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script, "_", "\(currentPID)", sourceApp.path, targetApp.path, tempRoot.path]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
    }

    private nonisolated static func spawnDetachedRelaunch(
        targetApp: URL,
        tempRoot: URL,
        currentPID: pid_t
    ) throws {
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
        try proc.run()
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
    private var isCancelled = false

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
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isCancelled {
                lock.unlock()
                cont.resume(throwing: CancellationError())
            } else {
                continuation = cont
                let downloadTask = session.downloadTask(with: request)
                task = downloadTask
                lock.unlock()
                downloadTask.resume()
            }
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
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
            if let urlErr = error as? URLError, urlErr.code == .cancelled {
                finish(with: .failure(CancellationError()))
            } else {
                finish(with: .failure(error))
            }
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
