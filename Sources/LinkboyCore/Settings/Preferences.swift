import Foundation

public enum Layout: String, Codable, Sendable, CaseIterable {
    case single, sideBySide
}

public enum Density: String, Codable, Sendable, CaseIterable {
    case compact, regular
}

/// User settings, kept in `UserDefaults` as one JSON value.
public struct Preferences: Codable, Equatable, Sendable {
    public var layout: Layout = .single
    /// Width of the entry list, in points.
    public var listWidth: Double = 320
    /// Share of the viewer the page takes in side-by-side layout.
    public var splitFraction: Double = 0.5
    public var listFontSize: Double = 13
    public var density: Density = .regular

    public init() {}

    static let key = "preferences"

    /// Defaults when nothing is stored or the stored value doesn't decode.
    public static func load(from defaults: UserDefaults = .standard) -> Preferences {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
