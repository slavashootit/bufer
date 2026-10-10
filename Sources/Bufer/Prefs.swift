import Foundation

/// User settings in UserDefaults, edited in the settings window.
enum Prefs {
    private static let defaults = UserDefaults.standard

    /// Bundle IDs whose copies are never recorded.
    static var excludedApps: [String] {
        get { defaults.stringArray(forKey: "excludedApps") ?? [] }
        set { defaults.set(newValue, forKey: "excludedApps") }
    }

    /// Paste without formatting unless ⌥ is held (⌥ flips it either way).
    static var plainTextByDefault: Bool {
        get { defaults.bool(forKey: "plainTextByDefault") }
        set { defaults.set(newValue, forKey: "plainTextByDefault") }
    }

    /// Recognize text on copied images so search finds screenshots.
    static var recognizeText: Bool {
        get { defaults.object(forKey: "recognizeText") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "recognizeText") }
    }

    /// Fetch page titles for copied links (makes a request to that site).
    static var fetchLinkTitles: Bool {
        get { defaults.object(forKey: "fetchLinkTitles") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fetchLinkTitles") }
    }

    /// Open the panel next to the mouse pointer; otherwise centered on that screen.
    static var panelAtCursor: Bool {
        get { defaults.object(forKey: "panelAtCursor") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "panelAtCursor") }
    }

    /// Icon in the menu bar. Without it settings open from the panel's gear, ⌘, or by
    /// launching Bufer again.
    static var showStatusIcon: Bool {
        get { defaults.object(forKey: "showStatusIcon") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showStatusIcon") }
    }

    /// Unpinned items kept; 0 means no limit.
    static var historyLimit: Int {
        get { defaults.object(forKey: "historyLimit") as? Int ?? 20_000 }
        set { defaults.set(newValue, forKey: "historyLimit") }
    }

    /// Unpinned items older than this many days are removed; 0 means never.
    static var maxAgeDays: Int {
        get { defaults.integer(forKey: "maxAgeDays") }
        set { defaults.set(newValue, forKey: "maxAgeDays") }
    }

    /// How often the clipboard is checked, in seconds.
    static var pollInterval: Double {
        get { defaults.object(forKey: "pollInterval") as? Double ?? 0.5 }
        set { defaults.set(newValue, forKey: "pollInterval") }
    }

    static var showShortcut: Shortcut {
        get { shortcut(forKey: "showShortcut") ?? .showDefault }
        set { setShortcut(newValue, forKey: "showShortcut") }
    }

    static var plainShortcut: Shortcut {
        get { shortcut(forKey: "plainShortcut") ?? .plainDefault }
        set { setShortcut(newValue, forKey: "plainShortcut") }
    }

    private static func shortcut(forKey key: String) -> Shortcut? {
        guard let dict = defaults.dictionary(forKey: key),
              let code = dict["code"] as? Int, let mods = dict["mods"] as? Int else { return nil }
        return Shortcut(keyCode: code, modifiers: mods)
    }

    private static func setShortcut(_ shortcut: Shortcut, forKey key: String) {
        defaults.set(["code": shortcut.keyCode, "mods": shortcut.modifiers], forKey: key)
    }
}
