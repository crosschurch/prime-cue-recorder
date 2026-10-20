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
        let (setlist, entry) = try XCTUnwrap(try db.setlists().lazy.compactMap { list in
            try? db.songs(setlistId: list.id).first { $0.lyricCues > 0 && $0.hasSections }.map { (list, $0) }
        }.first)
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

    /// Songs without sections get their length from their downloaded stems.
    func testSectionlessSongsHaveADuration() throws {
        guard let path = ProcessInfo.processInfo.environment["PRIME_TEST_DB"] else {
            throw XCTSkip("Set PRIME_TEST_DB to a copy of a Prime database")
        }
        let db = PrimeDB(url: URL(fileURLWithPath: path))
        var checked = 0
        for setlist in try db.setlists() {
            for entry in try db.songs(setlistId: setlist.id) where entry.isMusic && !entry.hasSections {
                let song = try db.song(versionId: entry.id)
                XCTAssertFalse(song.hasSections)
                if let d = song.duration {
                    XCTAssertGreaterThan(d, 30, song.name)
                    print("\(song.name): \(d)s")
                    checked += 1
                }
            }
        }
        if checked == 0 { throw XCTSkip("No downloaded songs without sections") }
    }

    /// Shifting every lyric cue earlier and back again leaves the songs as they were, and
    /// never touches other notes or buses.
    func testShiftMovesOnlyLyricCuesAndUndoes() throws {
        guard let path = ProcessInfo.processInfo.environment["PRIME_TEST_DB"] else {
            throw XCTSkip("Set PRIME_TEST_DB to a copy of a Prime database")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = PrimeDB(url: URL(fileURLWithPath: path), backupDir: scratch)
        var versions: [String] = []
        for list in try db.setlists() {
            versions += try db.songs(setlistId: list.id).filter { $0.lyricCues > 0 }.map(\.id)
        }
        versions = Array(Set(versions)).sorted()
        XCTAssertFalse(versions.isEmpty)

        func shift(_ seconds: Double) throws -> (moved: Int, pinned: Int) {
            var moves: [String: [String: (sectionId: String, progress: Double)]] = [:]
            var pinned = 0
            for id in versions {
                let r = CueShift.shift(try db.cues(versionId: id, note: 19), in: try db.song(versionId: id), by: seconds)
                if !r.moves.isEmpty { moves[id] = r.moves }
                pinned += r.pinned
            }
            try db.move(moves)
            return (moves.values.map(\.count).reduce(0, +), pinned)
        }
        let before = try versions.map { try db.cues(versionId: $0, note: 19) }
        func otherNotes() throws -> [String] {
            try versions.map { id in "\(id): " + (try [18, 1, 35].map { try db.cues(versionId: id, note: $0) }.description) }
        }
        let others = try otherNotes()
        let earlier = try shift(-0.5)
        print("moved \(earlier.moved) cues in \(versions.count) songs, \(earlier.pinned) pinned")
        XCTAssertGreaterThan(earlier.moved, 0)
        let during = try versions.map { try db.cues(versionId: $0, note: 19) }
        XCTAssertEqual(during.map(\.count), before.map(\.count))
        XCTAssertEqual(during.map { $0.map(\.velocity) }, before.map { $0.map(\.velocity) })
        for (a, b) in zip(try otherNotes(), others) where a != b { XCTFail("changed:\n  \(b)\n  \(a)") }
        let later = try shift(0.5)
        // Compare where each cue sits in the song, in beats: the end of one section and the start
        // of the next are the same moment.
        var moved: [String] = []
        for (i, id) in versions.enumerated() {
            let song = try db.song(versionId: id)
            let byId = Dictionary(song.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            func beat(_ c: SavedCue) -> Double {
                guard let s = byId[c.sectionId] else { return c.progress * 100_000 }
                return s.startBeat + c.progress * s.beats
            }
            for (b, a) in zip(before[i], try db.cues(versionId: id, note: 19)) where abs(beat(b) - beat(a)) > 0.01 {
                moved.append("\(song.name) slide \(b.velocity): \(beat(b)) -> \(beat(a))")
            }
        }
        print("\(moved.count) cues not back where they started; \(earlier.pinned + later.pinned) were pinned")
        moved.forEach { print("  " + $0) }
        XCTAssertLessThanOrEqual(moved.count, earlier.pinned + later.pinned)
    }

    func testEditRemovesRenumbersAndAddsOnlyThoseCues() throws {
        guard let path = ProcessInfo.processInfo.environment["PRIME_TEST_DB"] else {
            throw XCTSkip("Set PRIME_TEST_DB to a copy of a Prime database")
        }
        let db = PrimeDB(url: URL(fileURLWithPath: path),
                         backupDir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let id = try XCTUnwrap(db.setlists().lazy.flatMap { try! db.songs(setlistId: $0.id) }.first { $0.lyricCues >= 3 }?.id)
        let before = try db.cues(versionId: id, note: 19)
        let others = try [18, 1, 35].map { try db.cues(versionId: id, note: $0) }
        var change = CueChanges()
        change.removed = [before[0].id]
        change.velocities = [before[1].id: 99]
        change.added = [(77, before[2].sectionId, before[2].progress)]
        try db.edit([id: change])
        let after = try db.cues(versionId: id, note: 19)
        XCTAssertEqual(after.count, before.count)
        XCTAssertFalse(after.contains { $0.id == before[0].id })
        XCTAssertEqual(after.first { $0.id == before[1].id }?.velocity, 99)
        XCTAssertEqual(after.last?.velocity, 77)
        XCTAssertEqual(after.last?.sectionId, before[2].sectionId)
        XCTAssertEqual(try [18, 1, 35].map { try db.cues(versionId: id, note: $0) }, others)
    }
}
