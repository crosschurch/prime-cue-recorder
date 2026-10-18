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
