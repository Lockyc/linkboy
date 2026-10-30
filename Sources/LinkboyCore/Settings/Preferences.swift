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
    public var bindings: KeyBindings = .default

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case layout, listWidth, splitFraction, listFontSize, density, bindings
    }

    /// A missing field takes its default, so a value saved before a field existed keeps everything else.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout) ?? d.layout
        listWidth = try c.decodeIfPresent(Double.self, forKey: .listWidth) ?? d.listWidth
        splitFraction = try c.decodeIfPresent(Double.self, forKey: .splitFraction) ?? d.splitFraction
        listFontSize = try c.decodeIfPresent(Double.self, forKey: .listFontSize) ?? d.listFontSize
        density = try c.decodeIfPresent(Density.self, forKey: .density) ?? d.density
        bindings = try c.decodeIfPresent(KeyBindings.self, forKey: .bindings) ?? d.bindings
    }

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
