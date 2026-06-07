import XCTest
@testable import HeadroomKit

final class CodexUsageReaderTests: XCTestCase {
    func testClassifiesOnlyRealSevenDayWindowAsWeekly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-codex-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("rollout-test.jsonl")
        let jsonl = """
        {"event":{"rate_limits":{"primary":{"used_percent":17,"window_minutes":540,"resets_at":4102444800},"secondary":{"used_percent":43,"window_minutes":10080,"resets_at":4102444800}}}}
        """
        try Data(jsonl.utf8).write(to: file)

        let usage = CodexUsageReader(sessionsDir: dir).read()

        XCTAssertEqual(usage.fiveHour?.fraction, 0.17)
        XCTAssertEqual(usage.fiveHour?.windowMinutes, 540)
        XCTAssertEqual(usage.weekly?.fraction, 0.43)
        XCTAssertEqual(usage.weekly?.windowMinutes, 10080)
    }

    func testMapsWeeklyOnlySnapshotToWeekly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-codex-sessions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("rollout-test.jsonl")
        let jsonl = """
        {"event":{"rate_limits":{"primary":{"used_percent":9,"window_minutes":10080,"resets_at":4102444800}}}}
        """
        try Data(jsonl.utf8).write(to: file)

        let usage = CodexUsageReader(sessionsDir: dir).read()

        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.weekly?.fraction, 0.09)
        XCTAssertEqual(usage.weekly?.windowMinutes, 10080)
    }
}
