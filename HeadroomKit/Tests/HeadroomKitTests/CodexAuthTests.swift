import XCTest
@testable import HeadroomKit

final class CodexAuthTests: XCTestCase {
    func testParsesSnakeCaseCodexAuthAndRefreshAge() throws {
        let url = URL(fileURLWithPath: "/tmp/auth.json")
        let json = """
        {
          "tokens": {
            "access_token": "access-token",
            "refresh_token": "refresh-token",
            "id_token": "id-token",
            "account_id": "account-id"
          },
          "last_refresh": "2026-05-01T00:00:00Z"
        }
        """

        let auth = try XCTUnwrap(CodexAuth.parse(data: Data(json.utf8), authFileURL: url))

        XCTAssertEqual(auth.accessToken, "access-token")
        XCTAssertEqual(auth.refreshToken, "refresh-token")
        XCTAssertEqual(auth.idToken, "id-token")
        XCTAssertEqual(auth.accountID, "account-id")
        let lastRefresh = try XCTUnwrap(auth.lastRefresh)
        XCTAssertFalse(auth.needsRefresh(now: lastRefresh.addingTimeInterval(8 * 24 * 60 * 60 - 1)))
        XCTAssertTrue(auth.needsRefresh(now: lastRefresh.addingTimeInterval(8 * 24 * 60 * 60 + 1)))
    }

    func testParsesLegacyCamelCaseCodexAuth() throws {
        let url = URL(fileURLWithPath: "/tmp/auth.json")
        let json = """
        {
          "tokens": {
            "accessToken": "access-token",
            "refreshToken": "refresh-token",
            "idToken": "id-token",
            "accountId": "account-id"
          }
        }
        """

        let auth = try XCTUnwrap(CodexAuth.parse(data: Data(json.utf8), authFileURL: url))

        XCTAssertEqual(auth.accessToken, "access-token")
        XCTAssertEqual(auth.refreshToken, "refresh-token")
        XCTAssertEqual(auth.idToken, "id-token")
        XCTAssertEqual(auth.accountID, "account-id")
        XCTAssertTrue(auth.needsRefresh())
    }
}
