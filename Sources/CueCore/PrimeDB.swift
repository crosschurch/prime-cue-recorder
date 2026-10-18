import AppKit
import Foundation
import SQLite3

public struct Setlist: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let serviceDate: String

    public init(id: String, name: String, serviceDate: String) {
        self.id = id; self.name = name; self.serviceDate = serviceDate
    }
}

public struct SetlistSong: Identifiable, Hashable, Sendable {
    public let id: String           // editable multitrackVersion localId
    public let name: String
    public let versionName: String
    public let lyricCues: Int
    public let playlistCues: [Int]  // velocities of the playlist-item cues, in song order
    public let hasSections: Bool
    public let isActive: Bool

    public init(id: String, name: String, versionName: String, lyricCues: Int, playlistCues: [Int] = [],
                hasSections: Bool = true, isActive: Bool) {
        self.id = id; self.name = name; self.versionName = versionName; self.lyricCues = lyricCues
        self.playlistCues = playlistCues; self.hasSections = hasSections; self.isActive = isActive
    }
}

/// Which MIDI notes the ProPresenter setup listens for. Prime stores channel 1 as 0.
public struct CueNotes: Codable, Hashable, Sendable {
    public var lyric = 19
    public var playlist = 18
    public var channel = 0

    public init(lyric: Int = 19, playlist: Int = 18, channel: Int = 0) {
        self.lyric = lyric; self.playlist = playlist; self.channel = channel
    }
}

public struct CueWrite: Sendable {
    public let versionId: String
    public let note: Int
    public let channel: Int
    public let cues: [(velocity: Int, sectionId: String, progress: Double)]

    public init(versionId: String, note: Int, channel: Int, cues: [(velocity: Int, sectionId: String, progress: Double)]) {
        self.versionId = versionId; self.note = note; self.channel = channel; self.cues = cues
    }
}

public struct PrimeSong: Sendable {
    public let versionId: String
    public let name: String
    public let tempo: Double
    public let sections: [PrimeSection]     // song order, Prime's beat coordinates
    public let arrangement: [PrimeSection]  // what this version actually plays

    public init(versionId: String, name: String, tempo: Double, sections: [PrimeSection], arrangement: [PrimeSection]) {
        self.versionId = versionId; self.name = name; self.tempo = tempo
        self.sections = sections; self.arrangement = arrangement
    }
}

public enum PrimeError: LocalizedError {
    case notFound(String), schemaChanged(String), sqlite(String), primeRunning

    public var errorDescription: String? {
        switch self {
        case .notFound(let s): return s
        case .schemaChanged(let s):
            return "Prime's database has changed (\(s)). This app needs an update before it can save safely."
        case .sqlite(let s): return "Database error: \(s)"
        case .primeRunning: return "Quit Prime before saving."
        }
    }
}

/// Reads and writes Loop Community Prime's local SQLite database.
/// Mirrors scripts/prime.py from the prime-midi-cues skill.
public final class PrimeDB {
    public static let bundleID = "com.loopcommunity.PRIMEMAC"
    public static let bus = "lyrics"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    public static let containerDocs = home.appendingPathComponent(
        "Library/Containers/\(bundleID)/Data/Documents")
    public static let backupDir = home.appendingPathComponent("Documents/PrimeBackups")

    public let url: URL
    public let backupDir: URL

    public init(url: URL, backupDir: URL = PrimeDB.backupDir) {
        self.url = url
        self.backupDir = backupDir
    }

    /// Newest database-<account>.sqlite, i.e. the account last used in Prime.
    public static func locate() throws -> PrimeDB {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: containerDocs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dbs = files.filter { $0.lastPathComponent.hasPrefix("database-") && $0.pathExtension == "sqlite" }
        func modified(_ u: URL) -> Date {
            (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard let newest = dbs.max(by: { modified($0) < modified($1) }) else {
            throw PrimeError.notFound("Couldn't find Prime's library on this Mac. Is Prime installed and signed in?")
        }
        return PrimeDB(url: newest)
    }

    public static var primeIsRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Reading

    public func checkSchema() throws {
        try withDB(readonly: true) { db in
            let needed = [
                "multitrack": ["localId", "name", "tempo", "sections"],
                "multitrackVersion": ["localId", "name", "multitrackId", "midiCues", "arrangedSections"],
                "setlist": ["localId", "name", "serviceDate", "activeMultitrackVersionId", "updatedAt"],
                "setlistMultitrackVersion": ["localId", "setlistId", "editableVersionId", "position"],
            ]
            for (table, columns) in needed {
                let have = Set(try query(db, "SELECT name FROM pragma_table_info(?)", [table]).compactMap { $0[0] })
                if let missing = columns.first(where: { !have.contains($0) }) {
                    throw PrimeError.schemaChanged("\(table).\(missing) is missing")
                }
            }
        }
    }

    public func setlists() throws -> [Setlist] {
        try withDB(readonly: true) { db in
            try query(db, "SELECT localId, name, serviceDate FROM setlist ORDER BY updatedAt DESC LIMIT 40")
                .map { Setlist(id: $0[0] ?? "", name: $0[1] ?? "", serviceDate: String(($0[2] ?? "").prefix(10))) }
        }
    }

    public func songs(setlistId: String, notes: CueNotes = CueNotes()) throws -> [SetlistSong] {
        try withDB(readonly: true) { db in
            try query(db, """
                SELECT v.localId, m.name, v.name,
                       (SELECT count(*) FROM json_each(v.midiCues) j
                        WHERE json_extract(j.value, '$.bus') = '\(Self.bus)'
                          AND json_extract(j.value, '$.noteNumber') = \(notes.lyric)),
                       (SELECT group_concat(json_extract(j.value, '$.noteVelocity')) FROM json_each(v.midiCues) j
                        WHERE json_extract(j.value, '$.bus') = '\(Self.bus)'
                          AND json_extract(j.value, '$.noteNumber') = \(notes.playlist)),
                       json_array_length(coalesce(m.sections, '[]')) > 0,
                       s.localId = l.activeMultitrackVersionId
                FROM setlistMultitrackVersion s
                JOIN setlist l ON l.localId = s.setlistId
                JOIN multitrackVersion v ON v.localId = s.editableVersionId
                JOIN multitrack m ON m.localId = v.multitrackId
                WHERE s.setlistId = ? ORDER BY s.position
                """, [setlistId])
                .map { SetlistSong(id: $0[0] ?? "", name: $0[1] ?? "", versionName: $0[2] ?? "",
                                   lyricCues: Int($0[3] ?? "") ?? 0,
                                   playlistCues: ($0[4] ?? "").split(separator: ",").compactMap { Int($0) },
                                   hasSections: $0[5] == "1", isActive: $0[6] == "1") }
        }
    }

    public func song(versionId: String) throws -> PrimeSong {
        try withDB(readonly: true) { db in
            guard let row = try query(db, """
                SELECT m.name, m.tempo, m.sections, v.arrangedSections
                FROM multitrackVersion v JOIN multitrack m ON m.localId = v.multitrackId
                WHERE v.localId = ?
                """, [versionId]).first else {
                throw PrimeError.notFound("That song is no longer in Prime. Pick it again.")
            }
            let sections = Self.parseSections(row[2]).sorted { $0.startBeat < $1.startBeat }
            let byId = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let arranged = Self.jsonArray(row[3]).compactMap { Self.string($0["sectionId"]).flatMap { byId[$0] } }
            return PrimeSong(versionId: versionId, name: row[0] ?? "", tempo: Double(row[1] ?? "") ?? 0,
                             sections: sections, arrangement: arranged.isEmpty ? sections : arranged)
        }
    }

    // MARK: Writing

    /// Replaces each version's cues on that note (lyrics bus only), keeping every other cue.
    /// Backs up the whole database first, writes everything in one transaction, and returns
    /// the backup's location.
    @discardableResult
    public func write(_ writes: [CueWrite], lyricNote: Int = CueNotes().lyric) throws -> URL {
        let isLive = url.resolvingSymlinksInPath().path.hasPrefix(Self.containerDocs.resolvingSymlinksInPath().path)
        if isLive && Self.primeIsRunning { throw PrimeError.primeRunning }
        try checkSchema()
        let backup = try withDB(readonly: false) { db in
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let stamp = DateFormatter.backupStamp.string(from: Date())
            let backup = backupDir.appendingPathComponent("\(url.lastPathComponent)-\(stamp)-pre-record.bak")
            try exec(db, "VACUUM INTO ?", [backup.path])

            try exec(db, "BEGIN IMMEDIATE")
            do {
                var nextId = 100_000 + (Int(try query(db, """
                    SELECT max(CAST(json_extract(j.value, '$.id') AS INTEGER))
                    FROM multitrackVersion v, json_each(v.midiCues) j
                    """).first?[0] ?? "") ?? 0)
                for w in writes {
                    let current = try query(db, "SELECT midiCues FROM multitrackVersion WHERE localId = ?", [w.versionId])
                    guard let row = current.first else {
                        throw PrimeError.notFound("A song was removed from Prime before saving. Nothing was saved.")
                    }
                    var kept = Self.jsonArray(row[0]).filter {
                        !(($0["noteNumber"] as? Int) == w.note && ($0["bus"] as? String) == Self.bus)
                    }
                    for cue in w.cues {
                        kept.append([
                            "bus": Self.bus, "channel": w.channel, "id": String(nextId),
                            "isMigratedToBus": true, "messageType": ["noteOn": [String: Any]()],
                            "multitrackSectionId": cue.sectionId, "noteNumber": w.note,
                            "noteVelocity": cue.velocity, "sectionProgress": cue.progress,
                        ])
                        nextId += 1
                    }
                    let data = try JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys, .withoutEscapingSlashes])
                    try exec(db, "UPDATE multitrackVersion SET midiCues = ? WHERE localId = ?",
                             [String(decoding: data, as: UTF8.self), w.versionId])
                }
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
            return backup
        }
        for w in writes where w.note == lyricNote {
            if let song = try? song(versionId: w.versionId) { try? saveBaseline(song: song, cues: w.cues) }
        }
        return backup
    }

    /// Same sidecar prime.py writes, so the skill's `learn` command can diff later hand edits.
    private func saveBaseline(song: PrimeSong, cues: [(velocity: Int, sectionId: String, progress: Double)]) throws {
        let byId = Dictionary(song.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var beats: [String: Double] = [:]
        for c in cues {
            guard let s = byId[c.sectionId] else { continue }
            beats[String(c.velocity)] = ((s.startBeat + c.progress * s.beats) * 10_000).rounded() / 10_000
        }
        let dir = backupDir.appendingPathComponent("baselines")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: beats, options: [.sortedKeys, .prettyPrinted])
            .write(to: dir.appendingPathComponent("\(song.versionId).json"))
    }

    // MARK: SQLite plumbing

    private func withDB<T>(readonly: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let flags = readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            throw PrimeError.sqlite(message)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        return try body(db)
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ args: [String] = []) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw PrimeError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient) }
        var rows: [[String?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw PrimeError.sqlite(String(cString: sqlite3_errmsg(db))) }
            rows.append((0..<sqlite3_column_count(stmt)).map { col in
                sqlite3_column_text(stmt, col).map { String(cString: $0) }
            })
        }
        return rows
    }

    private func exec(_ db: OpaquePointer, _ sql: String, _ args: [String] = []) throws {
        _ = try query(db, sql, args)
    }

    static func jsonArray(_ text: String?) -> [[String: Any]] {
        guard let data = text?.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return array
    }

    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func parseSections(_ text: String?) -> [PrimeSection] {
        jsonArray(text).compactMap { s in
            guard let id = string(s["id"]),
                  let start = (s["startBeat"] as? NSNumber)?.doubleValue,
                  let end = (s["endBeat"] as? NSNumber)?.doubleValue else { return nil }
            return PrimeSection(id: id, type: s["sectionType"] as? String ?? "", startBeat: start, endBeat: end)
        }
    }
}

extension DateFormatter {
    static let backupStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()
}
