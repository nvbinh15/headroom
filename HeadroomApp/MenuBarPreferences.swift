import Foundation

enum MenuBarDensity: String, CaseIterable, Identifiable {
    case full
    case compact
    case iconsOnly
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Full"
        case .compact: return "Compact"
        case .iconsOnly: return "Icons"
        case .hidden: return "Hidden"
        }
    }

    var detail: String {
        switch self {
        case .full: return "Icon + primary · secondary %"
        case .compact: return "Icon + primary %"
        case .iconsOnly: return "Provider icons only"
        case .hidden: return "Headroom icon only"
        }
    }
}

enum MenuBarPreferences {
    private static let densityKey = "menuBarDensity"
    private static let showClaudeKey = "menuBarShowClaude"
    private static let showCodexKey = "menuBarShowCodex"
    private static let showCursorKey = "menuBarShowCursor"

    static func loadDensity() -> MenuBarDensity {
        guard let raw = UserDefaults.standard.string(forKey: densityKey),
              let density = MenuBarDensity(rawValue: raw)
        else { return .compact }
        return density
    }

    static func loadShowClaude() -> Bool {
        guard UserDefaults.standard.object(forKey: showClaudeKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: showClaudeKey)
    }

    static func loadShowCodex() -> Bool {
        guard UserDefaults.standard.object(forKey: showCodexKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: showCodexKey)
    }

    static func loadShowCursor() -> Bool {
        guard UserDefaults.standard.object(forKey: showCursorKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: showCursorKey)
    }

    static func save(density: MenuBarDensity) {
        UserDefaults.standard.set(density.rawValue, forKey: densityKey)
    }

    static func save(showClaude: Bool) {
        UserDefaults.standard.set(showClaude, forKey: showClaudeKey)
    }

    static func save(showCodex: Bool) {
        UserDefaults.standard.set(showCodex, forKey: showCodexKey)
    }

    static func save(showCursor: Bool) {
        UserDefaults.standard.set(showCursor, forKey: showCursorKey)
    }
}
