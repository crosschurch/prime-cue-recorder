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
    var itemNumbers: [String: Int] = [:]
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
        loadLibrary()
        if !ppPort.isEmpty { Task { await connect() } }
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

    var changeCount: Int { playlistChanges.count + pendingLyrics.count }

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

    private func loadSongs() {
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
        guard let db, let versionId else { song = nil; return }
        do { song = try db.song(versionId: versionId) } catch { self.error = error.localizedDescription }
    }

    // MARK: ProPresenter

    private var client: ProPresenterClient? {
        Int(ppPort).flatMap { ProPresenterClient(host: ppHost, port: $0) }
    }

    func connect() async {
        guard let client else { connection = .failed("Enter ProPresenter's network port."); return }
        connection = .checking
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
                            presentations[current.uuid] = try await client.presentation(uuid: current.uuid)
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
        if PrimeDB.primeIsRunning {
            saveState = .waitingForPrime
            waitTask = Task {
                while PrimeDB.primeIsRunning && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                }
                if !Task.isCancelled { write() }
            }
        } else {
            write()
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
            try db.write(writes, lyricNote: notes.lyric)
            let playlistCount = playlistChanges.count
            let lyricSongs = pendingLyrics.count
            pendingLyrics = [:]
            loadSongs()
            var parts: [String] = []
            if playlistCount > 0 { parts.append("\(playlistCount) playlist cue\(playlistCount == 1 ? "" : "s")") }
            if lyricSongs > 0 { parts.append("lyrics for \(lyricSongs) song\(lyricSongs == 1 ? "" : "s")") }
            saveState = .saved("Saved " + parts.joined(separator: " and ")
                               + ". Open Prime, check the songs, then save them to the cloud.")
        } catch {
            self.error = error.localizedDescription
            saveState = .idle
        }
    }
}
