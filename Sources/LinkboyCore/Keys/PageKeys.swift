import Foundation

/// The names a web page's key listener matches on: `KeyboardEvent.key` (single characters lowercased), prefixed
/// `shift+` when ⇧ is held. Only unmodified combos (⇧ allowed) have one — ⌘/⌃/⌥ combos never reach the page.
extension KeyCombo {
    public var pageKey: String? {
        guard !isModified else { return nil }
        let name = Self.domNames[key] ?? key
        return modifiers.contains(.shift) ? "shift+" + name : name
    }

    public init?(pageKey: String) {
        let shifted = pageKey.hasPrefix("shift+") && pageKey.count > "shift+".count
        let name = shifted ? String(pageKey.dropFirst("shift+".count)) : pageKey
        guard !name.isEmpty else { return nil }
        let key = Self.domNames.first { $0.value == name }?.key ?? name
        self.init(key: key, modifiers: shifted ? [.shift] : [])
    }

    /// AppKit's characters for keys whose DOM `key` is a name: Return, Tab, Delete, Escape, the arrows and F1–F35.
    private static let domNames: [String: String] = {
        var names: [String: String] = [
            "\r": "Enter", "\t": "Tab", "\u{7f}": "Backspace", "\u{1b}": "Escape",
            "\u{F700}": "ArrowUp", "\u{F701}": "ArrowDown", "\u{F702}": "ArrowLeft", "\u{F703}": "ArrowRight",
        ]
        for n in 0..<35 { names[String(UnicodeScalar(0xF704 + n)!)] = "F\(n + 1)" }
        return names
    }()
}

extension KeyBindings {
    /// The page keys of every unmodified binding, sorted, for the in-page listener.
    public var pageKeys: [String] { map.keys.compactMap(\.pageKey).sorted() }
}
