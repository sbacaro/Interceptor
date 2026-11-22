import Foundation
import os

/// Automatic JSON persistence for configured virtual audio routing bridges.
public final class BridgeStore: @unchecked Sendable {
    private let fileURL: URL
    private let logger = Logger(subsystem: "com.interceptor.audio", category: "BridgeStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil) {
        if let customURL = fileURL {
            self.fileURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.fileURL = appSupport
                .appendingPathComponent("Interceptor", isDirectory: true)
                .appendingPathComponent("bridges.json", isDirectory: false)
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    public func loadBridges() -> [AudioBridgeConfiguration] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            return try decoder.decode([AudioBridgeConfiguration].self, from: data)
        } catch {
            logger.error("Failed to load bridges from \(self.fileURL.path): \(error.localizedDescription)")
            backupCorruptStore()
            return []
        }
    }

    private func backupCorruptStore() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let backupURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("bridges.corrupt-\(timestamp).json", isDirectory: false)
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
            logger.warning("Backed up unreadable bridge configuration to \(backupURL.path)")
        } catch {
            logger.error("Failed to back up corrupt bridge configuration: \(error.localizedDescription)")
        }
    }

    public func saveBridges(_ bridges: [AudioBridgeConfiguration]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(bridges)
        try data.write(to: fileURL, options: [.atomic])
    }
}
