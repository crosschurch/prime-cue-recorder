import Foundation

public struct PPPlaylist: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct PPPlaylistItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let index: Int          // 0-based position in the playlist, headers included
    public let type: String        // "presentation", "header", "media", …
    public let presentationId: String?
    /// The arrangement this playlist item plays, which can differ from the presentation's own.
    public let arrangementId: String?

    public init(id: String, name: String, index: Int, type: String, presentationId: String? = nil,
                arrangementId: String? = nil) {
        self.id = id; self.name = name; self.index = index; self.type = type; self.presentationId = presentationId
        self.arrangementId = arrangementId
    }

    /// The velocity that selects this item: ProPresenter numbers playlist items from 1.
    public var number: Int { index + 1 }
}

/// Lines a Prime setlist up with a ProPresenter playlist for the weekly playlist-item cues.
public enum WeekSetup {
    /// "What A God (Live)", "what a god" -> "whatagod"
    public static func normalize(_ title: String) -> String {
        var t = title.lowercased()
        while let open = t.firstIndex(where: { "([".contains($0) }),
              let close = t[open...].firstIndex(where: { ")]".contains($0) }) {
            t.removeSubrange(open...close)
        }
        return t.replacingOccurrences(of: "&", with: "and").filter { $0.isLetter || $0.isNumber }
    }

    /// Prime version id -> playlist item, matched by title. Each item is used at most once,
    /// in setlist order, so a song in the set twice gets the next copy.
    public static func match(songs: [SetlistSong], items: [PPPlaylistItem]) -> [String: PPPlaylistItem] {
        var free = items.filter { $0.type != "header" }
        var result: [String: PPPlaylistItem] = [:]
        for song in songs {
            let name = normalize(song.name)
            guard !name.isEmpty else { continue }
            let exact = free.firstIndex { normalize($0.name) == name }
            let loose = exact ?? free.firstIndex {
                let other = normalize($0.name)
                return !other.isEmpty && (other.hasPrefix(name) || name.hasPrefix(other))
            }
            if let i = loose { result[song.id] = free.remove(at: i) }
        }
        return result
    }

    /// Where the playlist-item cue goes: one beat into the song, before any lyric slide.
    /// Songs without sections (pads, click-only items) use a song-level cue like Prime does.
    public static func playlistCuePosition(arrangement: [PrimeSection]) -> (sectionId: String, progress: Double) {
        guard let first = arrangement.first(where: { $0.beats > 0 }) else { return ("", 0.01) }
        return (first.id, min(1 / first.beats, 0.5))
    }
}
