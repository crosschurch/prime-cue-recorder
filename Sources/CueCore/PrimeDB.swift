import AppKit
import AVFoundation
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
    public let isMusic: Bool        // false for spoken items like "Host / Announcements" (no tempo)
    public let isActive: Bool

    public var needsLyrics: Bool { isMusic && lyricCues == 0 }

    public init(id: String, name: String, versionName: String, lyricCues: Int, playlistCues: [Int] = [],
                hasSections: Bool = true, isMusic: Bool = true, isActive: Bool) {
        self.id = id; self.name = name; self.versionName = versionName; self.lyricCues = lyricCues
        self.playlistCues = playlistCues; self.hasSections = hasSections; self.isMusic = isMusic
        self.isActive = isActive
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

/// A cue already saved in Prime.
public struct SavedCue: Equatable, Sendable {
    public let id: String
    public let velocity: Int
    public let sectionId: String
    public let progress: Double

    public init(id: String, velocity: Int, sectionId: String, progress: Double) {
        self.id = id; self.velocity = velocity; self.sectionId = sectionId; self.progress = progress
    }

    init?(_ cue: [String: Any], note: Int) {
        guard (cue["bus"] as? String) == PrimeDB.bus, (cue["noteNumber"] as? Int) == note,
              let id = PrimeDB.string(cue["id"]) else { return nil }
        self.init(id: id, velocity: (cue["noteVelocity"] as? Int) ?? 0,
                  sectionId: PrimeDB.string(cue["multitrackSectionId"]) ?? "",
                  progress: (cue["sectionProgress"] as? NSNumber)?.doubleValue ?? 0)
    }
}

public struct PrimeSong: Sendable {
    public let versionId: String
    public let name: String
    public let tempo: Double
    public let sections: [PrimeSection]     // song order, Prime's beat coordinates
    public let arrangement: [PrimeSection]  // what this version actually plays
    /// Full length in seconds. Only looked up for songs without sections, which are timed by
    /// the clock; nil when the audio isn't downloaded.
    public let duration: Double?

    public var hasSections: Bool { arrangement.contains { $0.beats > 0 } }

    public init(versionId: String, name: String, tempo: Double, sections: [PrimeSection],
                arrangement: [PrimeSection], duration: Double? = nil) {
        self.versionId = versionId; self.name = name; self.tempo = tempo
        self.sections = sections; self.arrangement = arrangement; self.duration = duration
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
                       s.localId = l.activeMultitrackVersionId,
                       coalesce(m.tempo, 0) > 0
                FROM setlistMultitrackVersion s
                JOIN setlist l ON l.localId = s.setlistId
                JOIN multitrackVersion v ON v.localId = s.editableVersionId
                JOIN multitrack m ON m.localId = v.multitrackId
                WHERE s.setlistId = ? ORDER BY s.position
                """, [setlistId])
                .map { SetlistSong(id: $0[0] ?? "", name: $0[1] ?? "", versionName: $0[2] ?? "",
                                   lyricCues: Int($0[3] ?? "") ?? 0,
                                   playlistCues: ($0[4] ?? "").split(separator: ",").compactMap { Int($0) },
                                   hasSections: $0[5] == "1", isMusic: $0[7] == "1", isActive: $0[6] == "1") }
        }
    }

    public func song(versionId: String) throws -> PrimeSong {
        try withDB(readonly: true) { db in
            guard let row = try query(db, """
                SELECT m.name, m.tempo, m.sections, v.arrangedSections, m.localId, m.duration
                FROM multitrackVersion v JOIN multitrack m ON m.localId = v.multitrackId
                WHERE v.localId = ?
                """, [versionId]).first else {
                throw PrimeError.notFound("That song is no longer in Prime. Pick it again.")
            }
            let sections = Self.parseSections(row[2]).sorted { $0.startBeat < $1.startBeat }
            let byId = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let arranged = Self.jsonArray(row[3]).compactMap { Self.string($0["sectionId"]).flatMap { byId[$0] } }
            let song = PrimeSong(versionId: versionId, name: row[0] ?? "", tempo: Double(row[1] ?? "") ?? 0,
                                 sections: sections, arrangement: arranged.isEmpty ? sections : arranged)
            guard !song.hasSections else { return song }
            var duration = Double(row[5] ?? "").flatMap { $0 > 0 ? $0 : nil }
            if duration == nil {
                let tracks = try query(db, "SELECT localId FROM track WHERE multitrackId = ?", [row[4] ?? ""])
                duration = Self.audioDuration(trackIds: tracks.compactMap { $0[0] })
            }
            return PrimeSong(versionId: versionId, name: song.name, tempo: song.tempo, sections: sections,
                             arrangement: song.arrangement, duration: duration)
        }
    }

    /// The longest of a song's downloaded stems. Prime keeps them as <track localId>.m4a in a
    /// Tracks folder a couple of oddly named folders down from Documents/PRIME.
    static func audioDuration(trackIds: [String]) -> Double? {
        let fm = FileManager.default
        let root = containerDocs.appendingPathComponent("PRIME")
        let level1 = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let folders = level1.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .map { $0.appendingPathComponent("Tracks") }
        let lengths = trackIds.compactMap { id -> Double? in
            for folder in folders {
                let url = folder.appendingPathComponent("\(id).m4a")
                guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { continue }
                return Double(file.length) / file.fileFormat.sampleRate
            }
            return nil
        }
        return lengths.max()
    }

    // MARK: Writing

    /// Replaces each version's cues on that note (lyrics bus only), keeping every other cue.
    /// Backs up the whole database first, writes everything in one transaction, and returns
    /// the backup's location.
    @discardableResult
    public func write(_ writes: [CueWrite], lyricNote: Int = CueNotes().lyric) throws -> URL {
        let backup = try modify(label: "pre-record") { db in
            var nextId = 100_000 + (Int(try query(db, """
                SELECT max(CAST(json_extract(j.value, '$.id') AS INTEGER))
                FROM multitrackVersion v, json_each(v.midiCues) j
                """).first?[0] ?? "") ?? 0)
            for w in writes {
                var kept = try midiCues(db, versionId: w.versionId).filter {
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
                try setMidiCues(db, versionId: w.versionId, kept)
            }
        }
        for w in writes where w.note == lyricNote {
            if let song = try? song(versionId: w.versionId) { try? saveBaseline(song: song, cues: w.cues) }
        }
        return backup
    }

    /// A version's cues on one note (lyrics bus only), as saved in Prime.
    public func cues(versionId: String, note: Int) throws -> [SavedCue] {
        try withDB(readonly: true) { db in
            try midiCues(db, versionId: versionId).compactMap { SavedCue($0, note: note) }
        }
    }

    /// Moves saved cues in place, keeping everything else about them (id, channel, velocity).
    /// `moves` is versionId -> cue id -> new position. Edits only those cues' two fields inside
    /// SQLite, so every other cue stays byte-for-byte the same. Backs up first, one transaction.
    @discardableResult
    public func move(_ moves: [String: [String: (sectionId: String, progress: Double)]],
                     lyricNote: Int = CueNotes().lyric) throws -> URL {
        let backup = try modify(label: "pre-shift") { db in
            for (versionId, positions) in moves {
                let rows = try query(db, """
                    SELECT j.key, CAST(json_extract(j.value, '$.id') AS TEXT)
                    FROM multitrackVersion v, json_each(v.midiCues) j
                    WHERE v.localId = ? AND json_extract(j.value, '$.bus') = '\(Self.bus)'
                      AND json_extract(j.value, '$.noteNumber') = \(lyricNote)
                    """, [versionId])
                for row in rows {
                    guard let index = row[0].flatMap(Int.init), let id = row[1], let to = positions[id] else { continue }
                    try exec(db, """
                        UPDATE multitrackVersion
                        SET midiCues = json_set(midiCues, '$[\(index)].multitrackSectionId', ?,
                                                '$[\(index)].sectionProgress', json(?))
                        WHERE localId = ? AND json_extract(midiCues, '$[\(index)].id') IS NOT NULL
                        """, [to.sectionId, String(to.progress), versionId])
                }
            }
        }
        for versionId in moves.keys {
            guard let song = try? song(versionId: versionId),
                  let saved = try? cues(versionId: versionId, note: lyricNote) else { continue }
            try? saveBaseline(song: song, cues: saved.map { ($0.velocity, $0.sectionId, $0.progress) })
        }
        return backup
    }

    /// Backs up the whole database, then runs `body` in one transaction. Returns the backup.
    private func modify(label: String, _ body: (OpaquePointer) throws -> Void) throws -> URL {
        let isLive = url.resolvingSymlinksInPath().path.hasPrefix(Self.containerDocs.resolvingSymlinksInPath().path)
        if isLive && Self.primeIsRunning { throw PrimeError.primeRunning }
        try checkSchema()
        return try withDB(readonly: false) { db in
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let stamp = DateFormatter.backupStamp.string(from: Date())
            var backup = backupDir.appendingPathComponent("\(url.lastPathComponent)-\(stamp)-\(label).bak")
            var n = 2
            while FileManager.default.fileExists(atPath: backup.path) {
                backup = backupDir.appendingPathComponent("\(url.lastPathComponent)-\(stamp)-\(label)-\(n).bak")
                n += 1
            }
            try exec(db, "VACUUM INTO ?", [backup.path])
            try exec(db, "BEGIN IMMEDIATE")
            do {
                try body(db)
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
            return backup
        }
    }

    private func midiCues(_ db: OpaquePointer, versionId: String) throws -> [[String: Any]] {
        guard let row = try query(db, "SELECT midiCues FROM multitrackVersion WHERE localId = ?", [versionId]).first else {
            throw PrimeError.notFound("A song was removed from Prime before saving. Nothing was saved.")
        }
        return Self.jsonArray(row[0])
    }

    private func setMidiCues(_ db: OpaquePointer, versionId: String, _ cues: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: cues, options: [.sortedKeys, .withoutEscapingSlashes])
        try exec(db, "UPDATE multitrackVersion SET midiCues = ? WHERE localId = ?",
                 [String(decoding: data, as: UTF8.self), versionId])
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
