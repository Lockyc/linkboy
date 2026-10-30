import Foundation

public enum KeyRouter {
    /// The action `combo` performs, or nil to let the key through. While a text field in the page has focus,
    /// unmodified keys (⇧ included) are the user's typing and never route; ⌘/⌃/⌥ combos always do.
    public static func route(_ combo: KeyCombo, editableFocused: Bool, bindings: KeyBindings) -> Action? {
        if editableFocused && !combo.isModified { return nil }
        return bindings.map[combo]
    }
}
