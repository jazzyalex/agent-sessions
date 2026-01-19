import XCTest
@testable import AgentSessions

final class AgentBinaryDetectionTests: XCTestCase {
    func testFindsExecutableInPATHOverride() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("mybin", isDirectory: false)
        let created = fileManager.createFile(
            atPath: binURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        XCTAssertTrue(created)

        XCTAssertTrue(AgentEnablement.binaryDetectedInPATH("mybin", pathOverride: dir.path))
    }

    func testDoesNotFindNonExecutableInPATHOverride() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("mybin", isDirectory: false)
        let created = fileManager.createFile(
            atPath: binURL.path,
            contents: Data("echo hello\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o644)]
        )
        XCTAssertTrue(created)

        XCTAssertFalse(AgentEnablement.binaryDetectedInPATH("mybin", pathOverride: dir.path))
    }

    func testUnderstandsDirectPath() throws {
        let fileManager = FileManager.default
        let dir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: dir) }

        let binURL = dir.appendingPathComponent("mybin", isDirectory: false)
        let created = fileManager.createFile(
            atPath: binURL.path,
            contents: Data("#!/bin/sh\nexit 0\n".utf8),
            attributes: [.posixPermissions: NSNumber(value: 0o755)]
        )
        XCTAssertTrue(created)

        XCTAssertTrue(AgentEnablement.binaryDetectedInPATH(binURL.path, pathOverride: nil))
    }
}
