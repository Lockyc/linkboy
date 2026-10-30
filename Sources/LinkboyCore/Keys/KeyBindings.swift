import Foundation

public enum Modifier: String, Codable, Hashable, Sendable, CaseIterable {
    case command, control, option, shift
}

/// One key press: the key's character as typed without modifiers (lowercased), plus the modifiers held.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var key: String
    public var modifiers: Set<Modifier>

    public init(key: String, modifiers: Set<Modifier> = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Held ⌘, ⌃ or ⌥ — a shortcut rather than typing. ⇧ alone is still typing.
    public var isModified: Bool { !modifiers.isDisjoint(with: [.command, .control, .option]) }
}

/// The rebindable reading actions. Mark all is deliberately absent: it is never one keystroke away.
public enum Action: String, Codable, CaseIterable, Sendable {
    case next, previous, togglePane, star, toggleRead, openInBrowser
}

/// Which combo performs which action; each action has at most one combo and no combo serves two actions.
public struct KeyBindings: Codable, Equatable, Sendable {
    public var map: [KeyCombo: Action]

    public init(map: [KeyCombo: Action]) { self.map = map }

    public static let `default` = KeyBindings(map: [
        KeyCombo(key: "j"): .next,
        KeyCombo(key: "k"): .previous,
        KeyCombo(key: "c"): .togglePane,
        KeyCombo(key: "s"): .star,
        KeyCombo(key: "u"): .toggleRead,
        KeyCombo(key: "o"): .openInBrowser,
    ])

    private enum CodingKeys: String, CodingKey { case map }

    /// Bindings saved before an action existed gain it on its default combo, unless something else holds that.
    public init(from decoder: Decoder) throws {
        map = try decoder.container(keyedBy: CodingKeys.self).decode([KeyCombo: Action].self, forKey: .map)
        let bound = Set(map.values)
        for (combo, action) in Self.default.map where !bound.contains(action) && map[combo] == nil {
            map[combo] = action
        }
    }

    public func combo(for action: Action) -> KeyCombo? { map.first { $0.value == action }?.key }

    /// Binds `action` to `combo`, releasing its previous combo. If another action holds `combo`, nothing
    /// changes and that action is returned.
    @discardableResult
    public mutating func rebind(_ action: Action, to combo: KeyCombo) -> Action? {
        if let holder = map[combo], holder != action { return holder }
        map = map.filter { $0.value != action }
        map[combo] = action
        return nil
    }
}
