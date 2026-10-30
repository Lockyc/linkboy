import Foundation
import WebKit

/// The user's content-blocking rules (WebKit content-rule-list JSON) from `content-rules.json` in the app's
/// Application Support folder, compiled once and applied to every web view. A list that fails to compile
/// never replaces the active one.
@MainActor
final class ContentRules {
    static let shared = ContentRules()

    static let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("linkboy/content-rules.json")
    private static let identifier = "content-rules"

    /// Why the saved rules aren't active, or nil when they are.
    private(set) var error: String?
    private var list: WKContentRuleList?
    private let controllers = NSHashTable<WKUserContentController>.weakObjects()

    /// Compiles the saved rules, first writing an empty list if there is no file yet.
    func loadSaved() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.fileURL.path) {
            try? fm.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data("[]\n".utf8).write(to: Self.fileURL, options: .atomic)
        }
        Task {
            switch await compile(savedSource()) {
            case .success(let compiled): activate(compiled)
            case .failure(let failure): error = failure.message
            }
        }
    }

    func savedSource() -> String { (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? "[]\n" }

    /// Compiles `source`, writes it to the file, then makes it the active list. Returns the compile or write error,
    /// in which case the previous list stays active and the file is untouched.
    func save(_ source: String) async -> String? {
        let compiled: WKContentRuleList?
        switch await compile(source) {
        case .success(let list): compiled = list
        case .failure(let failure): return failure.message
        }
        do {
            try Data(source.utf8).write(to: Self.fileURL, options: .atomic)
        } catch {
            return "Couldn't save the rules: \(error.localizedDescription)"
        }
        activate(compiled)
        return nil
    }

    /// Applies the active list to `controller` now and to every later list.
    func attach(_ controller: WKUserContentController) {
        controllers.add(controller)
        if let list { controller.add(list) }
    }

    private struct Failure: Error { let message: String }

    /// The compiled list, nil for an empty array (WebKit refuses to compile one, and it means no rules).
    private func compile(_ source: String) async -> Result<WKContentRuleList?, Failure> {
        if let parsed = try? JSONSerialization.jsonObject(with: Data(source.utf8)) as? [Any], parsed.isEmpty {
            return .success(nil)
        }
        do {
            guard let list = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: Self.identifier, encodedContentRuleList: source)
            else { return .failure(Failure(message: "The rules didn't compile")) }
            return .success(list)
        } catch {
            // WebKit puts the compiler's message ("Rule list compilation failed: …") in the help anchor.
            return .failure(Failure(message: (error as NSError).helpAnchor ?? error.localizedDescription))
        }
    }

    private func activate(_ compiled: WKContentRuleList?) {
        list = compiled
        error = nil
        for c in controllers.allObjects {
            c.removeAllContentRuleLists()
            if let compiled { c.add(compiled) }
        }
    }
}
