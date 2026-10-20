import AppKit
import CueCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case ready, recording, review }
    enum Connection: Equatable { case unknown, checking, connected(String), failed(String) }
    enum SaveState: Equatable { case idle, waitingForPrime, saved(String) }

    /// What the weekly setup will do to a song's playlist-item cue.
    enum PlaylistStatus: Equatable {
        case noItem             // nothing matched in the ProPresenter playlist
        case correct(Int)
        case willSet(Int)
        case custom([Int])      // several playlist cues (a medley); left alone
    }

    var phase = Phase.ready { didSet { updateBusy() } }
    var connection = Connection.unknown
    var saveState = SaveState.idle { didSet { updateBusy() } }
    var error: String?
    /// Showing the Full Disk Access onboarding; Prime's library isn't read until it's done.
    var askForDiskAccess = false

    // Settings
    var ppHost: String { didSet { defaults.set(ppHost, forKey: "ppHost") } }
    var ppPort: String { didSet { defaults.set(ppPort, forKey: "ppPort") } }
    var leadSeconds: Double { didSet { defaults.set(leadSeconds, forKey: "leadSeconds") } }
    var notes: CueNotes {
        didSet {
            defaults.set(try? JSONEncoder().encode(notes), forKey: "notes")
            if notes != oldValue { loadSongs() }
        }
    }
    var countHeaders: Bool { didSet { defaults.set(countHeaders, forKey: "countHeaders"); rematch() } }

    // Prime
    var setlists: [Setlist] = []
    var songs: [SetlistSong] = []
    var setlistId: String? { didSet { if setlistId != oldValue { loadSongs() } } }
    var versionId: String? { didSet { if versionId != oldValue { loadSong() } } }
    var song: PrimeSong?

    // ProPresenter playlist
    var playlists: [PPPlaylist] = []
    var playlistId: String? { didSet { if playlistId != oldValue { Task { await loadPlaylistItems() } } } }
    var playlistItems: [PPPlaylistItem] = []
    /// Prime version id -> playlist item number. Starts from title matching; editable per song.
    var itemNumbers: [String: Int] = [:] {
        didSet { if itemNumbers[versionId ?? ""] != oldValue[versionId ?? ""] { Task { await loadSlides() } } }
    }
    /// Songs the user chose to leave without a playlist cue this week.
    var skipPlaylistCue: Set<String> = []

    // Recording
    var clicks: [SlideClick] = []
    var presentationName: String?
    private(set) var otherPresentationClicks = 0
    var recordingStartedAt: Date?
    /// Songs without sections: where the first recorded slide lands, in seconds into the song.
    /// nil keeps the recorded timing (Record and Play pressed together).
    var firstSlideAt: Double?
    /// Recorded lyric cues waiting to be saved, by Prime version id.
    var pendingLyrics: [String: CuePlan] = [:]

    // Saved lyric cues of the selected song, for moving them
    var savedCues: [SavedCue] = []
    /// The song's slides in ProPresenter, by slide number - 1; nil until read (needs the playlist item).
    var savedSlides: [(group: String, text: String)]?
    /// Moves waiting to be saved: Prime version id -> cue id -> seconds (> 0 is later).
    var cueEdits: [String: [String: Double]] = [:]
    var showShift = false
    #if DEBUG
    var demoShiftPreview: ShiftPreview?
    #endif

    private let defaults = UserDefaults.standard
    private var db: PrimeDB?
    private var recordTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?

    init() {
        ppHost = defaults.string(forKey: "ppHost") ?? "127.0.0.1"
        ppPort = defaults.string(forKey: "ppPort") ?? ""
        leadSeconds = defaults.object(forKey: "leadSeconds") as? Double ?? 0.5
        notes = (defaults.data(forKey: "notes")).flatMap { try? JSONDecoder().decode(CueNotes.self, from: $0) } ?? CueNotes()
        countHeaders = defaults.object(forKey: "countHeaders") as? Bool ?? true
        #if DEBUG
        if let demo = ProcessInfo.processInfo.environment["PCR_DEMO"] { loadDemo(demo); return }
        #endif
        if DiskAccess.granted || defaults.bool(forKey: "skippedDiskAccess") {
            loadLibrary()
        } else {
            askForDiskAccess = true
        }
        Task { await keepConnected() }
    }

    /// ProPresenter may open after this app, or be slow to answer at launch: keep trying until it answers.
    private func keepConnected() async {
        while true {
            switch connection {
            case .unknown, .failed: if !ppPort.isEmpty && phase != .recording { await connect(quietly: true) }
            default: break
            }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Skipping is remembered: macOS's own prompt asks every launch after that, and Settings can turn it on.
    func finishDiskAccess(skipped: Bool) {
        if skipped { defaults.set(true, forKey: "skippedDiskAccess") }
        askForDiskAccess = false
        loadLibrary()
    }

    var plan: CuePlan? {
        guard let song, !clicks.isEmpty else { return nil }
        if song.hasSections {
            return CueEngine.plan(clicks: clicks, arrangement: song.arrangement, tempo: song.tempo,
                                  leadSeconds: leadSeconds)
        }
        guard let duration = song.duration else { return nil }
        return CueEngine.planByTime(clicks: clicks, duration: duration, firstSlideAt: firstSlideAt,
                                    leadSeconds: leadSeconds)
    }

    /// Where the first slide lands in the song, as the review screen shows it.
    var firstSlideTime: Double {
        get { firstSlideAt ?? CueEngine.deslip(clicks).first?.time ?? 0 }
        set { firstSlideAt = max(0, newValue) }
    }

    // MARK: Week overview

    func playlistStatus(_ song: SetlistSong) -> PlaylistStatus {
        if song.playlistCues.count > 1 { return .custom(song.playlistCues) }
        guard !skipPlaylistCue.contains(song.id), let n = itemNumbers[song.id] else { return .noItem }
        return song.playlistCues == [n] ? .correct(n) : .willSet(n)
    }

    func item(number: Int) -> PPPlaylistItem? {
        playlistItems.first { itemNumber($0) == number }
    }

    func itemNumber(_ item: PPPlaylistItem) -> Int {
        countHeaders ? item.number : playlistItems.filter { $0.type != "header" && $0.index <= item.index }.count
    }

    var playlistChanges: [SetlistSong] {
        songs.filter { if case .willSet = playlistStatus($0) { true } else { false } }
    }

    var changeCount: Int { playlistChanges.count + pendingLyrics.count + editedSongs.count }

    /// Songs with saved cues moved but not written yet (a new recording replaces them instead).
    var editedSongs: [String] {
        cueEdits.filter { !$0.value.isEmpty && pendingLyrics[$0.key] == nil }.map(\.key)
    }

    var nextSongNeedingLyrics: SetlistSong? {
        let order = songs.filter { $0.needsLyrics && pendingLyrics[$0.id] == nil }
        let current = songs.firstIndex { $0.id == versionId } ?? -1
        return order.first { s in (songs.firstIndex { $0.id == s.id } ?? 0) > current } ?? order.first
    }

    // MARK: Prime library

    func loadLibrary() {
        do {
            let db = try PrimeDB.locate()
            try db.checkSchema()
            self.db = db
            setlists = try db.setlists()
            if setlistId == nil || !setlists.contains(where: { $0.id == setlistId }) {
                setlistId = setlists.first?.id
            } else {
                loadSongs()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    fileprivate func loadSongs() {
        guard let db, let setlistId else { songs = []; return }
        do {
            let selected = versionId
            songs = try db.songs(setlistId: setlistId, notes: notes)
            rematch()
            versionId = songs.contains { $0.id == selected } ? selected
                : (songs.first { $0.needsLyrics } ?? songs.first)?.id
        } catch { self.error = error.localizedDescription }
    }

    private func loadSong() {
        savedSlides = nil
        guard let db, let versionId else { song = nil; savedCues = []; return }
        do {
            song = try db.song(versionId: versionId)
            savedCues = try db.cues(versionId: versionId, note: notes.lyric)
        } catch { self.error = error.localizedDescription }
        Task { await loadSlides() }
    }

    /// Reads the selected song's presentation from ProPresenter, through its playlist item, so
    /// saved cues (which only know their slide number) can show their words.
    func loadSlides() async {
        guard let client, let versionId, let n = itemNumbers[versionId],
              let item = item(number: n), let uuid = item.presentationId else { return }
        let presentation = try? await client.presentation(uuid: uuid, arrangement: item.arrangementId)
        if self.versionId == versionId, let presentation { savedSlides = presentation.slides }
    }

    // MARK: Moving saved lyric cues

    struct SavedRow: Identifiable {
        let id: String
        let slide: Int
        let group: String       // ProPresenter group, else Prime's section
        let text: String?       // nil when ProPresenter isn't connected
        let time: Double?       // where it fires now
        let nudge: Double
        let newTime: Double?    // where it will fire once saved

        var isInstrumental: Bool { CueGroup.isInstrumental(group: group, text: text ?? "-") }
    }

    var savedRows: [SavedRow] {
        guard let song else { return [] }
        let edits = cueEdits[song.versionId] ?? [:]
        let types = Dictionary(song.sections.map { ($0.id, $0.type) }, uniquingKeysWith: { a, _ in a })
        return savedCues.map { cue in
            let slide = savedSlides.flatMap { $0.indices.contains(cue.velocity - 1) ? $0[cue.velocity - 1] : nil }
            let nudge = edits[cue.id] ?? 0
            let time = CueShift.seconds(sectionId: cue.sectionId, progress: cue.progress, in: song)
            var newTime = time
            if nudge != 0 {
                let moved = CueShift.shift([cue], in: song, by: nudge).moves[cue.id]
                newTime = moved.flatMap { CueShift.seconds(sectionId: $0.sectionId, progress: $0.progress, in: song) } ?? time
            }
            return SavedRow(id: cue.id, slide: cue.velocity,
                            group: slide?.group ?? types[cue.sectionId].map(prettySection) ?? "",
                            text: slide?.text, time: time, nudge: nudge, newTime: newTime)
        }
        .sorted { ($0.time ?? 0, $0.slide) < ($1.time ?? 0, $1.slide) }
    }

    func nudgeSaved(_ cueIds: [String], by seconds: Double) {
        guard let versionId = song?.versionId else { return }
        var edits = cueEdits[versionId] ?? [:]
        for id in cueIds {
            let value = (((edits[id] ?? 0) + seconds) * 100).rounded() / 100
            edits[id] = value == 0 ? nil : value
        }
        cueEdits[versionId] = edits
    }

    func nudgeSaved(_ group: CueGroup, by seconds: Double) {
        nudgeSaved(savedRows.filter { group.contains(group: $0.group, text: $0.text ?? "-") }.map(\.id), by: seconds)
    }

    func resetSaved(_ cueId: String? = nil) {
        guard let versionId = song?.versionId else { return }
        if let cueId { cueEdits[versionId]?[cueId] = nil } else { cueEdits[versionId] = nil }
    }

    /// Recorded slides in `group`, moved together on the review screen.
    func nudge(_ group: CueGroup, by seconds: Double) {
        for i in clicks.indices where group.contains(group: clicks[i].group, text: clicks[i].text) {
            nudge(click: i, by: seconds)
        }
    }

    // MARK: ProPresenter

    private var client: ProPresenterClient? {
        Int(ppPort).flatMap { ProPresenterClient(host: ppHost, port: $0) }
    }

    /// `quietly` keeps the badge as it is while retrying in the background.
    func connect(quietly: Bool = false) async {
        guard let client else { connection = .failed("Enter ProPresenter's network port."); return }
        if !quietly || connection == .unknown { connection = .checking }
        do {
            connection = .connected(try await client.version())
            playlists = (try? await client.playlists()) ?? []
            let current = await client.currentPlaylistId()
            if let current, playlists.contains(where: { $0.id == current }) {
                playlistId = current
            } else if playlistId == nil {
                playlistId = playlists.first?.id
            }
            await loadPlaylistItems()
        } catch {
            connection = .failed("Can't reach ProPresenter at \(ppHost):\(ppPort). "
                                 + "Is Network turned on in ProPresenter's settings?")
        }
    }

    func loadPlaylistItems() async {
        guard let client, let playlistId else { return }
        do {
            playlistItems = try await client.playlistItems(id: playlistId)
            rematch()
        } catch {
            self.error = "Couldn't read that playlist from ProPresenter."
        }
    }

    private func rematch() {
        itemNumbers = WeekSetup.match(songs: songs, items: playlistItems).mapValues { itemNumber($0) }
        skipPlaylistCue = []
    }

    // MARK: Recording

    func startRecording() {
        guard let client else { connection = .failed("Enter ProPresenter's network port."); return }
        clicks = []
        firstSlideAt = nil
        presentationName = nil
        otherPresentationClicks = 0
        error = nil
        saveState = .idle
        phase = .recording
        recordingStartedAt = Date()
        let start = ContinuousClock.now
        recordTask = Task {
            var last: PPSlideIndex?
            var primed = false
            var presentations: [String: PPPresentation] = [:]
            var failures = 0
            var presentationId: String?
            while !Task.isCancelled {
                do {
                    let current = try await client.slideIndex()
                    let elapsed = start.duration(to: .now)
                    let time = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    failures = 0
                    // The slide already showing when Record was pressed isn't a click.
                    if primed, let current, current != last {
                        if presentations[current.uuid] == nil {
                            let arrangement = playlistItems.first { $0.presentationId == current.uuid }?.arrangementId
                            presentations[current.uuid] = try await client.presentation(
                                uuid: current.uuid, arrangement: arrangement)
                        }
                        if presentationId == nil {
                            presentationId = current.uuid
                            presentationName = current.name
                        }
                        if current.uuid == presentationId {
                            let slides = presentations[current.uuid]?.slides ?? []
                            let slide = slides.indices.contains(current.index) ? slides[current.index] : ("", "")
                            clicks.append(SlideClick(time: time, slide: current.index + 1,
                                                     group: slide.0, text: slide.1))
                        } else {
                            otherPresentationClicks += 1
                        }
                    }
                    last = current
                    primed = true
                } catch {
                    failures += 1
                    if failures > 30 {
                        self.error = "Lost the connection to ProPresenter. Recording stopped."
                        stopRecording()
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    func stopRecording() {
        recordTask?.cancel()
        recordTask = nil
        phase = clicks.isEmpty ? .ready : .review
    }

    /// Moves one recorded slide's cue later (> 0) or earlier, e.g. an Interlude clicked too soon.
    func nudge(click: Int, by seconds: Double) {
        guard clicks.indices.contains(click) else { return }
        clicks[click].nudge = ((clicks[click].nudge + seconds) * 100).rounded() / 100
    }

    func resetNudge(click: Int) {
        guard clicks.indices.contains(click) else { return }
        clicks[click].nudge = 0
    }

    func discard() {
        clicks = []
        phase = .ready
    }

    /// Keeps the reviewed cues for the next save and moves on to the next song without lyrics.
    func keep() {
        guard let song, let plan else { return }
        pendingLyrics[song.versionId] = plan
        clicks = []
        phase = .ready
        if let next = nextSongNeedingLyrics { versionId = next.id }
    }

    func forget(_ versionId: String) {
        pendingLyrics[versionId] = nil
    }

    private func updateBusy() {
        Updates.shared.busy = phase == .recording || saveState == .waitingForPrime
    }

    // MARK: Saving

    func save() {
        guard changeCount > 0 else { return }
        whenPrimeIsClosed { $0.write() }
    }

    /// Prime overwrites its database when it quits, so writes wait until it's closed.
    private func whenPrimeIsClosed(_ action: @escaping (AppModel) -> Void) {
        if PrimeDB.primeIsRunning {
            saveState = .waitingForPrime
            waitTask = Task {
                while PrimeDB.primeIsRunning && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if !Task.isCancelled { action(self) }
            }
        } else {
            action(self)
        }
    }

    // MARK: Shifting saved lyric cues

    struct ShiftPreview {
        var moves: [String: [String: (sectionId: String, progress: Double)]] = [:]
        var songs = 0
        var cues = 0
        var pinned = 0
        var skipped: [String] = []  // "Song name: reason"
    }

    /// What shifting this week's saved lyric cues by `seconds` (< 0 is earlier) would do, read fresh
    /// from Prime. Songs with a recording that isn't saved yet are left out: saving it replaces
    /// their cues anyway.
    func shiftPreview(seconds: Double) -> ShiftPreview {
        var preview = ShiftPreview()
        #if DEBUG
        if let demo = demoShiftPreview { return demo }
        #endif
        guard let db else { return preview }
        for entry in songs where entry.isMusic && entry.lyricCues > 0 {
            if pendingLyrics[entry.id] != nil {
                preview.skipped.append("\(entry.name): recorded but not saved yet")
                continue
            }
            do {
                let song = try db.song(versionId: entry.id)
                let result = CueShift.shift(try db.cues(versionId: entry.id, note: notes.lyric), in: song, by: seconds)
                if let reason = result.skipped {
                    preview.skipped.append("\(entry.name): \(reason)")
                    continue
                }
                guard !result.moves.isEmpty else { continue }
                preview.moves[entry.id] = result.moves
                preview.songs += 1
                preview.cues += result.moves.count
                preview.pinned += result.pinned
            } catch {
                preview.skipped.append("\(entry.name): \(error.localizedDescription)")
            }
        }
        return preview
    }

    /// Moves every saved lyric cue in this week's songs (or one song) by `seconds`; playlist
    /// item cues stay put. `adjustLead` also moves new recordings by the same amount.
    func shiftLyrics(seconds: Double, adjustLead: Bool) {
        whenPrimeIsClosed { model in
            guard let db = model.db else { model.saveState = .idle; return }
            let preview = model.shiftPreview(seconds: seconds)
            do {
                if !preview.moves.isEmpty { try db.move(preview.moves, lyricNote: model.notes.lyric) }
                if adjustLead { model.leadSeconds = min(max(model.leadSeconds - seconds, 0), 3) }
                model.loadSongs()
                let amount = String(format: "%g second%@ %@", abs(seconds), abs(seconds) == 1 ? "" : "s",
                                    seconds < 0 ? "earlier" : "later")
                model.saveState = .saved(preview.moves.isEmpty
                    ? "No lyric cues needed moving."
                    : "Moved \(preview.cues) lyric cue\(preview.cues == 1 ? "" : "s") in \(preview.songs) "
                      + "song\(preview.songs == 1 ? "" : "s") \(amount). Open Prime, check them, then save "
                      + "them to the cloud.")
            } catch {
                model.error = error.localizedDescription
                model.saveState = .idle
            }
        }
    }

    func cancelSave() {
        waitTask?.cancel()
        saveState = .idle
    }

    func quitPrime() {
        NSRunningApplication.runningApplications(withBundleIdentifier: PrimeDB.bundleID).forEach { $0.terminate() }
    }

    func openPrime() {
        saveState = .idle
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PrimeDB.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func write() {
        guard let db else { saveState = .idle; return }
        do {
            var writes: [CueWrite] = []
            for s in playlistChanges {
                guard case .willSet(let n) = playlistStatus(s) else { continue }
                let pos = WeekSetup.playlistCuePosition(arrangement: try db.song(versionId: s.id).arrangement)
                writes.append(CueWrite(versionId: s.id, note: notes.playlist, channel: notes.channel,
                                       cues: [(n, pos.sectionId, pos.progress)]))
            }
            for (id, plan) in pendingLyrics {
                writes.append(CueWrite(versionId: id, note: notes.lyric, channel: notes.channel,
                                       cues: plan.cues.sorted { $0.slide < $1.slide }
                                           .map { ($0.slide, $0.sectionId, $0.progress) }))
            }
            if !writes.isEmpty { try db.write(writes, lyricNote: notes.lyric) }
            var moves: [String: [String: (sectionId: String, progress: Double)]] = [:]
            for id in editedSongs {
                let song = try db.song(versionId: id)
                for cue in try db.cues(versionId: id, note: notes.lyric) {
                    guard let seconds = cueEdits[id]?[cue.id],
                          let moved = CueShift.shift([cue], in: song, by: seconds).moves[cue.id] else { continue }
                    moves[id, default: [:]][cue.id] = moved
                }
            }
            if !moves.isEmpty { try db.move(moves, lyricNote: notes.lyric) }
            let playlistCount = playlistChanges.count
            let lyricSongs = pendingLyrics.count
            let movedSongs = moves.count
            pendingLyrics = [:]
            cueEdits = [:]
            loadSongs()
            loadSong()
            var parts: [String] = []
            if playlistCount > 0 { parts.append("\(playlistCount) playlist cue\(playlistCount == 1 ? "" : "s")") }
            if lyricSongs > 0 { parts.append("lyrics for \(lyricSongs) song\(lyricSongs == 1 ? "" : "s")") }
            if movedSongs > 0 { parts.append("moved cues in \(movedSongs) song\(movedSongs == 1 ? "" : "s")") }
            saveState = .saved("Saved " + parts.joined(separator: " and ")
                               + ". Open Prime, check the songs, then save them to the cloud.")
        } catch {
            self.error = error.localizedDescription
            saveState = .idle
        }
    }
}

/// "verse_1" -> "Verse 1"
func prettySection(_ type: String) -> String {
    type.replacingOccurrences(of: "_", with: " ").capitalized
}
