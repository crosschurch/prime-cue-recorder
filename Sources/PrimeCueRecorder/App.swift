import CueCore
import SwiftUI

@main
struct PrimeCueRecorderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Prime Cue Recorder", id: "main") {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView(model: model)
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSetup = false

    var body: some View {
        Group {
            switch model.phase {
            case .ready: ReadyView(model: model)
            case .recording: RecordingView(model: model)
            case .review: ReviewView(model: model)
            case .waitingForPrime: WaitingView(model: model)
            case .done(let message): DoneView(model: model, message: message)
            }
        }
        .frame(minWidth: 680, minHeight: 560)
        .safeAreaInset(edge: .top) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .glassCard(tint: .red, shape: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .navigationTitle(model.song?.name ?? "Prime Cue Recorder")
        .navigationSubtitle(model.setlists.first { $0.id == model.setlistId }?.name ?? "")
        .toolbar { toolbar }
        .sheet(isPresented: $showSetup) {
            SettingsView(model: model, isFirstRun: true)
        }
        .onAppear { if model.ppPort.isEmpty { showSetup = true } }
        .animation(.smooth, value: model.phase)
        .animation(.smooth, value: model.error)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ConnectionBadge(connection: model.connection)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Setlist", selection: $model.setlistId) {
                ForEach(model.setlists) { list in
                    Text("\(list.name) — \(list.serviceDate)").tag(Optional(list.id))
                }
            }
            .help("Setlist")
            Picker("Song", selection: $model.versionId) {
                ForEach(model.songs) { song in
                    Text(song.name).tag(Optional(song.id))
                }
            }
            .help("Song")
            Button("Reload", systemImage: "arrow.clockwise") { model.loadLibrary() }
                .help("Reload setlists from Prime")
        }
        ToolbarItem(placement: .primaryAction) {
            SettingsLink { Label("Settings", systemImage: "gearshape") }
                .help("ProPresenter settings")
        }
    }
}

// MARK: Ready

private struct ReadyView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            if let song = model.song {
                VStack(spacing: 6) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(.bottom, 6)
                    Text(song.name).font(.largeTitle.weight(.semibold))
                    Text(details(song)).foregroundStyle(.secondary)
                }
                RecordButton(isRecording: false) { model.startRecording() }
                    .disabled(song.arrangement.isEmpty)
                if song.arrangement.isEmpty {
                    Text("This song has no sections in Prime, so it can't be timed.")
                        .foregroundStyle(.orange)
                }
            } else {
                ContentUnavailableView("Choose a Song", systemImage: "music.note.list",
                                       description: Text("Pick a setlist and song from the toolbar."))
            }
            Spacer(minLength: 0)
            Steps()
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private func details(_ song: PrimeSong) -> String {
        let cues = model.songs.first { $0.id == song.versionId }?.lyricCues ?? 0
        return ["\(Int(song.tempo.rounded())) BPM", "\(song.arrangement.count) sections",
                cues > 0 ? "\(cues) lyric cues now" : "No lyric cues yet"].joined(separator: "  ·  ")
    }
}

private struct Steps: View {
    let steps = [
        ("record.circle", "Press Record"),
        ("play.fill", "Play the song in Prime from the top"),
        ("cursorarrow.click.2", "Click through the slides in ProPresenter"),
        ("checkmark.circle", "Stop, check, and save"),
    ]

    var body: some View {
        GlassGroup {
            HStack(spacing: 10) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    VStack(spacing: 8) {
                        Image(systemName: step.0).font(.title2).foregroundStyle(.tint)
                        Text("\(i + 1). \(step.1)")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 84)
                    .padding(12)
                    .glassCard(shape: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
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
                        Text("Recording").font(.headline)
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
                    .controlSize(.regular)
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
                List {
                    ForEach(Array(model.clicks.enumerated().reversed()), id: \.offset) { i, click in
                        SlideRow(slide: click.slide, group: click.group, text: click.text,
                                 trailing: String(format: "%.1fs", click.time))
                            .opacity(i == model.clicks.count - 1 ? 1 : 0.75)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
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
                    Stepper(value: $model.lead, in: 0...8, step: 0.5) {
                        Text("Lyrics \(model.lead, specifier: "%g") beats early").monospacedDigit()
                    }
                    .help("Blank slides always fire right where you clicked them.")
                }

                ForEach(plan.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .glassCard(tint: .orange, shape: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                List(Array(plan.cues.enumerated()), id: \.offset) { _, cue in
                    SlideRow(slide: cue.slide, group: pretty(cue.sectionType), text: cue.text,
                             trailing: String(format: "beat %.2f", cue.beat))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .glassCard(shape: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                        Button("Save to Prime", systemImage: "square.and.arrow.down") { model.save() }
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

// MARK: Saving

private struct WaitingView: View {
    @Bindable var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Quit Prime to Save", systemImage: "hourglass")
        } description: {
            Text("Prime has to be closed while the cues are saved, or it will overwrite them. "
                 + "They'll save as soon as Prime closes.")
        } actions: {
            GlassGroup {
                HStack {
                    Button("Cancel") { model.cancelSave() }.glassButton()
                    Button("Quit Prime") { model.quitPrime() }.glassProminentButton()
                }
                .controlSize(.large)
            }
        }
    }
}

private struct DoneView: View {
    @Bindable var model: AppModel
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label {
                Text("Saved")
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        } description: {
            Text(message)
        } actions: {
            GlassGroup {
                HStack {
                    Button("Record Another Song") { model.discard() }.glassButton()
                    Button("Open Prime", systemImage: "arrow.up.forward.app") { model.openPrime() }
                        .glassProminentButton()
                }
                .controlSize(.large)
            }
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
                .font(isRecording ? .body.weight(.semibold) : .title3.weight(.semibold))
                .padding(.horizontal, isRecording ? 6 : 18)
                .padding(.vertical, isRecording ? 2 : 8)
        }
        .glassProminentButton()
        .tint(.red)
        .controlSize(.extraLarge)
        .keyboardShortcut(isRecording ? .escape : .space, modifiers: [])
    }
}

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
        .padding(.vertical, 3)
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

struct SettingsView: View {
    @Bindable var model: AppModel
    var isFirstRun = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Computer", text: $model.ppHost, prompt: Text("127.0.0.1"))
                TextField("Port", text: $model.ppPort, prompt: Text("e.g. 50001"))
            } header: {
                Text("ProPresenter")
            } footer: {
                Text("In ProPresenter, open Settings › Network, turn on Enable Network, and copy the port here. "
                     + "Use 127.0.0.1 when ProPresenter runs on this Mac.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status") { ConnectionBadge(connection: model.connection) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .toolbar {
            if isFirstRun {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: model.ppPort) { Task { await model.checkConnection() } }
        .onChange(of: model.ppHost) { Task { await model.checkConnection() } }
    }
}

// MARK: Liquid Glass with a fallback for macOS 14–15

private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer { content }
        } else {
            content
        }
    }
}

private extension View {
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

private func firstLine(_ text: String) -> String {
    let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    return line.isEmpty ? "Blank" : line
}

private func pretty(_ type: String) -> String {
    type.replacingOccurrences(of: "_", with: " ").capitalized
}
