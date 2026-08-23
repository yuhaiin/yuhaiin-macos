import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    private let controller: SPUStandardUpdaterController

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        if isConfigured {
            controller.startUpdater()
        }
    }

    var isConfigured: Bool {
        guard let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String else {
            return false
        }
        guard URL(string: feedURL)?.scheme != nil else { return false }
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            return false
        }
        return !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canCheckForUpdates: Bool {
        isConfigured && controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        controller.checkForUpdates(nil)
    }
}
