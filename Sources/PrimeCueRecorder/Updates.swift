import CueCore
import Observation
import Sparkle
import SwiftUI

/// Auto-updates (Sparkle): release builds check the feed in Info.plist (`SUFeedURL`) once a day and
/// offer new versions, which are signed with the key whose public half is `SUPublicEDKey`.
/// Builds without a feed (`swift run`, local builds) never update themselves.
///
/// Never mid-recording or mid-save: checks wait, and a relaunch into an update waits until it's done.
@MainActor @Observable
final class Updates {
    static let shared = Updates()

    /// Recording or saving, set by the model.
    @ObservationIgnored var busy = false {
        didSet {
            if !busy, let relaunch = heldRelaunch {
                heldRelaunch = nil
                relaunch()
            }
        }
    }

    /// A newer version waiting in the feed, found by a quiet check; shown in the toolbar and Settings.
    var newVersion: String?
    var lastChecked: Date?

    @ObservationIgnored private let gate = UpdateGate()
    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored fileprivate var heldRelaunch: (() -> Void)?

    private init() {
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = hasFeed
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: gate, userDriverDelegate: gate) : nil
        lastChecked = controller?.updater.lastUpdateCheckDate
        Task {
            try? await Task.sleep(for: .seconds(10))
            lookQuietly()
        }
    }

    var available: Bool { controller != nil }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Opens Sparkle's window: the update with its notes, or "you're up to date".
    func check() {
        controller?.checkForUpdates(nil)
    }

    /// Asks the feed without showing anything, to light up the toolbar and Settings.
    func lookQuietly() {
        guard let updater = controller?.updater, updater.sessionInProgress == false, !busy else { return }
        updater.checkForUpdateInformation()
    }

    fileprivate func found(_ version: String?) {
        newVersion = version
        lastChecked = controller?.updater.lastUpdateCheckDate ?? Date()
    }
}

/// Sparkle's delegates: says not now while recording or saving, notes what the feed offers, and
/// trims the release notes to the versions newer than this one. Sparkle calls them on the main thread.
nonisolated private final class UpdateGate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private var busy: Bool { MainActor.assumeIsolated { Updates.shared.busy } }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard busy else { return }
        throw NSError(domain: "church.cross.PrimeCueRecorder.updates", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Finish recording or saving first, then check for updates.",
        ])
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard busy else { return false }
        MainActor.assumeIsolated { Updates.shared.heldRelaunch = installHandler }
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { Updates.shared.found(version) }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { Updates.shared.found(nil) }
    }

    func standardUserDriverWillShowReleaseNotesText(
        _ releaseNotesAttributedString: NSAttributedString, for update: SUAppcastItem,
        withBundleDisplayVersion bundleDisplayVersion: String, bundleVersion: String
    ) -> NSAttributedString? {
        ReleaseNotes.newer(than: bundleDisplayVersion, in: releaseNotesAttributedString)
    }
}

/// Prime Cue Recorder › Check for Updates…
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { Updates.shared.check() }
                .disabled(!Updates.shared.available)
        }
    }
}

/// Settings › Updates
struct UpdatesSection: View {
    @State private var updates = Updates.shared
    @State private var automatic = Updates.shared.checksAutomatically

    var body: some View {
        Section {
            LabeledContent("Version", value: Updates.version)
            if let new = updates.newVersion {
                LabeledContent {
                    Button("Update…") { updates.check() }
                        .buttonStyle(.borderedProminent)
                } label: {
                    Label("Version \(new) is available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.tint)
                }
            } else {
                LabeledContent {
                    Button("Check for Updates…") { updates.check() }
                        .disabled(!updates.available)
                } label: {
                    if let checked = updates.lastChecked {
                        Text("Up to date, checked \(checked, format: .relative(presentation: .named))")
                    } else {
                        Text(updates.available ? "Not checked yet" : "This build doesn't update itself")
                    }
                }
            }
            Toggle("Check for updates every day", isOn: $automatic)
                .onChange(of: automatic) { updates.checksAutomatically = automatic }
                .disabled(!updates.available)
        } header: {
            Text("Updates")
        }
        .onAppear { updates.lookQuietly() }
    }
}

/// Toolbar: a colored download icon, only when a new version is waiting.
struct UpdateBadge: View {
    @State private var updates = Updates.shared

    var body: some View {
        if let new = updates.newVersion {
            Button {
                updates.check()
            } label: {
                Label("Update to \(new)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .help("Version \(new) of Prime Cue Recorder is ready to install")
        }
    }
}
