import Foundation
import AppKit
import CryptoKit

final class ImageBrowserThumbnailCache {
    struct DiskEntry: Codable, Hashable, Sendable {
        let filename: String
        var sizeBytes: Int64
        var lastAccessUnixSeconds: Int64
    }

    struct DiskManifest: Codable, Sendable {
        var totalBytes: Int64
        var entriesByKey: [String: DiskEntry]
    }

    private let memoryCache = NSCache<NSString, NSImage>()
    private let diskBudgetBytes: Int64
    private let thumbnailMaxPixelSize: Int

    private let fileManager: FileManager
    private let diskRoot: URL
    private let thumbnailsDir: URL
    private let manifestURL: URL

    private let diskQueue = DispatchQueue(label: "AgentSessions.ImageBrowserThumbDisk", qos: .utility)
    private var manifest: DiskManifest = DiskManifest(totalBytes: 0, entriesByKey: [:])
    private var manifestFlushWorkItem: DispatchWorkItem?

    init(memoryBudgetBytes: Int = 128 * 1024 * 1024,
         diskBudgetBytes: Int64 = 512 * 1024 * 1024,
         thumbnailMaxPixelSize: Int = 480,
         fileManager: FileManager = .default,
         cacheRootOverride: URL? = nil) {
        self.diskBudgetBytes = max(0, diskBudgetBytes)
        self.thumbnailMaxPixelSize = thumbnailMaxPixelSize
        self.fileManager = fileManager

        let root: URL = cacheRootOverride ?? (fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory)
            .appendingPathComponent("AgentSessions/ImageBrowser", isDirectory: true)
        self.diskRoot = root
        self.thumbnailsDir = root.appendingPathComponent("Thumbnails", isDirectory: true)
        self.manifestURL = root.appendingPathComponent("thumbnails_manifest.json", isDirectory: false)

        memoryCache.totalCostLimit = max(8 * 1024 * 1024, memoryBudgetBytes)

        diskQueue.async { [weak self] in
            self?.loadManifest()
        }
    }

    func thumbnailIfPresent(for key: ImageBrowserImageKey) -> NSImage? {
        memoryCache.object(forKey: key.stableID as NSString)
    }

    func loadOrCreateThumbnail(for key: ImageBrowserImageKey, decode: () throws -> Data) throws -> NSImage {
        if let img = thumbnailIfPresent(for: key) { return img }

        let (diskURL, dataFromDisk): (URL, Data?) = diskQueue.sync {
            let url = self.thumbnailURL(forKeyID: key.stableID)
            let data = try? Data(contentsOf: url)
            if data != nil {
                self.touchManifestLocked(keyID: key.stableID, fileURL: url)
            }
            return (url, data)
        }

        if let dataFromDisk, let img = NSImage(data: dataFromDisk) {
            memoryCache.setObject(img, forKey: key.stableID as NSString, cost: estimatedCostBytes(for: img))
            return img
        }

        let decoded = try decode()
        guard let thumb = CodexSessionImagePayload.makeThumbnail(from: decoded, maxPixelSize: thumbnailMaxPixelSize) else {
            throw NSError(domain: "ImageBrowserThumbnailCache", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unsupported image format"])
        }

        guard let pngData = thumb.pngData() else {
            memoryCache.setObject(thumb, forKey: key.stableID as NSString, cost: estimatedCostBytes(for: thumb))
            return thumb
        }

        memoryCache.setObject(thumb, forKey: key.stableID as NSString, cost: estimatedCostBytes(for: thumb))

        diskQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.fileManager.createDirectory(at: self.thumbnailsDir, withIntermediateDirectories: true)
                try pngData.write(to: diskURL, options: [.atomic])
                self.recordManifestLocked(keyID: key.stableID, fileURL: diskURL, sizeBytes: Int64(pngData.count))
                self.enforceDiskBudgetLocked()
                self.scheduleFlushManifestLocked()
            } catch {
                // Best-effort disk caching; ignore failures.
            }
        }

        return thumb
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        diskQueue.async { [weak self] in
            guard let self else { return }
            try? self.fileManager.removeItem(at: self.diskRoot)
            self.manifest = DiskManifest(totalBytes: 0, entriesByKey: [:])
        }
    }
}

private extension ImageBrowserThumbnailCache {
    func thumbnailURL(forKeyID keyID: String) -> URL {
        thumbnailsDir.appendingPathComponent("\(keyID).png", isDirectory: false)
    }

    func nowUnixSeconds() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }

    func loadManifest() {
        do {
            try fileManager.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                manifest = DiskManifest(totalBytes: 0, entriesByKey: [:])
                return
            }
            let data = try Data(contentsOf: manifestURL)
            let decoded = try JSONDecoder().decode(DiskManifest.self, from: data)
            manifest = decoded
        } catch {
            manifest = DiskManifest(totalBytes: 0, entriesByKey: [:])
        }
    }

    func recordManifestLocked(keyID: String, fileURL: URL, sizeBytes: Int64) {
        let access = nowUnixSeconds()
        let entry = DiskEntry(filename: fileURL.lastPathComponent, sizeBytes: sizeBytes, lastAccessUnixSeconds: access)
        if let prior = manifest.entriesByKey[keyID] {
            manifest.totalBytes -= prior.sizeBytes
        }
        manifest.entriesByKey[keyID] = entry
        manifest.totalBytes += sizeBytes
    }

    func touchManifestLocked(keyID: String, fileURL: URL) {
        let access = nowUnixSeconds()
        if var entry = manifest.entriesByKey[keyID] {
            entry.lastAccessUnixSeconds = access
            manifest.entriesByKey[keyID] = entry
            scheduleFlushManifestLocked()
            return
        }

        let sizeBytes: Int64 = (try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        recordManifestLocked(keyID: keyID, fileURL: fileURL, sizeBytes: sizeBytes)
    }

    func enforceDiskBudgetLocked() {
        guard diskBudgetBytes > 0 else { return }
        guard manifest.totalBytes > diskBudgetBytes else { return }

        let sorted = manifest.entriesByKey.sorted { a, b in
            if a.value.lastAccessUnixSeconds != b.value.lastAccessUnixSeconds {
                return a.value.lastAccessUnixSeconds < b.value.lastAccessUnixSeconds
            }
            return a.key < b.key
        }

        var bytes = manifest.totalBytes
        for (keyID, entry) in sorted {
            if bytes <= diskBudgetBytes { break }
            let url = thumbnailsDir.appendingPathComponent(entry.filename, isDirectory: false)
            try? fileManager.removeItem(at: url)
            manifest.entriesByKey.removeValue(forKey: keyID)
            bytes -= entry.sizeBytes
        }
        manifest.totalBytes = max(0, bytes)
    }

    func scheduleFlushManifestLocked() {
        manifestFlushWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do {
                let data = try JSONEncoder().encode(self.manifest)
                try data.write(to: self.manifestURL, options: [.atomic])
            } catch {
                // Ignore.
            }
        }
        manifestFlushWorkItem = item
        diskQueue.asyncAfter(deadline: .now() + 0.75, execute: item)
    }

    func estimatedCostBytes(for image: NSImage) -> Int {
        // Best-effort estimate: width * height * 4.
        let size = image.size
        let w = Int(max(1, size.width.rounded(.up)))
        let h = Int(max(1, size.height.rounded(.up)))
        return w * h * 4
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation else { return nil }
        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

