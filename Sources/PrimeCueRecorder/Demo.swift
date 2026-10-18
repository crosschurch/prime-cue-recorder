#if DEBUG
import AppKit
import CueCore

/// PCR_DEMO=ready|recording|review|waiting|done swift run — sample data for checking the UI
/// without ProPresenter or a Prime library.
extension AppModel {
    func loadDemo(_ phase: String) {
        let sections = [("intro", 8), ("verse_1", 32), ("chorus", 32), ("verse_2", 32), ("chorus_2", 32),
                        ("bridge", 32), ("outro", 16)]
        var start = 0.0
        let arrangement = sections.enumerated().map { i, s in
            defer { start += Double(s.1) }
            return PrimeSection(id: "\(i)", type: s.0, startBeat: start, endBeat: start + Double(s.1))
        }
        setlists = [Setlist(id: "s", name: "Sunday Morning", serviceDate: "2026-10-18")]
        setlistId = "s"
        songs = [SetlistSong(id: "v", name: "Goodness of God", versionName: "Default", lyricCues: 0, isActive: true)]
        versionId = "v"
        song = PrimeSong(versionId: "v", name: "Goodness of God", tempo: 126, sections: arrangement,
                         arrangement: arrangement)
        connection = .connected("ProPresenter 7.16")
        ppPort = "50001"
        let lines = [("Verse 1", "I love You, Lord"), ("Verse 1", "For Your mercy never fails me"),
                     ("Verse 1", "From the moment I wake up"), ("Verse 1", "With every breath I have"),
                     ("Chorus", "All my life You have been faithful"), ("Chorus", "And all my life You have been so, so good"),
                     ("Chorus", "With every breath that I am able"), ("Chorus", "I will sing of the goodness of God"),
                     ("Verse 2", "I love Your voice"), ("Verse 2", "You are my friend")]
        let bps = 126.0 / 60
        clicks = lines.enumerated().map { i, l in
            let beat = l.0 == "Verse 1" ? 6 + Double(i) * 8 : l.0 == "Chorus" ? 38 + Double(i - 4) * 8 : 70 + Double(i - 8) * 8
            return SlideClick(time: 2.4 + beat / bps, slide: i + 2, group: l.0, text: l.1)
        }
        presentationName = "Goodness of God"
        recordingStartedAt = Date().addingTimeInterval(-41)
        // `swift run` launches a bare executable, which macOS treats as a background tool.
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApplication.shared.activate() }
        self.phase = switch phase {
        case "recording": .recording
        case "review": .review
        case "waiting": .waitingForPrime
        case "done": .done("Saved 10 cues to “Goodness of God”. Open Prime, play it through to check, then save the song to the cloud.")
        default: .ready
        }
    }
}
#endif
