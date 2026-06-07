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

    public func isExpired(leeway: TimeInterval = 60, now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now.addingTimeInterval(leeway)
    }
}

public enum KeychainCredentialsLoader {
    private static let claudeService = "Claude Code-credentials"
    private static let cacheService = "Headroom-ClaudeCredentialsCache"
    private static let cacheAccount = "Claude Code OAuth"
    private static let credentialsFileName = "claude-credentials.json"
    private static let deniedUntilKey = "HeadroomClaudeKeychainDeniedUntil"
    private static let denialCooldown: TimeInterval = 6 * 60 * 60

    private static let memoryLock = NSLock()
    private nonisolated(unsafe) static var memoryCredentials: ClaudeCredentials?

    /// Override in tests to redirect the Headroom credential cache file.
    static var headroomCredentialsFileURLOverride: URL?

    /// Reads Claude OAuth credentials without repeatedly prompting for Claude Code's
    /// keychain item. A copy is kept in memory for the process lifetime and on disk
    /// at ~/Library/Application Support/Headroom/claude-credentials.json after the
    /// first successful read.
    public static func loadClaude(now: Date = Date()) -> ClaudeCredentials? {
        if let cached = readMemoryCache() {
            return cached
        }

        if let data = readHeadroomCredentialsFile(),
           let credentials = parseClaudeCredentials(data: data) {
            writeMemoryCache(credentials)
            return credentials
        }

        if let data = readAppKeychainCache(),
           let credentials = parseClaudeCredentials(data: data) {
            persist(credentials: credentials, rawData: data)
            return credentials
        }

        if let data = readClaudeCredentialsFile(),
           let credentials = parseClaudeCredentials(data: data) {
            persist(credentials: credentials, rawData: data)
            return credentials
        }

        guard canAttemptClaudeKeychain(now: now) else { return nil }

        if let data = readClaudeKeychainWithSecurityFramework(now: now),
           let credentials = parseClaudeCredentials(data: data) {
            persist(credentials: credentials, rawData: data)
            return credentials
        }

        return nil
    }

    /// Re-read Claude Code's keychain item and refresh the on-disk cache. Intended
    /// for use after the API rejects an expired token, not on every refresh tick.
    public static func reloadClaudeFromKeychain(now: Date = Date()) -> ClaudeCredentials? {
        guard canAttemptClaudeKeychain(now: now) else { return nil }
        guard let data = readClaudeKeychainWithSecurityFramework(now: now),
              let credentials = parseClaudeCredentials(data: data)
        else { return nil }
        persist(credentials: credentials, rawData: data)
        return credentials
    }

    static func parseClaudeCredentials(data: Data) -> ClaudeCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let rawAccess = oauth["accessToken"] as? String
        else { return nil }
        let access = rawAccess.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty else { return nil }

        let expiresAt: Date?
        if let raw = oauth["expiresAt"] as? Double {
            expiresAt = dateFromClaudeExpiry(raw)
        } else if let raw = oauth["expiresAt"] as? Int {
            expiresAt = dateFromClaudeExpiry(Double(raw))
        } else if let raw = oauth["expiresAt"] as? String {
            expiresAt = parseISO8601(raw)
        } else {
            expiresAt = nil
        }

        return ClaudeCredentials(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    static func headroomCredentialsFileURL(
        fileManager: FileManager = .default
    ) -> URL {
        if let override = headroomCredentialsFileURLOverride {
            return override
        }
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Headroom", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(credentialsFileName)
    }

    private static func persist(credentials: ClaudeCredentials, rawData: Data) {
        writeMemoryCache(credentials)
        writeHeadroomCredentialsFile(rawData)
    }

    private static func readMemoryCache() -> ClaudeCredentials? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return memoryCredentials
    }

    private static func writeMemoryCache(_ credentials: ClaudeCredentials) {
        memoryLock.lock()
        memoryCredentials = credentials
        memoryLock.unlock()
    }

    private static func readHeadroomCredentialsFile(
        fileManager: FileManager = .default
    ) -> Data? {
        let url = headroomCredentialsFileURL(fileManager: fileManager)
        return try? Data(contentsOf: url)
    }

    private static func writeHeadroomCredentialsFile(_ data: Data) {
        let url = headroomCredentialsFileURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private static func readClaudeCredentialsFile() -> Data? {
        let url = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    private static func readAppKeychainCache() -> Data? {
        var result: CFTypeRef?
        var query = appCacheIdentityQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func appCacheIdentityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount
        ]
    }

    private static func readClaudeKeychainWithSecurityFramework(now: Date) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNoAccessForItem:
            recordClaudeKeychainDenied(now: now)
            return nil
        default:
            return nil
        }
    }

    private static func canAttemptClaudeKeychain(now: Date) -> Bool {
        guard let raw = UserDefaults.standard.object(forKey: deniedUntilKey) as? Double else {
            return true
        }
        let deniedUntil = Date(timeIntervalSince1970: raw)
        if deniedUntil > now { return false }
        UserDefaults.standard.removeObject(forKey: deniedUntilKey)
        return true
    }

    private static func recordClaudeKeychainDenied(now: Date) {
        let deniedUntil = now.addingTimeInterval(denialCooldown)
        UserDefaults.standard.set(deniedUntil.timeIntervalSince1970, forKey: deniedUntilKey)
    }

    private static func dateFromClaudeExpiry(_ raw: Double) -> Date {
        // Claude stores milliseconds, but accepting seconds keeps old/local fixtures usable.
        let seconds = raw > 10_000_000_000 ? raw / 1000.0 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}
