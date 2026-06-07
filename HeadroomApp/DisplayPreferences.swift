import Foundation

enum DisplayPreferences {
    private static let showRemainingKey = "showRemainingPercent"
    private static let lowHeadroomWarningsKey = "lowHeadroomWarnings"
    private static let densityExplicitKey = "menuBarDensityExplicit"

    static func loadShowRemainingPercent() -> Bool {
        UserDefaults.standard.bool(forKey: showRemainingKey)
    }

    static func save(showRemainingPercent: Bool) {
        UserDefaults.standard.set(showRemainingPercent, forKey: showRemainingKey)
    }

    static func loadLowHeadroomWarnings() -> Bool {
        UserDefaults.standard.bool(forKey: lowHeadroomWarningsKey)
    }

    static func save(lowHeadroomWarnings: Bool) {
        UserDefaults.standard.set(lowHeadroomWarnings, forKey: lowHeadroomWarningsKey)
    }

    static func isDensityExplicitlySet() -> Bool {
        UserDefaults.standard.bool(forKey: densityExplicitKey)
    }

    static func markDensityExplicitlySet() {
        UserDefaults.standard.set(true, forKey: densityExplicitKey)
    }
}
