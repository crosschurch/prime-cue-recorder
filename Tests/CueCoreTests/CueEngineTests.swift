import XCTest
@testable import CueCore

final class CueEngineTests: XCTestCase {
    // 120 BPM = 2 beats/s. Prime sections in song beats.
    let intro = PrimeSection(id: "i", type: "intro", startBeat: 0, endBeat: 8)
    let verse = PrimeSection(id: "v1", type: "verse_1", startBeat: 8, endBeat: 24)
    let chorus = PrimeSection(id: "c", type: "chorus", startBeat: 24, endBeat: 40)
    let verse2 = PrimeSection(id: "v2", type: "verse_2", startBeat: 40, endBeat: 56)
    let outro = PrimeSection(id: "o", type: "outro", startBeat: 56, endBeat: 64)

    /// Operator clicks each line 2 beats early; Prime started playing 3 s after Record.
    func click(_ beat: Double, _ slide: Int, _ group: String, _ text: String = "line") -> SlideClick {
        SlideClick(time: 3 + (beat - 2) / 2, slide: slide, group: group, text: text)
    }

    func testStraightTakeKeepsOperatorTimingAndFiresEarly() {
        let clicks = [
            click(8, 2, "Verse 1"), click(12, 3, "Verse 1"), click(16, 4, "Verse 1"), click(20, 5, "Verse 1"),
            click(24, 6, "Chorus"), click(32, 7, "Chorus"),
            click(40, 8, "Verse 2"), click(48, 9, "Verse 2"),
            SlideClick(time: 3 + 57 / 2, slide: 10, group: "Blank", text: ""),
        ]
        let plan = CueEngine.plan(clicks: clicks, arrangement: [intro, verse, chorus, verse2, outro],
                                  tempo: 120, leadSeconds: 1)
        XCTAssertEqual(plan.anchors, 3)
        XCTAssertEqual(plan.fitError ?? 99, 0, accuracy: 0.001)
        XCTAssertEqual(plan.cues.map(\.beat), [6, 10, 14, 18, 22, 30, 38, 46, 57])
        XCTAssertEqual(plan.cues.first?.sectionId, "i")   // early first line lands in the intro
        XCTAssertEqual(plan.cues.last?.sectionId, "o")    // blanks fire early too
        XCTAssertEqual(plan.cues[1].progress, 0.125)      // beat 10 is 2/16 into verse 1
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
    }

    func testMissingPrimeSectionDoesNotShiftTiming() {
        // ProPresenter has a pre-chorus Prime doesn't know about; it just isn't an anchor.
        let clicks = [click(8, 2, "Verse 1"), click(20, 3, "Pre-Chorus"), click(24, 4, "Chorus"), click(40, 5, "Verse 2")]
        let plan = CueEngine.plan(clicks: clicks, arrangement: [intro, verse, chorus, verse2, outro],
                                  tempo: 120, leadSeconds: 0)
        XCTAssertEqual(plan.anchors, 3)
        XCTAssertEqual(plan.cues.map(\.beat), [8, 20, 24, 40])
    }

    func testRepeatedSectionClicksAreDropped() {
        let clicks = [click(8, 2, "Verse 1"), click(24, 3, "Chorus"), click(40, 4, "Chorus")]
        let plan = CueEngine.plan(clicks: clicks, arrangement: [intro, verse, chorus, chorus],
                                  tempo: 120, leadSeconds: 0)
        XCTAssertEqual(plan.cues.map(\.slide), [2, 3])
        XCTAssertEqual(plan.warnings.count, 1)
    }

    func testNoMatchingGroupsWarns() {
        let plan = CueEngine.plan(clicks: [click(8, 1, "Slide")], arrangement: [intro, verse],
                                  tempo: 120, leadSeconds: 1)
        XCTAssertTrue(plan.cues.isEmpty)
        XCTAssertEqual(plan.warnings.count, 1)
    }

    func testFamilies() {
        XCTAssertEqual(CueEngine.family("Verse 2"), "verse")
        XCTAssertEqual(CueEngine.family("verse_2"), "verse")
        XCTAssertEqual(CueEngine.family("Pre-Chorus"), "prechorus")
        XCTAssertEqual(CueEngine.family("down_chorus"), "chorus")
        XCTAssertEqual(CueEngine.family("Ending"), "end")
        XCTAssertNil(CueEngine.family("start"))
        XCTAssertNil(CueEngine.family("Blank"))
    }
}

final class WeekSetupTests: XCTestCase {
    func song(_ id: String, _ name: String) -> SetlistSong {
        SetlistSong(id: id, name: name, versionName: "", lyricCues: 0, isActive: false)
    }

    func testMatchesTitlesLooselyAndInOrder() {
        let items = [
            PPPlaylistItem(id: "h", name: "Worship", index: 0, type: "header"),
            PPPlaylistItem(id: "a", name: "Welcome", index: 1, type: "presentation"),
            PPPlaylistItem(id: "b", name: "What A God", index: 2, type: "presentation"),
            PPPlaylistItem(id: "c", name: "Holy Forever (Chris Tomlin)", index: 3, type: "presentation"),
            PPPlaylistItem(id: "d", name: "What A God", index: 4, type: "presentation"),
        ]
        let songs = [song("1", "What A God (Live)"), song("2", "Holy Forever"), song("3", "What a God"),
                     song("4", "Click Only")]
        let m = WeekSetup.match(songs: songs, items: items)
        XCTAssertEqual(m["1"]?.number, 3)
        XCTAssertEqual(m["2"]?.number, 4)
        XCTAssertEqual(m["3"]?.number, 5)
        XCTAssertNil(m["4"])
    }

    func testPlaylistCueIsOneBeatIn() {
        let pos = WeekSetup.playlistCuePosition(arrangement: [PrimeSection(id: "s", type: "start", startBeat: 1, endBeat: 9)])
        XCTAssertEqual(pos.sectionId, "s")
        XCTAssertEqual(pos.progress, 0.125)
        XCTAssertEqual(WeekSetup.playlistCuePosition(arrangement: []).sectionId, "")
    }
}

final class ClockTimingTests: XCTestCase {
    let clicks = [
        SlideClick(time: 2.8, slide: 5, group: "Chorus", text: "slip"),
        SlideClick(time: 3.0, slide: 2, group: "Verse 1", text: "a"),
        SlideClick(time: 13.0, slide: 3, group: "Verse 1", text: "b"),
        SlideClick(time: 23.0, slide: 4, group: "Chorus", text: "c"),
    ]

    func testCuesAreAFractionOfTheSongFromTheFirstSlide() {
        // Record was pressed 9 s before Play: the first slide is really 12 s into a 200 s song.
        let plan = CueEngine.planByTime(clicks: clicks, duration: 200, firstSlideAt: 12, leadSeconds: 0.5)
        XCTAssertEqual(plan.cues.map(\.slide), [2, 3, 4])  // the slip is gone
        XCTAssertEqual(plan.cues.map(\.time), [11.5, 21.5, 31.5])
        XCTAssertEqual(plan.cues.map(\.progress), [0.0575, 0.1075, 0.1575])
        XCTAssertTrue(plan.cues.allSatisfy { $0.sectionId == "" })
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func testRecordedTimingWithoutAFirstSlideTime() {
        let plan = CueEngine.planByTime(clicks: clicks, duration: 100, firstSlideAt: nil, leadSeconds: 0.5)
        XCTAssertEqual(plan.cues.first?.time, 2.5)
    }

    func testClicksPastTheEndAreWarnedAndClamped() {
        let plan = CueEngine.planByTime(clicks: clicks, duration: 30, firstSlideAt: 12, leadSeconds: 0)
        XCTAssertEqual(plan.cues.last?.time, 29.99)
        XCTAssertEqual(plan.warnings.count, 1)
    }
}

final class CueShiftTests: XCTestCase {
    // 120 BPM: half a second is one beat.
    let intro = PrimeSection(id: "i", type: "intro", startBeat: 0, endBeat: 8)
    let verse = PrimeSection(id: "v", type: "verse_1", startBeat: 8, endBeat: 40)
    let chorus = PrimeSection(id: "c", type: "chorus", startBeat: 40, endBeat: 72)

    func song(_ arrangement: [PrimeSection]) -> PrimeSong {
        PrimeSong(versionId: "x", name: "x", tempo: 120, sections: [intro, verse, chorus], arrangement: arrangement)
    }

    func testMovesWithinASection() {
        let cue = SavedCue(id: "1", velocity: 2, sectionId: "v", progress: 0.5)  // beat 16 of 32
        let r = CueShift.shift([cue], in: song([intro, verse, chorus]), by: -0.5)
        XCTAssertEqual(r.moves["1"]?.sectionId, "v")
        XCTAssertEqual(r.moves["1"]?.progress, 0.46875)  // beat 15
        XCTAssertEqual(r.pinned, 0)
    }

    func testCrossesIntoThePreviousSectionWhenEachPlaysOnce() {
        let cue = SavedCue(id: "1", velocity: 2, sectionId: "v", progress: 0)
        let r = CueShift.shift([cue], in: song([intro, verse, chorus]), by: -0.5)
        XCTAssertEqual(r.moves["1"]?.sectionId, "i")
        XCTAssertEqual(r.moves["1"]?.progress, 0.875)  // beat 7 of 8
    }

    func testPinsAtTheSectionStartWhenTheSectionRepeats() {
        let cue = SavedCue(id: "1", velocity: 5, sectionId: "c", progress: 0)
        let r = CueShift.shift([cue], in: song([intro, verse, chorus, verse, chorus]), by: -0.5)
        XCTAssertNil(r.moves["1"])  // already at the start, nothing to change
        XCTAssertEqual(r.pinned, 1)
    }

    func testLaterUndoesEarlier() {
        let cues = [SavedCue(id: "1", velocity: 2, sectionId: "v", progress: 0),
                    SavedCue(id: "2", velocity: 3, sectionId: "c", progress: 0.25)]
        let s = song([intro, verse, chorus])
        let earlier = CueShift.shift(cues, in: s, by: -0.5)
        let moved = cues.map { c in earlier.moves[c.id].map {
            SavedCue(id: c.id, velocity: c.velocity, sectionId: $0.sectionId, progress: $0.progress) } ?? c }
        let back = CueShift.shift(moved, in: s, by: 0.5)
        XCTAssertEqual(back.moves["1"]?.sectionId, "v")
        XCTAssertEqual(back.moves["1"]?.progress, 0)
        XCTAssertEqual(back.moves["2"]?.progress, 0.25)
    }

    func testSongsWithoutSectionsMoveByTheClock() {
        let s = PrimeSong(versionId: "x", name: "x", tempo: 70, sections: [], arrangement: [], duration: 200)
        let cues = [SavedCue(id: "1", velocity: 2, sectionId: "", progress: 0.05),     // 10 s
                    SavedCue(id: "2", velocity: 3, sectionId: "", progress: 0.001)]    // 0.2 s
        let r = CueShift.shift(cues, in: s, by: -0.5)
        XCTAssertEqual(r.moves["1"]?.progress, 0.0475)  // 9.5 s
        XCTAssertEqual(r.moves["2"]?.progress, 0)
        XCTAssertEqual(r.pinned, 1)
        let unknown = PrimeSong(versionId: "x", name: "x", tempo: 70, sections: [], arrangement: [])
        XCTAssertNotNil(CueShift.shift(cues, in: unknown, by: -0.5).skipped)
    }
}
