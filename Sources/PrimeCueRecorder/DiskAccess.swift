import AppKit
import SwiftUI

/// Prime keeps its library inside its own app container. macOS asks "would like to access data
/// from other apps" every launch for that, unless the app has Full Disk Access.
enum DiskAccess {
    /// The privacy database only opens with Full Disk Access, and trying doesn't prompt.
    static var granted: Bool {
        guard let handle = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db")
        else { return false }
        try? handle.close()
        return true
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!)
    }
}

struct DiskAccessSheet: View {
    @Bindable var model: AppModel
    @State private var granted = DiskAccess.granted
    @State private var openedSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: granted ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 40))
                    .foregroundStyle(granted ? .green : .accentColor)
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let Prime Cue Recorder open Prime's library").font(.title2.bold())
                    Text(granted ? "Full Disk Access is on. You're all set." : "One-time setup")
                        .foregroundStyle(.secondary)
                }
            }
            Text("Prime keeps your setlists and cues in its own private folder on this Mac. Prime Cue "
                 + "Recorder reads your songs from there and saves the cues you record back into it. "
                 + "It never touches anything else.")
            Text("Without Full Disk Access, macOS asks you to Allow this every time the app opens. "
                 + "Turn it on once and it stays on, through updates too.")
                .foregroundStyle(.secondary)
            if !granted {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Click Open Privacy Settings below.", systemImage: "1.circle")
                        Label("Turn on Prime Cue Recorder in the list. If it isn't there, click + and "
                              + "choose it in Applications.", systemImage: "2.circle")
                        Label("Come back here. This window notices on its own.", systemImage: "3.circle")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                if openedSettings {
                    Text("Turned it on and nothing changed? Quit Prime Cue Recorder and open it again.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                if !granted {
                    Button("Not Now") { model.finishDiskAccess(skipped: true) }
                        .help("macOS will ask you to Allow each time the app opens. You can turn this on later in Settings.")
                }
                Spacer()
                if granted {
                    Button("Continue") { model.finishDiskAccess(skipped: false) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Privacy Settings") {
                        DiskAccess.openSettings()
                        openedSettings = true
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth, value: granted)
        .animation(.smooth, value: openedSettings)
        .task {
            while !granted && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                granted = DiskAccess.granted
            }
        }
    }
}
