#if DEBUG
import AppKit
import CueCore

/// PCR_DEMO=ready|recording|review|waiting|saved|shift swift run (add -clock for a song without sections) — sample data for checking the UI
/// without ProPresenter or a Prime library.
extension AppModel {
    func loadDemo(_ demo: String) {
        let clock = demo.hasSuffix("-clock")
        let phase = clock ? String(demo.dropLast(6)) : demo
        ppPort = ""  // so nothing tries to reach a real ProPresenter
        let sections = [("intro", 8), ("verse_1", 32), ("chorus", 32), ("verse_2", 32), ("chorus_2", 32),
                        ("bridge", 32), ("outro", 16)]
        var start = 0.0
        let arrangement = sections.enumerated().map { i, s in
            defer { start += Double(s.1) }
            return PrimeSection(id: "\(i)", type: s.0, startBeat: start, endBeat: start + Double(s.1))
        }
        setlists = [Setlist(id: "s", name: "Sunday Morning", serviceDate: "2026-10-18")]
        setlistId = "s"
        songs = [
            SetlistSong(id: "a", name: "Holy Forever", versionName: "", lyricCues: 31, playlistCues: [3], isActive: false),
            SetlistSong(id: "v", name: "Goodness of God", versionName: "", lyricCues: 0, isActive: true),
            SetlistSong(id: "b", name: "Host & Announcements", versionName: "", lyricCues: 0, hasSections: false, isMusic: false,
                        isActive: false),
            SetlistSong(id: "c", name: "What A God (Live)", versionName: "", lyricCues: 0, playlistCues: [7], isActive: false),
            SetlistSong(id: "d", name: "What a God / He Wears a Crown", versionName: "", lyricCues: 44,
                        playlistCues: [8, 9], isActive: false),
        ]
        playlists = [PPPlaylist(id: "p", name: "10/18 Sunday")]
        playlistId = "p"
        playlistItems = [
            PPPlaylistItem(id: "0", name: "Pre-Service", index: 0, type: "header"),
            PPPlaylistItem(id: "1", name: "Countdown", index: 1, type: "media"),
            PPPlaylistItem(id: "2", name: "Holy Forever", index: 2, type: "presentation"),
            PPPlaylistItem(id: "3", name: "Goodness of God", index: 3, type: "presentation"),
            PPPlaylistItem(id: "4", name: "Host & Announcements", index: 4, type: "presentation"),
            PPPlaylistItem(id: "5", name: "Offering", index: 5, type: "presentation"),
            PPPlaylistItem(id: "6", name: "What A God", index: 6, type: "presentation"),
        ]
        itemNumbers = WeekSetup.match(songs: songs, items: playlistItems).mapValues { itemNumber($0) }
        versionId = "v"
        error = nil
        song = clock
            ? PrimeSong(versionId: "v", name: "Goodness of God", tempo: 126, sections: [], arrangement: [],
                        duration: 277.6)
            : PrimeSong(versionId: "v", name: "Goodness of God", tempo: 126, sections: arrangement,
                        arrangement: arrangement)
        connection = .connected("ProPresenter 7.16")
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
        for delay in [0.3, 1.0, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApplication.shared.activate()
                NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
        switch phase {
        case "recording": self.phase = .recording
        case "review": self.phase = .review
        case "waiting": saveState = .waitingForPrime
        case "shift":
            clicks = []
            demoShiftPreview = ShiftPreview(songs: 3, cues: 118, pinned: 2,
                                            skipped: ["Goodness of God: recorded but not saved yet"])
            showShift = true
        case "saved":
            saveState = .saved("Saved 2 playlist cues and lyrics for 1 song. Open Prime, check the songs, "
                               + "then save them to the cloud.")
        default: clicks = []
        }
    }
}
#endif
