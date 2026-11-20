import XCTest
@testable import HeadroomKit

final class ElectronSafeStorageTests: XCTestCase {
    func testDecryptsChromiumV10Payload() throws {
        // openssl enc -aes-128-cbc, key = PBKDF2-SHA1("peanuts", "saltysalt", 1003), iv = 16 spaces
        let ciphertext = Data([0x67, 0xf2, 0xc4, 0xd6, 0x0d, 0x0a, 0x05, 0x63,
                               0x60, 0x70, 0xe4, 0xd4, 0x5b, 0x68, 0x59, 0xb7])
        let key = try XCTUnwrap(ElectronSafeStorage.deriveKey(password: Data("peanuts".utf8)))
        let plain = try XCTUnwrap(ElectronSafeStorage.aes128CBCDecrypt(ciphertext, key: key))
        XCTAssertEqual(String(data: plain, encoding: .utf8), "cursor-token")
    }

    func testClaudeDesktopCachePicksFreshestProfileToken() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let ms = { (s: Double) in (now.timeIntervalSince1970 + s) * 1000 }
        let json = """
        {
          "acct:a|c:o:https://api.anthropic.com:user:inference": {"token": "no-profile", "expiresAt": \(ms(9000))},
          "acct:a|c:o:https://api.anthropic.com:user:profile": {"token": "expired", "expiresAt": \(ms(-10))},
          "acct:a|c:o:https://api.anthropic.com:user:inference user:profile": {"token": "good", "refreshToken": "r",
            "expiresAt": \(ms(3600)), "rateLimitTier": "default_claude_max_5x"}
        }
        """
        let creds = try XCTUnwrap(KeychainCredentialsLoader.parseClaudeDesktopTokenCache(Data(json.utf8), now: now))
        XCTAssertEqual(creds.accessToken, "good")
        XCTAssertNil(creds.refreshToken) // never rotate the desktop app's login
        XCTAssertEqual(creds.plan, .max5x)
    }
}
