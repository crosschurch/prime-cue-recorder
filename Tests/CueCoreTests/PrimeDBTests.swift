import XCTest
@testable import CueCore

/// Runs against a copy of a real Prime database: PRIME_TEST_DB=/path/to/copy.sqlite swift test
final class PrimeDBTests: XCTestCase {
    func testWriteReplacesOnlyLyricsBusNotes() throws {
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

        let backup = try db.write([
            CueWrite(versionId: entry.id, note: 19, channel: 0,
                     cues: [(1, first.id, 0.25), (2, first.id, 0.5)]),
            CueWrite(versionId: entry.id, note: 18, channel: 0, cues: [(7, first.id, 0.1)]),
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        let after = try XCTUnwrap(try db.songs(setlistId: setlist.id).first { $0.id == entry.id })
        XCTAssertEqual(after.lyricCues, 2)
        XCTAssertEqual(after.playlistCues, [7])
    }
}
