import CueCore
import SwiftUI

@main
struct PrimeCueRecorderApp: App {
    @State private var model = AppModel()

    init() {
        _ = Updates.shared
    }

    var body: some Scene {
        Window("Prime Cue Recorder", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands { UpdateCommands() }

        Settings {
            SettingsView(model: model)
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSetup = false

    var body: some View {
        NavigationSplitView {
            WeekSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
        } detail: {
            SongDetail(model: model)
                .safeAreaInset(edge: .top) {
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassCard(tint: .red, shape: Capsule())
                            .padding(.top, 8)
                            .onTapGesture { model.error = nil }
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
        }
        .frame(minWidth: 1120, minHeight: 640)
        // An empty title rather than none: removing the title packs every toolbar item to the
        // left, while an empty one keeps the actions at the right edge.
        .navigationTitle("")
        .toolbar { toolbar }
        .sheet(isPresented: $showSetup) {
            SettingsView(model: model, isFirstRun: true)
        }
        .sheet(isPresented: $model.showShift) {
            ShiftSheet(model: model)
        }
        .sheet(isPresented: $model.askForDiskAccess, onDismiss: askForSetup) {
            DiskAccessSheet(model: model)
                .interactiveDismissDisabled()
        }
        .onAppear { if !model.askForDiskAccess { askForSetup() } }
        .animation(.smooth, value: model.phase)
        .animation(.smooth, value: model.error)
        .animation(.smooth, value: model.saveState)
        // A new change after saving puts the Save button back without clicking Done.
        .onChange(of: model.changeCount) { _, count in
            if count > 0, case .saved = model.saveState { model.saveState = .idle }
        }
    }

    private func askForSetup() {
        if model.ppPort.isEmpty && model.connection == .unknown { showSetup = true }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ConnectionBadge(connection: model.connection)
        }
        // Setlist and playlist on the left, actions on the right edge however wide the window is.
        ToolbarItemGroup(placement: .navigation) {
            Picker("Prime Setlist", selection: $model.setlistId) {
                ForEach(model.setlists) { list in
                    Text("\(list.name) — \(list.serviceDate)").tag(Optional(list.id))
                }
            }
            .frame(maxWidth: 280)
            .help("Prime setlist")
            Picker("ProPresenter Playlist", selection: $model.playlistId) {
                if model.playlists.isEmpty { Text("No ProPresenter Playlist").tag(String?.none) }
                ForEach(model.playlists) { Text($0.name).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 220)
            .help("ProPresenter playlist")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Shift Lyric Cues", systemImage: "arrow.left.arrow.right") { model.showShift = true }
                .help("Move every saved lyric cue earlier or later")
                .disabled(model.phase == .recording || model.saveState == .waitingForPrime || model.songs.isEmpty)
            Button("Reload", systemImage: "arrow.clockwise") {
                model.loadLibrary()
                Task { await model.connect() }
            }
            .help("Reload from Prime and ProPresenter")
        }
        ToolbarItem(placement: .primaryAction) {
            UpdateBadge()
        }
        ToolbarItem(placement: .primaryAction) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("Settings")
        }
    }
}

// MARK: Sidebar

private struct WeekSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.versionId) {
            Section("This Week") {
                ForEach(model.songs) { song in
                    SongRow(model: model, song: song).tag(Optional(song.id))
                }
            }
        }
        .disabled(model.phase == .recording)
        .safeAreaInset(edge: .bottom) {
            SaveCard(model: model).padding(12)
        }
    }
}

private struct SongRow: View {
    let model: AppModel
    let song: SetlistSong
    /// Selected rows sit on the accent color, so colored text and icons switch to plain.
    private var plain: Bool { model.versionId == song.id }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(song.name).lineLimit(1)
                HStack(spacing: 6) {
                    playlistLabel
                    Text("·")
                    lyricsLabel
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            statusIcon
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var playlistLabel: some View {
        switch model.playlistStatus(song) {
        case .noItem: Text(song.playlistCues.first.map { "Item \($0)" } ?? "No item")
        case .correct(let n): Text("Item \(n)")
        case .willSet(let n): Text("Item \(n)").foregroundStyle(plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        case .custom(let ns): Text("Items " + ns.map(String.init).joined(separator: ", "))
        }
    }

    @ViewBuilder private var lyricsLabel: some View {
        if let plan = model.pendingLyrics[song.id] {
            Text("\(plan.cues.count) recorded").foregroundStyle(plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
        } else if !song.isMusic {
            Text("No music")
        } else if song.lyricCues == 0 {
            Text("Needs lyrics").foregroundStyle(plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
        } else {
            Text("\(song.lyricCues) lyric cues")
        }
    }

    @ViewBuilder private var statusIcon: some View {
        let unsaved = model.pendingLyrics[song.id] != nil
            || { if case .willSet = model.playlistStatus(song) { true } else { false } }()
        if unsaved {
            Image(systemName: "circle.fill").font(.system(size: 7))
                .foregroundStyle(plain ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
                .help("Changes waiting to be saved")
        } else if song.needsLyrics {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(plain ? AnyShapeStyle(.primary) : AnyShapeStyle(.orange))
                .help("No lyric cues yet")
        } else {
            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        }
    }
}

private struct SaveCard: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.saveState {
            case .waitingForPrime:
                Text("Quit Prime to save").font(.headline)
                Text("Prime has to be closed while saving, or it will overwrite the cues.")
                    .font(.callout).foregroundStyle(.secondary)
                GlassGroup {
                    HStack {
                        Button("Cancel") { model.cancelSave() }.glassButton()
                        Spacer()
                        Button("Quit Prime") { model.quitPrime() }.glassProminentButton()
                    }
                }
            case .saved(let message):
                Label("Saved", systemImage: "checkmark.circle.fill").font(.headline)
                    .foregroundStyle(.green)
                Text(message).font(.callout).foregroundStyle(.secondary)
                GlassGroup {
                    HStack {
                        Button("Done") { model.saveState = .idle }.glassButton()
                        Spacer()
                        Button("Open Prime") { model.openPrime() }.glassProminentButton()
                    }
                }
            case .idle:
                Text(summary).font(.callout).foregroundStyle(.secondary)
                Button {
                    model.save()
                } label: {
                    Text(model.changeCount == 0 ? "Nothing to Save" : "Save \(model.changeCount) to Prime")
                        .frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .controlSize(.large)
                .disabled(model.changeCount == 0 || model.phase == .recording)
            }
        }
        .padding(14)
        .glassCard(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var summary: String {
        let playlist = model.playlistChanges.count
        let lyrics = model.pendingLyrics.count
        let moved = model.editedSongs.count
        let missing = model.songs.filter { $0.needsLyrics && model.pendingLyrics[$0.id] == nil }.count
        var parts: [String] = []
        if playlist > 0 { parts.append("\(playlist) playlist cue\(playlist == 1 ? "" : "s") to set") }
        if lyrics > 0 { parts.append("\(lyrics) song\(lyrics == 1 ? "" : "s") recorded") }
        if moved > 0 { parts.append("cues moved in \(moved) song\(moved == 1 ? "" : "s")") }
        if missing > 0 { parts.append("\(missing) still need\(missing == 1 ? "s" : "") lyrics") }
        return parts.isEmpty ? "Everything this week has cues." : parts.joined(separator: " · ")
    }
}

// MARK: Song detail

private struct SongDetail: View {
    @Bindable var model: AppModel

    var body: some View {
        if let song = model.song, let entry = model.songs.first(where: { $0.id == song.versionId }) {
            switch model.phase {
            case .ready: ReadyView(model: model, song: song, entry: entry)
            case .recording: RecordingView(model: model)
            case .review: ReviewView(model: model)
            }
        } else {
            ContentUnavailableView("Choose a Song", systemImage: "music.note.list",
                                   description: Text("Pick a song from this week's setlist."))
        }
    }
}

private struct ReadyView: View {
    @Bindable var model: AppModel
    let song: PrimeSong
    let entry: SetlistSong

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Text(song.name).font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
                    Text(subtitle).foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                PlaylistCueCard(model: model, entry: entry)
                LyricsCard(model: model, song: song, entry: entry)
                if entry.isMusic && !model.savedCues.isEmpty && model.pendingLyrics[entry.id] == nil {
                    SavedCuesCard(model: model)
                }
            }
            .padding(28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: String {
        guard entry.isMusic else { return "No music" }
        let tempo = "\(Int(song.tempo.rounded())) BPM"
        if song.hasSections { return tempo + "  ·  \(song.arrangement.count) sections" }
        return tempo + "  ·  No sections" + (song.duration.map { "  ·  " + clock($0, tenths: false) } ?? "")
    }
}

private struct PlaylistCueCard: View {
    @Bindable var model: AppModel
    let entry: SetlistSong

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Playlist Item", systemImage: "list.number").font(.headline)
                Spacer()
                status
            }
            Text("Note \(model.notes.playlist) selects this song's item in the ProPresenter playlist, one beat into the song.")
                .font(.callout).foregroundStyle(.secondary)
            if case .custom(let numbers) = model.playlistStatus(entry) {
                Text("This song has \(numbers.count) playlist cues (items \(numbers.map(String.init).joined(separator: ", "))), "
                     + "like a medley. They're left as they are.")
                    .font(.callout)
            } else {
                Picker("ProPresenter item", selection: binding) {
                    Text("None").tag(Int?.none)
                    ForEach(model.playlistItems.filter { $0.type != "header" }) { item in
                        Text("\(model.itemNumber(item)). \(item.name)").tag(Optional(model.itemNumber(item)))
                    }
                }
                .disabled(model.playlistItems.isEmpty)
                if model.playlistItems.isEmpty {
                    Text("Connect to ProPresenter to match this song to the playlist.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .glassCard(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var binding: Binding<Int?> {
        Binding {
            model.skipPlaylistCue.contains(entry.id) ? nil : model.itemNumbers[entry.id]
        } set: { n in
            if let n {
                model.itemNumbers[entry.id] = n
                model.skipPlaylistCue.remove(entry.id)
            } else {
                model.skipPlaylistCue.insert(entry.id)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.playlistStatus(entry) {
        case .correct(let n): Label("Item \(n) set", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .willSet(let n):
            Label(entry.playlistCues.isEmpty ? "Will set item \(n)" : "Will change to item \(n)",
                  systemImage: "circle.fill").foregroundStyle(.tint)
        case .custom: Label("Custom", systemImage: "slider.horizontal.3").foregroundStyle(.secondary)
        case .noItem:
            if let n = entry.playlistCues.first {
                Label("Item \(n) set", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Label("Not set", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
        }
    }
}

private struct LyricsCard: View {
    @Bindable var model: AppModel
    let song: PrimeSong
    let entry: SetlistSong

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Lyric Slides", systemImage: "text.quote").font(.headline)
                Spacer()
                if let plan = model.pendingLyrics[entry.id] {
                    Label("\(plan.cues.count) recorded", systemImage: "circle.fill").foregroundStyle(.tint)
                } else if entry.lyricCues > 0 {
                    Label("\(entry.lyricCues) cues", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("None yet", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                }
            }
            if !entry.isMusic {
                Text("This item has no music, so it doesn't need lyric cues.")
                    .foregroundStyle(.secondary)
            } else if !song.hasSections && song.duration == nil {
                Text("This song has no sections in Prime and its audio isn't downloaded, so the app can't "
                     + "tell how long it is. Play it once in Prime to download it, then choose it again.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(caption).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.lyricCues == 0 || model.pendingLyrics[entry.id] != nil { Steps() }
                HStack {
                    if model.pendingLyrics[entry.id] != nil {
                        Button("Discard Recording", role: .destructive) { model.forget(entry.id) }
                            .glassButton()
                    }
                    Spacer()
                    RecordButton(isRecording: false) { model.startRecording() }
                }
            }
        }
        .padding(18)
        .glassCard(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var caption: String {
        if model.pendingLyrics[entry.id] != nil {
            return "Recorded and waiting to be saved. Record again to replace it."
        }
        if entry.lyricCues > 0 {
            return "This song already has lyric cues. Move them below, or record again to replace them when you save."
        }
        let lead = String(format: "Cues fire %g seconds before your clicks to cover MIDI delay.", model.leadSeconds)
        if !song.hasSections {
            return "Press Record and Play in Prime at the same moment, then click through the slides in "
                + "ProPresenter. This song has no sections in Prime, so afterwards you'll check where the "
                + "first slide lands in the song. " + lead
        }
        return "Play the song in Prime from the top and click through the slides in ProPresenter. " + lead
    }
}

private struct Steps: View {
    let steps = [
        ("record.circle", "Press Record"),
        ("play.fill", "Play the song in Prime"),
        ("cursorarrow.click.2", "Click the slides in ProPresenter"),
        ("checkmark.circle", "Stop and keep"),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                VStack(spacing: 6) {
                    Image(systemName: step.0).font(.title3).foregroundStyle(.tint)
                    Text("\(i + 1). \(step.1)")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: Recording

private struct RecordingView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 10, height: 10)
                            .phaseAnimator([1.0, 0.3]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.8) }
                        Text("Recording \(model.song?.name ?? "")").font(.headline)
                        if let start = model.recordingStartedAt {
                            Text(start, style: .timer).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Text(model.presentationName.map { "Following “\($0)” in ProPresenter" }
                         ?? "Play the song in Prime and click the first slide")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RecordButton(isRecording: true) { model.stopRecording() }
            }
            .padding(18)
            .glassCard(shape: RoundedRectangle(cornerRadius: 24, style: .continuous))

            if model.otherPresentationClicks > 0 {
                Label("Ignored \(model.otherPresentationClicks) click(s) in another presentation",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            if model.clicks.isEmpty {
                ContentUnavailableView("Waiting for the First Slide", systemImage: "cursorarrow.click.2",
                                       description: Text("Slides you click in ProPresenter show up here."))
            } else {
                // Like a chat: the newest slide comes in at the bottom and the list follows it, all
                // of it, down to a marker under the last row.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.clicks.enumerated()), id: \.offset) { i, click in
                                SlideRow(slide: click.slide, group: click.group, text: click.text,
                                         trailing: String(format: "%.1fs", click.time))
                                    .padding(.horizontal, 8)
                                    .opacity(i == model.clicks.count - 1 ? 1 : 0.75)
                                if i < model.clicks.count - 1 { Divider().padding(.leading, 48) }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(10)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: model.clicks.count) {
                        Task { @MainActor in
                            withAnimation(.snappy) { proxy.scrollTo("end", anchor: .bottom) }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .glassCard(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .padding(24)
    }
}

// MARK: Review

private struct ReviewView: View {
    @Bindable var model: AppModel
    @State private var selected: String?

    /// Kept cues, plus clicks removed or left out as taken back, so they can be put back.
    private func rows(_ plan: CuePlan) -> [CueListRow] {
        let cues = Dictionary(plan.cues.map { ($0.click, $0) }, uniquingKeysWith: { a, _ in a })
        let takenBack = Set(CueEngine.cleaned(model.clicks).takenBack)
        return model.clicks.indices.compactMap { i in
            let click = model.clicks[i]
            if let cue = cues[i] {
                return CueListRow(id: "\(i)", slide: cue.slide, group: pretty(cue.sectionType), text: cue.text,
                                  trailing: cue.time.map { clock($0) } ?? String(format: "beat %.2f", cue.beat),
                                  nudge: click.nudge, status: click.edited ? "Edited" : nil)
            }
            guard click.removed || takenBack.contains(i) else { return nil }
            return CueListRow(id: "\(i)", slide: click.slide, group: click.group, text: click.text, trailing: "",
                              status: click.removed ? "Removed" : "Clicked early, taken back", isOut: true)
        }
    }

    private var actions: CueActions {
        CueActions(
            nudge: { id, s in Int(id).map { model.nudge(click: $0, by: s) } },
            resetNudge: { id in Int(id).map { model.resetNudge(click: $0) } },
            setSlide: { id, n in Int(id).map { model.setSlide(click: $0, to: n) } },
            add: { id in Int(id).flatMap { model.addClick(after: $0) }.map { "\($0)" } },
            toggleRemove: { id in Int(id).map { model.toggleRemove(click: $0) } })
    }

    var body: some View {
        if let plan = model.plan {
            VStack(spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(plan.cues.count) cues ready").font(.title2.weight(.semibold))
                        if let err = plan.fitError {
                            Text(String(format: "Lined up with %d section changes, within ±%.1f beats",
                                        plan.anchors, err))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Stepper(value: $model.leadSeconds, in: 0...2, step: 0.1) {
                        Text(String(format: "Fire %.1fs early", model.leadSeconds)).monospacedDigit()
                    }
                    .help("Covers the delay between Prime sending MIDI and ProPresenter changing slides.")
                }

                if model.song?.hasSections == false {
                    FirstSlideCard(model: model)
                }

                ForEach(plan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassCard(tint: .orange, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                // The clicks this plan was made from: Keep empties model.clicks before this bar's last redraw.
                let clicks = model.clicks
                BulkMoveBar(count: { group in
                                plan.cues.filter {
                                    clicks.indices.contains($0.click)
                                        && group.contains(group: clicks[$0.click].group, text: $0.text)
                                }.count
                            },
                            apply: { model.nudge($0, by: $1) })

                CueList(rows: rows(plan), selected: $selected, slideCount: model.recordedSlides?.count,
                        actions: actions, scrolls: true)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .glassCard(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))

                Text("Click a slide to change it: ← → move it a quarter second, ↑ ↓ pick another, Delete removes it.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .safeAreaInset(edge: .bottom) {
                GlassGroup {
                    HStack {
                        Button("Record Again", systemImage: "arrow.counterclockwise", role: .destructive) {
                            model.discard()
                        }
                        .glassButton()
                        Spacer()
                        Button(model.nextSongNeedingLyrics == nil ? "Keep" : "Keep and Go to Next Song",
                               systemImage: "checkmark") { model.keep() }
                            .glassProminentButton()
                            .keyboardShortcut(.defaultAction)
                            .disabled(plan.cues.isEmpty)
                    }
                    .controlSize(.large)
                }
                .padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
    }
}

/// Songs without sections are timed by the clock, so they need one fixed point: where the first
/// slide lands in the song. Prime's timeline shows it.
private struct FirstSlideCard: View {
    @Bindable var model: AppModel
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "timer").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Where does the first slide land?").font(.headline)
                Text("This song has no sections in Prime. Find the first line in Prime's timeline and set its "
                     + "time here; the rest follow your clicks.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            TextField("0:00.0", text: $text)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .focused($editing)
                .onSubmit(commit)
                .onChange(of: editing) { if !editing { commit() } }
            Stepper("First slide", value: $model.firstSlideTime, in: 0...3600, step: 0.1)
                .labelsHidden()
        }
        .padding(16)
        .glassCard(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { text = clock(model.firstSlideTime) }
        .onChange(of: model.firstSlideTime) { if !editing { text = clock(model.firstSlideTime) } }
    }

    private func commit() {
        if let seconds = parseClock(text) { model.firstSlideTime = seconds }
        text = clock(model.firstSlideTime)
    }
}

// MARK: Saved cues

/// A song's lyric cues already in Prime, where they fire, and moving them: one at a time, or a
/// group at once (lyrics a bit earlier, Interludes and blanks a bit later).
private struct SavedCuesCard: View {
    @Bindable var model: AppModel
    @State private var selected: String?

    var body: some View {
        let rows = model.savedRows
        let changed = rows.filter { !$0.edit.isEmpty }.count
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Saved Cues", systemImage: "slider.horizontal.below.rectangle").font(.headline)
                Spacer()
                if changed > 0 {
                    Text("\(changed) changed, not saved yet").foregroundStyle(.orange)
                    Button("Reset") { model.resetSaved() }.glassButton()
                }
            }
            Text(caption).font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            BulkMoveBar(count: { group in
                            rows.filter { !$0.edit.removed && group.contains(group: $0.group, text: $0.text ?? "-") }.count
                        },
                        apply: { model.nudgeSaved($0, by: $1) },
                        canPickGroup: model.savedSlides != nil)
            CueList(rows: rows.map(listRow), selected: $selected, slideCount: model.savedSlides?.count,
                    actions: CueActions(
                        nudge: { model.nudgeSaved([$0], by: $1) },
                        resetNudge: { model.resetSaved($0) },
                        setSlide: { model.setSavedSlide($0, to: $1) },
                        add: { model.addSaved(after: $0) },
                        toggleRemove: { model.toggleRemoveSaved($0) }))
            if changed > 0 {
                HStack {
                    Spacer()
                    Button("Save to Prime", systemImage: "square.and.arrow.down") { model.save() }
                        .glassProminentButton()
                        .disabled(model.saveState == .waitingForPrime)
                }
            }
        }
        .padding(18)
        .glassCard(shape: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onChange(of: model.versionId) { selected = nil }
    }

    private func listRow(_ row: AppModel.SavedRow) -> CueListRow {
        let edit = row.edit
        let status = edit.added != nil ? "New" : edit.removed ? "Removed" : edit.slide != nil ? "Renumbered" : nil
        return CueListRow(id: row.id, slide: row.slide, group: row.group, text: row.text ?? "Slide \(row.slide)",
                          trailing: row.newTime.map { clock($0) } ?? "", nudge: edit.nudge,
                          status: status, isOut: edit.removed)
    }

    private var caption: String {
        let base = "Where each slide fires in the song. Click a slide to move, renumber or remove it, or add "
            + "the next slide after it. Move a group at once below. Changes are written when you save."
        return model.savedSlides == nil
            ? base + " Connect to ProPresenter and pick this song's playlist item to see each slide's words."
            : base
    }
}

/// Moves a group of slides earlier or later in one go.
private struct BulkMoveBar: View {
    let count: (CueGroup) -> Int
    let apply: (CueGroup, Double) -> Void
    var canPickGroup = true
    @State private var group = CueGroup.lyrics
    @State private var amount = 0.5

    var body: some View {
        let target = canPickGroup ? group : .all
        HStack(spacing: 12) {
            Picker("Move", selection: canPickGroup ? $group : .constant(.all)) {
                ForEach(CueGroup.allCases) { Text("\($0.title) (\(count($0)))").tag($0) }
            }
            .frame(maxWidth: 330)
            .disabled(!canPickGroup)
            .help(canPickGroup ? "" : "Needs the slides' words from ProPresenter")
            Stepper(value: $amount, in: 0.1...5, step: 0.1) {
                Text(amount.formatted(.number.precision(.fractionLength(1))) + " s").monospacedDigit()
            }
            Spacer(minLength: 0)
            Button("Earlier", systemImage: "chevron.backward") { apply(target, -amount) }
                .glassButton()
            Button("Later", systemImage: "chevron.forward") { apply(target, amount) }
                .glassButton()
        }
    }
}

// MARK: Pieces

private struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(isRecording ? "Stop" : "Record", systemImage: isRecording ? "stop.fill" : "record.circle")
                .font(.body.weight(.semibold))
                .padding(.horizontal, 6)
        }
        .glassProminentButton()
        .tint(.red)
        .controlSize(.extraLarge)
        .keyboardShortcut(isRecording ? .escape : .space, modifiers: [])
    }
}

/// A slide in the list while recording.
private struct SlideRow: View {
    let slide: Int
    let group: String
    let text: String
    let trailing: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(slide)")
                .font(.callout.weight(.semibold)).monospacedDigit()
                .frame(minWidth: 28)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.18), in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(firstLine(text)).foregroundStyle(text.isEmpty ? .secondary : .primary).lineLimit(1)
                if !group.isEmpty {
                    Text(group).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(trailing).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct ConnectionBadge: View {
    let connection: AppModel.Connection

    var body: some View {
        let (color, text, help): (Color, String, String) = switch connection {
        case .connected(let name): (.green, "ProPresenter", "Connected to \(name)")
        case .checking: (.yellow, "Connecting…", "Connecting to ProPresenter")
        case .failed(let message): (.orange, "ProPresenter", message)
        case .unknown: (.secondary, "ProPresenter", "ProPresenter isn't set up yet")
        }
        Label {
            Text(text)
        } icon: {
            Circle().fill(color).frame(width: 8, height: 8)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 10)
        .help(help)
    }
}

/// Moves every saved lyric cue earlier or later at once, e.g. when slides keep changing a
/// little late. Playlist item cues stay where they are.
private struct ShiftSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var amount = 0.5
    @State private var earlier = true
    @State private var adjustLead = true
    @State private var preview = AppModel.ShiftPreview()

    private var seconds: Double { earlier ? -amount : amount }
    private var direction: String { earlier ? "earlier" : "later" }
    private var setlistName: String { model.setlists.first { $0.id == model.setlistId }?.name ?? "this setlist" }
    private var newLead: Double { min(max(model.leadSeconds - seconds, 0), 3) }

    var body: some View {
        Form {
            Section {
                Picker("Move cues", selection: $earlier) {
                    Text("Earlier").tag(true)
                    Text("Later").tag(false)
                }
                .pickerStyle(.segmented)
                Stepper(value: $amount, in: 0.1...5, step: 0.1) {
                    LabeledContent("By", value: String(format: "%.1f seconds", amount)).monospacedDigit()
                }
            } header: {
                Text("Shift Lyric Cues")
            } footer: {
                Text("Moves the lyric slide cues (note \(model.notes.lyric)) already saved in Prime. "
                     + "Playlist item cues (note \(model.notes.playlist)) stay where they are.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Songs", value: "Every song in “\(setlistName)”")
                Toggle(String(format: "Also fire new recordings %.1fs %@ (%.1fs → %.1fs early)",
                              amount, direction, model.leadSeconds, newLead), isOn: $adjustLead)
            } footer: {
                Text("To move one song's cues, or only its lyrics or Interludes, choose the song and use its "
                     + "Saved Cues.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Label(summary, systemImage: preview.cues > 0 ? "arrow.left.arrow.right.circle.fill" : "info.circle")
                    .foregroundStyle(preview.cues > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                if preview.pinned > 0 {
                    Label("\(preview.pinned) cue\(preview.pinned == 1 ? " is" : "s are") at the edge of a section that "
                          + "plays more than once, so \(preview.pinned == 1 ? "it stops" : "they stop") at that edge.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                ForEach(preview.skipped, id: \.self) { line in
                    Label("Skipped \(line)", systemImage: "minus.circle").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Prime is backed up first, and shifting back the other way undoes it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(PrimeDB.primeIsRunning ? "Quit Prime and Shift" : "Shift Cues") {
                    model.shiftLyrics(seconds: seconds, adjustLead: adjustLead)
                    if PrimeDB.primeIsRunning { model.quitPrime() }
                    dismiss()
                }
                .disabled(preview.cues == 0 && !adjustLead)
            }
        }
        .task(id: seconds) {
            preview = model.shiftPreview(seconds: seconds)
        }
    }

    private var summary: String {
        guard preview.cues > 0 else { return "No saved lyric cues to move." }
        return String(format: "Moves %d lyric cue%@ in %d song%@ %.1f seconds %@.", preview.cues,
                      preview.cues == 1 ? "" : "s", preview.songs, preview.songs == 1 ? "" : "s", amount, direction)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel
    var isFirstRun = false
    @Environment(\.dismiss) private var dismiss
    @State private var diskAccess = DiskAccess.granted

    var body: some View {
        Form {
            Section {
                TextField("Computer", text: $model.ppHost, prompt: Text("127.0.0.1"))
                TextField("Port", text: $model.ppPort, prompt: Text("e.g. 50001"))
                LabeledContent("Status") { ConnectionBadge(connection: model.connection) }
            } header: {
                Text("ProPresenter")
            } footer: {
                Text("In ProPresenter, open Settings › Network, turn on Enable Network, and copy the port here. "
                     + "Use 127.0.0.1 when ProPresenter runs on this Mac.")
                    .foregroundStyle(.secondary)
            }
            if !isFirstRun {
                Section {
                    LabeledContent("Full Disk Access") {
                        if diskAccess {
                            Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Turn On…") { DiskAccess.openSettings() }
                        }
                    }
                } header: {
                    Text("Prime Library")
                } footer: {
                    Text("Prime keeps its library in its own private folder. Without Full Disk Access, macOS asks "
                         + "you to Allow opening it every time this app starts.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Stepper(value: $model.leadSeconds, in: 0...2, step: 0.1) {
                        LabeledContent("Fire cues early by", value: String(format: "%.1f seconds", model.leadSeconds))
                    }
                } header: {
                    Text("Timing")
                } footer: {
                    Text("Every recorded cue fires this much before your click, to cover the delay between Prime "
                         + "sending MIDI and ProPresenter changing slides.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    noteStepper("Lyric slide note", value: $model.notes.lyric)
                    noteStepper("Playlist item note", value: $model.notes.playlist)
                    Stepper(value: Binding { model.notes.channel + 1 } set: { model.notes.channel = $0 - 1 },
                            in: 1...16) {
                        LabeledContent("Channel", value: "\(model.notes.channel + 1)")
                    }
                    Toggle("Count playlist headers when numbering items", isOn: $model.countHeaders)
                    Button("Restore Defaults") { model.notes = CueNotes() }
                } header: {
                    Text("MIDI")
                } footer: {
                    Text("These must match ProPresenter's MIDI settings. The velocity is the slide number "
                         + "or the playlist item number.")
                        .foregroundStyle(.secondary)
                }
                UpdatesSection()
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            if isFirstRun {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            diskAccess = DiskAccess.granted
        }
        .task(id: model.ppHost + ":" + model.ppPort) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { await model.connect() }
        }
    }

    private func noteStepper(_ title: String, value: Binding<Int>) -> some View {
        Stepper(value: value, in: 0...127) {
            LabeledContent(title, value: "\(value.wrappedValue)")
        }
    }
}

// MARK: Liquid Glass with a fallback for macOS 14–15


struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

extension View {
    @ViewBuilder
    func glassCard(tint: Color? = nil, shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint?.opacity(0.35)), in: shape)
        } else {
            background(tint.map { AnyShapeStyle($0.opacity(0.25)) } ?? AnyShapeStyle(.regularMaterial), in: shape)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }
}


/// 83.4 -> "1:23.4"
private func clock(_ seconds: Double, tenths: Bool = true) -> String {
    let t = max(0, tenths ? (seconds * 10).rounded() / 10 : seconds.rounded())
    let m = Int(t) / 60
    return tenths ? String(format: "%d:%04.1f", m, t - Double(m * 60)) : String(format: "%d:%02d", m, Int(t) % 60)
}

/// "1:23.4", "83.4" or "1:23" -> seconds
private func parseClock(_ text: String) -> Double? {
    let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let last = Double(parts.last!) else { return nil }
    if parts.count == 1 { return last }
    guard let minutes = Int(parts[0]), last < 60 else { return nil }
    return Double(minutes * 60) + last
}

private func pretty(_ type: String) -> String {
    type.replacingOccurrences(of: "_", with: " ").capitalized
}
