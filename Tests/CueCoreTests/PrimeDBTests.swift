import XCTest
@testable import CueCore

/// Runs against a copy of a real Prime database: PRIME_TEST_DB=/path/to/copy.sqlite swift test
final class PrimeDBTests: XCTestCase {
    func testWriteKeepsOtherCuesAndRoundTrips() throws {
        guard let path = ProcessInfo.processInfo.environment["PRIME_TEST_DB"] else {
            throw XCTSkip("Set PRIME_TEST_DB to a copy of a Prime database")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = PrimeDB(url: URL(fileURLWithPath: path), backupDir: scratch)
        try db.checkSchema()
        let setlist = try XCTUnwrap(try db.setlists().first)
        let entry = try XCTUnwrap(try db.songs(setlistId: setlist.id).first { $0.lyricCues > 0 })
        let song = try db.song(versionId: entry.id)
        let first = try XCTUnwrap(song.arrangement.first)

        let cues = [
            PlannedCue(slide: 1, sectionId: first.id, progress: 0.25, beat: 0, sectionType: first.type, text: ""),
            PlannedCue(slide: 2, sectionId: first.id, progress: 0.5, beat: 0, sectionType: first.type, text: "x"),
        ]
        try db.writeLyricCues(versionId: entry.id, cues: cues)

        let after = try XCTUnwrap(try db.songs(setlistId: setlist.id).first { $0.id == entry.id })
        XCTAssertEqual(after.lyricCues, 2)
    }
}
