import Foundation

public enum LinkboyCore {
    /// The bundle ID, also the Keychain service and the log subsystem. `InfoPlistTests` pins the bundle's copy.
    public static let bundleID = "com.lockyc.linkboy"

    /// The app version, from the root `VERSION` file via the bundle's Info.plist; "0.0.0" outside a bundle.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
