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
    }
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionBar
            songPicker
            Divider()
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            switch model.phase {
            case .ready: readyView
            case .recording: recordingView
            case .review: reviewView
            case .waitingForPrime: waitingView
            case .done(let message): doneView(message)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 560)
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .onAppear { if model.ppPort.isEmpty { showSettings = true } }
    }

    private var connectionBar: some View {
        HStack {
            switch model.connection {
            case .connected(let name):
                Label("Connected to \(name)", systemImage: "circle.fill").foregroundStyle(.green)
            case .checking:
                ProgressView().controlSize(.small)
                Text("Connecting to ProPresenter…")
            case .failed(let message):
                Label(message, systemImage: "circle.fill").foregroundStyle(.orange)
            case .unknown:
                Label("ProPresenter not set up", systemImage: "circle").foregroundStyle(.secondary)
            }
            Spacer()
            Button("ProPresenter Settings…") { showSettings = true }
        }
        .font(.callout)
    }

    private var songPicker: some View {
        HStack {
            Picker("Setlist", selection: $model.setlistId) {
                ForEach(model.setlists) { Text("\($0.name) · \($0.serviceDate)").tag(Optional($0.id)) }
            }
            Picker("Song", selection: $model.versionId) {
                ForEach(model.songs) { song in
                    Text(song.name + (song.isActive ? " (open in Prime)" : "")
                         + (song.lyricCues > 0 ? " · \(song.lyricCues) cues" : ""))
                        .tag(Optional(song.id))
                }
            }
            Button { model.loadLibrary() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload setlists from Prime")
        }
        .disabled(model.phase == .recording)
    }

    private var readyView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How it works").font(.headline)
            Text("""
            1. Press Record.
            2. Play the song in Prime from the top, all the way through.
            3. Click through the slides in ProPresenter like you would on Sunday.
            4. Press Stop, check the cues, and save them to Prime.
            """)
            .foregroundStyle(.secondary)
            Button { model.startRecording() } label: {
                Label("Record", systemImage: "record.circle").frame(minWidth: 140)
            }
            .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            .disabled(model.song == nil)
            if let song = model.song, song.arrangement.isEmpty {
                Text("This song has no sections in Prime, so it can't be timed.").foregroundStyle(.orange)
            }
        }
    }

    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "record.circle.fill").foregroundStyle(.red).symbolEffect(.pulse)
                Text(model.presentationName.map { "Recording “\($0)”" } ?? "Recording… play the song and click the first slide")
                    .font(.headline)
                Spacer()
                Button { model.stopRecording() } label: { Label("Stop", systemImage: "stop.fill") }
                    .controlSize(.large)
            }
            if model.otherPresentationClicks > 0 {
                Text("Ignored \(model.otherPresentationClicks) click(s) in a different presentation.")
                    .foregroundStyle(.orange)
            }
            List(Array(model.clicks.enumerated().reversed()), id: \.offset) { _, click in
                HStack(alignment: .firstTextBaseline) {
                    Text(String(format: "%5.1fs", click.time)).monospacedDigit().foregroundStyle(.secondary)
                    Text("#\(click.slide)").monospacedDigit().frame(width: 40, alignment: .leading)
                    Text(click.group).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Text(firstLine(click.text)).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private var reviewView: some View {
        if let plan = model.plan {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("\(plan.cues.count) cues ready").font(.headline)
                    if let err = plan.fitError {
                        Text(String(format: "· lined up with %d section changes, ±%.1f beats", plan.anchors, err))
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(plan.warnings, id: \.self) {
                    Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                Stepper(value: $model.lead, in: 0...8, step: 0.5) {
                    Text("Fire lyric slides \(model.lead, specifier: "%g") beats early")
                }
                .help("Blank slides always fire right where you clicked them.")
                Table(plan.cues.indices.map { IndexedCue(index: $0, cue: plan.cues[$0]) }) {
                    TableColumn("Slide") { Text("#\($0.cue.slide)").monospacedDigit() }.width(50)
                    TableColumn("Section") { Text(pretty($0.cue.sectionType)) }.width(110)
                    TableColumn("Beat") { Text(String(format: "%.2f", $0.cue.beat)).monospacedDigit() }.width(60)
                    TableColumn("Lyrics") { Text(firstLine($0.cue.text)).foregroundStyle($0.cue.text.isEmpty ? .secondary : .primary) }
                }
                HStack {
                    Button("Record Again", role: .destructive) { model.discard() }
                    Spacer()
                    Button("Save to Prime") { model.save() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(plan.cues.isEmpty)
                }
            }
        }
    }

    private var waitingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quit Prime to save").font(.headline)
            Text("Prime has to be closed while the cues are saved, or it will overwrite them. "
                 + "They'll save as soon as Prime closes.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Quit Prime") { model.quitPrime() }.buttonStyle(.borderedProminent)
                Button("Cancel") { model.cancelSave() }
            }
        }
    }

    private func doneView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Saved", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            Text(message)
            HStack {
                Button("Open Prime") { model.openPrime() }.buttonStyle(.borderedProminent)
                Button("Record Another Song") { model.discard() }
            }
        }
    }

    private func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "(blank)" : line
    }

    private func pretty(_ type: String) -> String {
        type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct IndexedCue: Identifiable {
    let index: Int
    let cue: PlannedCue
    var id: Int { index }
}

struct SettingsSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Text("In ProPresenter, open Settings > Network, turn on Enable Network, and copy the port here.")
                .foregroundStyle(.secondary)
            TextField("Computer running ProPresenter", text: $model.ppHost, prompt: Text("127.0.0.1"))
            TextField("Port", text: $model.ppPort, prompt: Text("e.g. 50001"))
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                    Task { await model.checkConnection() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
