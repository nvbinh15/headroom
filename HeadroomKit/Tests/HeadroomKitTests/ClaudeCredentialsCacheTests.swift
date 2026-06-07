import XCTest
@testable import HeadroomKit

final class ClaudeCredentialsCacheTests: XCTestCase {
    override func tearDown() {
        KeychainCredentialsLoader.headroomCredentialsFileURLOverride = nil
        super.tearDown()
    }

    func testLoadsCredentialsFromHeadroomCacheFileWithoutKeychain() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let cacheURL = tempDir.appendingPathComponent("claude-credentials.json")
        KeychainCredentialsLoader.headroomCredentialsFileURLOverride = cacheURL

        let json = """
        {
          "claudeAiOauth": {
            "accessToken": "cached-access-token",
            "rateLimitTier": "default_claude_max_5x",
            "expiresAt": 4102444800000
          }
        }
        """
        try Data(json.utf8).write(to: cacheURL)

        let credentials = try XCTUnwrap(KeychainCredentialsLoader.loadClaude())
        XCTAssertEqual(credentials.accessToken, "cached-access-token")
        XCTAssertEqual(credentials.plan, .max5x)

        let secondRead = try XCTUnwrap(KeychainCredentialsLoader.loadClaude())
        XCTAssertEqual(secondRead.accessToken, "cached-access-token")
    }
}
