import Foundation

/// Both the menu-bar app and the widget extension are unsandboxed for local dev,
/// so they can share a plain file in Application Support — no App Group needed.
enum SharedStatePath {
    static let url: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("state.json")
    }()
}
