import Foundation

/// Moves a song's saved lyric cues earlier or later by a number of seconds, e.g. when every
/// slide turns out to change a little late because of MIDI delay.
///
/// Prime stores a cue as a position within a section, so a cue moved past the start of its
/// section has to become a cue in the section before it. That's only possible when both
/// sections play once: a cue belongs to its section and fires every time that section plays,
/// so after a section that plays twice there's no single "section before". Those cues stop at
/// the section's edge instead and are counted in `pinned`.
public enum CueShift {
    public struct Result: Sendable {
        /// cue id -> new position, only for cues that actually moved
        public var moves: [String: (sectionId: String, progress: Double)] = [:]
        /// cues that could only move as far as the edge of their section
        public var pinned = 0
        /// cues left alone because their section isn't in the song any more
        public var unknown = 0
        /// why nothing could be moved, if so
        public var skipped: String?
    }

    /// `seconds` < 0 moves cues earlier.
    public static func shift(_ cues: [SavedCue], in song: PrimeSong, by seconds: Double) -> Result {
        var result = Result()
        guard !cues.isEmpty, seconds != 0 else { return result }

        if !song.hasSections {
            guard let duration = song.duration, duration > 0 else {
                result.skipped = "its audio isn't downloaded, so its length is unknown"
                return result
            }
            for cue in cues {
                let t = cue.progress * duration + seconds
                let clamped = min(max(t, 0), duration - 0.01)
                if clamped != t { result.pinned += 1 }
                let progress = round6(clamped / duration)
                if progress != cue.progress { result.moves[cue.id] = ("", progress) }
            }
            return result
        }

        guard song.tempo > 0 else {
            result.skipped = "it has no tempo in Prime"
            return result
        }
        let delta = seconds * song.tempo / 60  // in beats
        let byId = Dictionary(song.sections.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let order = song.arrangement.filter { $0.beats > 0 }
        let plays = Dictionary(order.map { ($0.id, 1) }, uniquingKeysWith: +)

        /// The section played right before or after `id`, when that's unambiguous.
        func neighbor(of id: String, step: Int) -> PrimeSection? {
            guard plays[id] == 1, let i = order.firstIndex(where: { $0.id == id }),
                  order.indices.contains(i + step) else { return nil }
            let next = order[i + step]
            return plays[next.id] == 1 ? next : nil
        }

        for cue in cues {
            guard let section = byId[cue.sectionId], section.beats > 0 else {
                result.unknown += 1
                continue
            }
            var current = section
            var pos = cue.progress * section.beats + delta
            var pinned = false
            // Walk into neighboring sections while the cue falls outside this one.
            while pos < 0 || pos >= current.beats {
                if pos < 0, let previous = neighbor(of: current.id, step: -1) {
                    pos += previous.beats
                    current = previous
                } else if pos >= current.beats, let next = neighbor(of: current.id, step: 1) {
                    pos -= current.beats
                    current = next
                } else {
                    pos = pos < 0 ? 0 : current.beats * 0.999
                    pinned = true
                    break
                }
            }
            if pinned { result.pinned += 1 }
            let progress = round6(pos / current.beats)
            if current.id != cue.sectionId || progress != cue.progress {
                result.moves[cue.id] = (current.id, progress)
            }
        }
        return result
    }

    static func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
}
