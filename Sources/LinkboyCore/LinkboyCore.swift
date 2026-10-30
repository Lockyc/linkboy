import Foundation

public enum LinkboyCore {
    /// The app version, from the root `VERSION` file via the bundle's Info.plist; "0.0.0" outside a bundle.
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
