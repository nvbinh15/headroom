import Foundation
import Security

public struct ClaudeCredentials: Sendable, Codable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public var plan: ClaudePlan {
        guard let tier = rateLimitTier else { return .unknown }
        return ClaudePlan(rawValue: tier) ?? .unknown
    }
}

public enum KeychainCredentialsLoader {
    /// Reads the OAuth blob Claude Code writes to the macOS keychain under
    /// service "Claude Code-credentials". Returns nil if not present (e.g.
    /// when running in a sandbox without keychain access, or a fresh login
    /// hasn't happened yet).
    public static func loadClaude() -> ClaudeCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String else { return nil }

        let expiresAt: Date? = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return ClaudeCredentials(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }
}
