import Foundation

public enum KeyRouter {
    /// The action `combo` performs, or nil to let the key through. While `editableFocused` — something that takes
    /// typing holds the keyboard — unmodified keys (⇧ included) belong to it and never route; ⌘/⌃/⌥ combos always do.
    public static func route(_ combo: KeyCombo, editableFocused: Bool, bindings: KeyBindings) -> Action? {
        if editableFocused && !combo.isModified { return nil }
        return bindings.map[combo]
    }
}
