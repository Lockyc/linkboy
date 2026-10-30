import AppKit
import LinkboyCore

extension KeyCombo {
    /// The combo a key-down event presses; nil for a key with no character (a bare modifier, a dead key).
    init?(event: NSEvent) {
        guard event.type == .keyDown, let chars = event.charactersIgnoringModifiers?.lowercased(), chars.count == 1
        else { return nil }
        let flags = event.modifierFlags
        var mods = Set<Modifier>()
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        self.init(key: chars, modifiers: mods)
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { f.insert(.command) }
        if modifiers.contains(.control) { f.insert(.control) }
        if modifiers.contains(.option) { f.insert(.option) }
        if modifiers.contains(.shift) { f.insert(.shift) }
        return f
    }

    /// As a menu shows it: `⌃⌥⇧⌘` then the key, e.g. `J`, `⇧J`, `⌘↓`.
    var display: String {
        let glyphs = (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
        return glyphs + (Self.keyNames[key] ?? key.uppercased())
    }

    private static let keyNames: [String: String] = [
        " ": "Space", "\r": "↩", "\t": "⇥", "\u{7f}": "⌫", "\u{1b}": "⎋",
        String(UnicodeScalar(UInt16(NSUpArrowFunctionKey))!): "↑",
        String(UnicodeScalar(UInt16(NSDownArrowFunctionKey))!): "↓",
        String(UnicodeScalar(UInt16(NSLeftArrowFunctionKey))!): "←",
        String(UnicodeScalar(UInt16(NSRightArrowFunctionKey))!): "→",
    ]
}

extension Action {
    var title: String {
        switch self {
        case .next: "Next item"
        case .previous: "Previous item"
        case .togglePane: "Switch page / comments"
        case .star: "Star"
        case .openInBrowser: "Open in browser"
        }
    }
}
