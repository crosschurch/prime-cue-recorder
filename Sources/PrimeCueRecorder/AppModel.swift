import AppKit
import CueCore
import Observation

@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case ready, recording, review, waitingForPrime, done(String) }
    enum Connection: Equatable { case unknown, checking, connected(String), failed(String) }

    var phase = Phase.ready
    var connection = Connection.unknown
    var error: String?

    var ppHost: String { didSet { UserDefaults.standard.set(ppHost, forKey: "ppHost") } }
    var ppPort: String { didSet { UserDefaults.standard.set(ppPort, forKey: "ppPort") } }
    var lead: Double { didSet { UserDefaults.standard.set(lead, forKey: "lead") } }

    var setlists: [Setlist] = []
    var songs: [SetlistSong] = []
    var setlistId: String? { didSet { if setlistId != oldValue { loadSongs() } } }
    var versionId: String? { didSet { if versionId != oldValue { loadSong() } } }
    var song: PrimeSong?

    var clicks: [SlideClick] = []
    var presentationName: String?
    private(set) var otherPresentationClicks = 0
    var recordingStartedAt: Date?

    private var db: PrimeDB?
    private var recordTask: Task<Void, Never>?
    private var waitTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        ppHost = defaults.string(forKey: "ppHost") ?? "127.0.0.1"
        ppPort = defaults.string(forKey: "ppPort") ?? ""
        lead = defaults.object(forKey: "lead") as? Double ?? 2
        #if DEBUG
        if let demo = ProcessInfo.processInfo.environment["PCR_DEMO"] { loadDemo(demo); return }
        #endif
        loadLibrary()
        if !ppPort.isEmpty { Task { await checkConnection() } }
    }

    var plan: CuePlan? {
        guard let song, !clicks.isEmpty else { return nil }
        return CueEngine.plan(clicks: clicks, arrangement: song.arrangement, tempo: song.tempo, lead: lead)
    }

    // MARK: Prime library

    func loadLibrary() {
        do {
            let db = try PrimeDB.locate()
            try db.checkSchema()
            self.db = db
            setlists = try db.setlists()
            setlistId = setlists.first?.id
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadSongs() {
        guard let db, let setlistId else { songs = []; return }
        do {
            songs = try db.songs(setlistId: setlistId)
            versionId = (songs.first(where: \.isActive) ?? songs.first)?.id
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

    func checkConnection() async {
        guard let client else { connection = .failed("Enter ProPresenter's network port."); return }
        connection = .checking
        do { connection = .connected(try await client.version()) } catch {
            connection = .failed("Can't reach ProPresenter at \(ppHost):\(ppPort). "
                                 + "Is Network turned on in ProPresenter's settings?")
        }
    }

    // MARK: Recording

    func startRecording() {
        guard let client else { connection = .failed("Enter ProPresenter's network port."); return }
        clicks = []
        presentationName = nil
        otherPresentationClicks = 0
        error = nil
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

    // MARK: Saving

    func save() {
        if PrimeDB.primeIsRunning {
            phase = .waitingForPrime
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
        phase = .review
    }

    func quitPrime() {
        NSRunningApplication.runningApplications(withBundleIdentifier: PrimeDB.bundleID).forEach { $0.terminate() }
    }

    func openPrime() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PrimeDB.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func write() {
        guard let db, let song, let plan else { phase = .review; return }
        do {
            try db.writeLyricCues(versionId: song.versionId, cues: plan.cues)
            phase = .done("Saved \(plan.cues.count) cues to “\(song.name)”. Open Prime, play it through to check, "
                          + "then save the song to the cloud.")
            clicks = []
            let selected = versionId
            loadSongs()
            versionId = selected
        } catch {
            self.error = error.localizedDescription
            phase = .review
        }
    }
}
