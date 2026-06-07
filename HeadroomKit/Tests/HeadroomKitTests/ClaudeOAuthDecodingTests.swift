import XCTest
@testable import HeadroomKit

final class ClaudeOAuthDecodingTests: XCTestCase {
    func testUsageResponseDecodesFractionalResetDates() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 12.5,
            "resets_at": "2025-12-25T12:00:00.000Z"
          },
          "seven_day_sonnet": {
            "utilization": 5,
            "resets_at": "2025-12-31T00:00:00Z"
          }
        }
        """

        let response = try JSONDecoder().decode(OAuthUsageClient.Response.self, from: Data(json.utf8))

        XCTAssertEqual(response.five_hour?.utilization, 12.5)
        XCTAssertEqual(Int(try XCTUnwrap(response.five_hour?.resets_at).timeIntervalSince1970), 1_766_664_000)
        XCTAssertEqual(response.seven_day_sonnet?.utilization, 5)
        XCTAssertNotNil(response.seven_day_sonnet?.resets_at)
    }

    func testClaudeCredentialParserAcceptsMillisecondExpiry() throws {
        let json = """
        {
          "claudeAiOauth": {
            "accessToken": " access-token ",
            "refreshToken": "refresh-token",
            "expiresAt": 1766948068000,
            "subscriptionType": "pro",
            "rateLimitTier": "default_claude_pro"
          }
        }
        """

        let credentials = try XCTUnwrap(KeychainCredentialsLoader.parseClaudeCredentials(data: Data(json.utf8)))

        XCTAssertEqual(credentials.accessToken, "access-token")
        XCTAssertEqual(credentials.refreshToken, "refresh-token")
        XCTAssertEqual(credentials.plan, .pro)
        XCTAssertEqual(Int(try XCTUnwrap(credentials.expiresAt).timeIntervalSince1970), 1_766_948_068)
    }
}
