import Sparkle
import SwiftUI

/// Auto-updates (Sparkle): release builds check the feed in Info.plist (`SUFeedURL`) once a day and
/// offer new versions, which are signed with the key whose public half is `SUPublicEDKey`.
/// Builds without a feed (`swift run`, local builds) never update themselves.
///
/// Never mid-recording or mid-save: checks wait, and a relaunch into an update waits until it's done.
@MainActor
final class Updates {
    static let shared = Updates()

    /// Recording or saving, set by the model.
    var busy = false {
        didSet {
            if !busy, let relaunch = heldRelaunch {
                heldRelaunch = nil
                relaunch()
            }
        }
    }

    private let gate = UpdateGate()
    private let controller: SPUStandardUpdaterController?
    fileprivate var heldRelaunch: (() -> Void)?

    private init() {
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        controller = hasFeed
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: gate, userDriverDelegate: nil) : nil
    }

    var available: Bool { controller != nil }

    func check() {
        controller?.checkForUpdates(nil)
    }
}

/// Sparkle's delegate: says not now while recording or saving. Sparkle calls it on the main thread.
nonisolated private final class UpdateGate: NSObject, SPUUpdaterDelegate {
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
