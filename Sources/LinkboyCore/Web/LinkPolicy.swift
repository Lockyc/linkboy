import Foundation

public enum LinkDecision: Equatable, Sendable {
    /// Hand the URL to the default browser and cancel the navigation.
    case openExternally
    /// Cancel the new-window request and load its URL in the viewer that made it.
    case loadHere
    /// Let the navigation proceed in the viewer.
    case allow
}

/// Where a viewer's navigation goes: ⌘ on a clicked link or a new-window request sends it to the default browser;
/// a new-window request without ⌘ (`target=_blank`, `window.open`) loads in the same viewer; anything else stays.
public enum LinkPolicy {
    public static func decide(command: Bool, linkActivated: Bool, opensNewWindow: Bool) -> LinkDecision {
        if command && (linkActivated || opensNewWindow) { return .openExternally }
        return opensNewWindow ? .loadHere : .allow
    }
}
