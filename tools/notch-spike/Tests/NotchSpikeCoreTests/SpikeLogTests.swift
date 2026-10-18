import Testing
import Foundation
@testable import NotchSpikeCore

@Test func logLinesAreTimestampedAndSorted() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let log = SpikeLog(url: dir.appending(path: "spike.log"))
    log.write("hover.enter", ["role": "leftWing", "app_active": "false"])
    log.write("panel.created")
    log.flushForTesting()
    let lines = try String(contentsOf: dir.appending(path: "spike.log"), encoding: .utf8)
        .split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("\thover.enter\tapp_active=false role=leftWing"))
    // ISO-8601 UTC with exactly three fractional digits, e.g. 2026-10-17T21:22:59.123Z
    let stamp = try #require(lines[0].split(separator: "\t").first.map(String.init))
    #expect(stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
    #expect(lines[1].hasSuffix("\tpanel.created\t"))
}
