import Foundation

/// One section of a Prime song, in the song's own beat coordinates.
public struct PrimeSection: Equatable, Sendable {
    public let id: String
    public let type: String
    public let startBeat: Double
    public let endBeat: Double
    public var beats: Double { endBeat - startBeat }

    public init(id: String, type: String, startBeat: Double, endBeat: Double) {
        self.id = id; self.type = type; self.startBeat = startBeat; self.endBeat = endBeat
    }
}

/// A slide change seen in ProPresenter while recording.
public struct SlideClick: Equatable, Sendable {
    public let time: Double     // seconds since recording started
    public let slide: Int       // 1-based slide number, which is the MIDI velocity
    public let group: String    // ProPresenter group name ("Verse 1", "Chorus")
    public let text: String

    public init(time: Double, slide: Int, group: String, text: String) {
        self.time = time; self.slide = slide; self.group = group; self.text = text
    }
}

public struct PlannedCue: Equatable, Sendable {
    public let slide: Int
    public let sectionId: String
    public let progress: Double // 0-1 within the section, how Prime stores cues
    public let beat: Double     // beat in the played arrangement, from song start
    public let sectionType: String
    public let text: String
}

public struct CuePlan: Sendable {
    public var cues: [PlannedCue] = []
    public var anchors = 0          // section changes the timing was lined up with
    public var fitError: Double?    // RMS distance of those section changes, in beats
    public var warnings: [String] = []
}

/// Turns recorded slide clicks into Prime cue positions.
///
/// Prime knows where every section starts but nothing about when we clicked.
/// Each click that enters a new ProPresenter group ("Verse 1", "Chorus") is
/// paired with the matching Prime section start, and a straight line through
/// those pairs maps click time to song beat. The operator's own lead is
/// absorbed by that line, so `lead` is applied back on top for lyric slides.
public enum CueEngine {
    static let families = ["prechorus", "chorus", "verse", "bridge", "tag", "intro", "outro",
                           "interlude", "instrumental", "refrain", "turn", "end", "break", "solo"]

    /// "Verse 2", "verse_2", "Down Chorus", "chorus_2" -> "verse" / "chorus"
    public static func family(_ name: String) -> String? {
        var s = name.lowercased().filter(\.isLetter)
        if s.hasPrefix("down") { s.removeFirst(4) }
        return families.first { s.hasPrefix($0) }
    }

    public static func plan(clicks raw: [SlideClick], arrangement all: [PrimeSection],
                            tempo: Double, lead: Double) -> CuePlan {
        var plan = CuePlan()
        let arrangement = all.filter { $0.beats > 0 }
        guard !arrangement.isEmpty else {
            plan.warnings.append("This song has no sections in Prime.")
            return plan
        }
        // A slide replaced within 0.6 s was a slip of the finger, not a line.
        let clicks = raw.indices.filter { $0 + 1 == raw.count || raw[$0 + 1].time - raw[$0].time >= 0.6 }
            .map { raw[$0] }

        var starts: [Double] = []
        var total = 0.0
        for s in arrangement { starts.append(total); total += s.beats }
        let nominal = tempo > 0 ? tempo / 60 : 2

        let entries: [(time: Double, family: String)] = clicks.indices.compactMap { i in
            guard let f = family(clicks[i].group), i == 0 || clicks[i - 1].group != clicks[i].group
            else { return nil }
            return (clicks[i].time, f)
        }
        func sections(of f: String) -> [Int] {
            arrangement.indices.filter { family(arrangement[$0].type) == f }
        }
        // Start from the first verse click landing on the first verse, at the song's tempo.
        guard let first = entries.first(where: { $0.family == "verse" }) ?? entries.first,
              let firstSection = sections(of: first.family).first else {
            plan.warnings.append("None of the ProPresenter groups (Verse 1, Chorus…) match a section "
                                 + "in Prime, so there was nothing to line the timing up with.")
            return plan
        }
        var slope = nominal
        var intercept = starts[firstSection] - nominal * first.time
        var pairs: [(time: Double, beat: Double)] = []
        var slopeRejected = false
        for _ in 0..<3 {
            let matched: [(time: Double, beat: Double)] = entries.compactMap { e in
                let predicted = intercept + slope * e.time
                guard let best = sections(of: e.family).min(by: {
                    abs(starts[$0] - predicted) < abs(starts[$1] - predicted)
                }), abs(starts[best] - predicted) <= max(8, arrangement[best].beats / 2) else { return nil }
                return (e.time, starts[best])
            }
            guard !matched.isEmpty else { break }
            pairs = matched
            (slope, intercept, slopeRejected) = fit(pairs, nominal: nominal)
        }
        plan.anchors = pairs.count
        if !pairs.isEmpty {
            let sq = pairs.map { pow(intercept + slope * $0.time - $0.beat, 2) }.reduce(0, +)
            plan.fitError = (sq / Double(pairs.count)).squareRoot()
        }
        if slopeRejected {
            plan.warnings.append("The time between section changes didn't match the song's tempo, so "
                                 + "the song's tempo was used instead. Did the song stop, loop, or jump?")
        }
        if let err = plan.fitError, err > 2 {
            plan.warnings.append(String(format: "Section changes were off by about %.1f beats on "
                                        + "average. Check the result, or record it again.", err))
        }

        var firstIndex: [String: Int] = [:]
        for (i, s) in arrangement.enumerated() where firstIndex[s.id] == nil { firstIndex[s.id] = i }
        var repeated: [String] = []
        var early = 0
        for c in clicks {
            let isBlank = c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var beat = intercept + slope * c.time - (isBlank ? 0 : lead)
            if beat < 0 { early += 1 }
            beat = min(max((beat * 4).rounded() / 4, 0), total - 0.01)
            let i = starts.lastIndex { $0 <= beat } ?? 0
            let s = arrangement[i]
            // Cues belong to a section, so a section Prime plays twice fires them both times.
            guard firstIndex[s.id] == i else {
                if !repeated.contains(s.type) { repeated.append(s.type) }
                continue
            }
            plan.cues.append(PlannedCue(
                slide: c.slide, sectionId: s.id,
                progress: ((beat - starts[i]) / s.beats * 1_000_000).rounded() / 1_000_000,
                beat: beat, sectionType: s.type, text: c.text))
        }
        if early > 0 {
            plan.warnings.append("\(early) slide(s) were clicked before the song started; "
                                 + "they'll fire at the very start.")
        }
        if !repeated.isEmpty {
            plan.warnings.append("Prime plays the same section more than once ("
                                 + repeated.joined(separator: ", ") + "). Its cues fire every time it "
                                 + "plays, so slides clicked during the repeat were left out.")
        }
        return plan
    }

    /// Least-squares line through (time, beat). Keeps the song's tempo when there are too
    /// few points or the fitted tempo is more than 10% off, which means the take wasn't straight.
    static func fit(_ pairs: [(time: Double, beat: Double)], nominal: Double)
        -> (slope: Double, intercept: Double, rejected: Bool) {
        let n = Double(pairs.count)
        let mt = pairs.map(\.time).reduce(0, +) / n
        let mb = pairs.map(\.beat).reduce(0, +) / n
        let vt = pairs.map { ($0.time - mt) * ($0.time - mt) }.reduce(0, +)
        var slope = nominal
        var rejected = false
        if pairs.count >= 2, vt > 1 {
            let s = pairs.map { ($0.time - mt) * ($0.beat - mb) }.reduce(0, +) / vt
            if abs(s / nominal - 1) < 0.1 { slope = s } else { rejected = true }
        }
        return (slope, mb - slope * mt, rejected)
    }
}
