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
    public let isActive: Bool

    public init(id: String, name: String, versionName: String, lyricCues: Int, isActive: Bool) {
        self.id = id; self.name = name; self.versionName = versionName
        self.lyricCues = lyricCues; self.isActive = isActive
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
    public static let lyricNote = 19
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

    public func songs(setlistId: String) throws -> [SetlistSong] {
        try withDB(readonly: true) { db in
            try query(db, """
                SELECT v.localId, m.name, v.name,
                       (SELECT count(*) FROM json_each(v.midiCues) j
                        WHERE json_extract(j.value, '$.noteNumber') = \(Self.lyricNote)),
                       s.localId = l.activeMultitrackVersionId
                FROM setlistMultitrackVersion s
                JOIN setlist l ON l.localId = s.setlistId
                JOIN multitrackVersion v ON v.localId = s.editableVersionId
                JOIN multitrack m ON m.localId = v.multitrackId
                WHERE s.setlistId = ? ORDER BY s.position
                """, [setlistId])
                .map { SetlistSong(id: $0[0] ?? "", name: $0[1] ?? "", versionName: $0[2] ?? "",
                                   lyricCues: Int($0[3] ?? "") ?? 0, isActive: $0[4] == "1") }
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

    /// Replaces the version's lyric cues, keeping every other cue (lights, utility notes).
    /// Backs up the whole database first and returns the backup's location.
    @discardableResult
    public func writeLyricCues(versionId: String, cues: [PlannedCue]) throws -> URL {
        let isLive = url.resolvingSymlinksInPath().path.hasPrefix(Self.containerDocs.resolvingSymlinksInPath().path)
        if isLive && Self.primeIsRunning { throw PrimeError.primeRunning }
        try checkSchema()
        let song = try song(versionId: versionId)
        return try withDB(readonly: false) { db in
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let stamp = DateFormatter.backupStamp.string(from: Date())
            let backup = backupDir.appendingPathComponent("\(url.lastPathComponent)-\(stamp)-pre-record.bak")
            try exec(db, "VACUUM INTO ?", [backup.path])

            try exec(db, "BEGIN IMMEDIATE")
            do {
                let current = try query(db, "SELECT midiCues FROM multitrackVersion WHERE localId = ?", [versionId])
                var kept = Self.jsonArray(current.first?[0] ?? nil).filter {
                    ($0["noteNumber"] as? Int) != Self.lyricNote
                }
                let maxId = Int(try query(db, """
                    SELECT max(CAST(json_extract(j.value, '$.id') AS INTEGER))
                    FROM multitrackVersion v, json_each(v.midiCues) j
                    """).first?[0] ?? "") ?? 0
                for (i, cue) in cues.sorted(by: { $0.slide < $1.slide }).enumerated() {
                    kept.append([
                        "bus": "lyrics", "channel": 0, "id": String(maxId + 100_000 + i),
                        "isMigratedToBus": true, "messageType": ["noteOn": [String: Any]()],
                        "multitrackSectionId": cue.sectionId, "noteNumber": Self.lyricNote,
                        "noteVelocity": cue.slide, "sectionProgress": cue.progress,
                    ])
                }
                let data = try JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys, .withoutEscapingSlashes])
                try exec(db, "UPDATE multitrackVersion SET midiCues = ? WHERE localId = ?",
                         [String(decoding: data, as: UTF8.self), versionId])
                try exec(db, "COMMIT")
            } catch {
                try? exec(db, "ROLLBACK")
                throw error
            }
            try? saveBaseline(song: song, cues: cues)
            return backup
        }
    }

    /// Same sidecar prime.py writes, so the skill's `learn` command can diff later hand edits.
    private func saveBaseline(song: PrimeSong, cues: [PlannedCue]) throws {
        let byId = Dictionary(song.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var beats: [String: Double] = [:]
        for c in cues {
            guard let s = byId[c.sectionId] else { continue }
            beats[String(c.slide)] = ((s.startBeat + c.progress * s.beats) * 10_000).rounded() / 10_000
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
