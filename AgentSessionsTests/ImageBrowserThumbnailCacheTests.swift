import XCTest
import AppKit
@testable import AgentSessions

final class ImageBrowserThumbnailCacheTests: XCTestCase {
    func testDiskRoundTripDoesNotRequireDecode() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSessionsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let cacheRoot = tmp.appendingPathComponent("ThumbCache-\(UUID().uuidString)", isDirectory: true)
        let sig = ImageBrowserFileSignature(filePath: "/tmp/fake.jsonl", fileSizeBytes: 123, modifiedAtUnixSeconds: 456)
        let key = ImageBrowserImageKey(signature: sig, base64PayloadOffset: 10, base64PayloadLength: 200, mediaType: "image/png", thumbnailMaxPixelSize: 64)

        let png = try makeTestPNG(width: 8, height: 8)
        let cache1 = ImageBrowserThumbnailCache(memoryBudgetBytes: 8 * 1024 * 1024, diskBudgetBytes: 64 * 1024 * 1024, thumbnailMaxPixelSize: 64, cacheRootOverride: cacheRoot)
        _ = try cache1.loadOrCreateThumbnail(for: key) { png }

        // Wait for async disk write.
        let thumbPath = cacheRoot.appendingPathComponent("Thumbnails", isDirectory: true).appendingPathComponent("\(key.stableID).png").path
        let deadline = Date().addingTimeInterval(2.0)
        while !FileManager.default.fileExists(atPath: thumbPath) && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: thumbPath))

        let cache2 = ImageBrowserThumbnailCache(memoryBudgetBytes: 8 * 1024 * 1024, diskBudgetBytes: 64 * 1024 * 1024, thumbnailMaxPixelSize: 64, cacheRootOverride: cacheRoot)
        var decodeCalled = false
        let img = try cache2.loadOrCreateThumbnail(for: key) {
            decodeCalled = true
            return Data()
        }
        XCTAssertFalse(decodeCalled)
        XCTAssertNotNil(img.tiffRepresentation)
    }

    private func makeTestPNG(width: Int, height: Int) throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ImageBrowserThumbnailCacheTests", code: 1, userInfo: nil)
        }
        return data
    }
}

