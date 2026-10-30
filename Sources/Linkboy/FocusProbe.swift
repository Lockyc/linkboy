import LinkboyCore
import WebKit

/// Where `PageKeyScript` runs: in every frame, in linkboy's own content world (the page can't see or call it).
enum FocusProbe {
    static let world = WKContentWorld.world(name: "linkboy")
    static let message = PageKeyScript.messageName
}
