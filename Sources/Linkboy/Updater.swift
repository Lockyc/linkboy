import Foundation
import Sparkle

enum Updater {
    /// Sparkle's standard updater, started — or nil when `bundle` names no feed (`swift run`), so
    /// a build outside linkboy.app never checks a feed it doesn't have.
    static func make(bundle: Bundle = .main) -> SPUStandardUpdaterController? {
        guard bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        return SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }
}
