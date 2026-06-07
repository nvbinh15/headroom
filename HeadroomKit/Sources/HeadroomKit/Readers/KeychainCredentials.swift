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
    private static let deniedUntilKey = "HeadroomClaudeKeychainDeniedUntil"
    private static let denialCooldown: TimeInterval = 6 * 60 * 60
    private static let memoryTTL: TimeInterval = 30 * 60

    private static let memoryLock = NSLock()
    private nonisolated(unsafe) static var memoryCredentials: ClaudeCredentials?
    private nonisolated(unsafe) static var memoryStoredAt: Date?

    /// Reads the OAuth blob Claude Code writes to the macOS keychain under
    /// service "Claude Code-credentials". Returns nil if not present (e.g.
    /// when running in a sandbox without keychain access, or a fresh login
    /// hasn't happened yet).
    public static func loadClaude(now: Date = Date()) -> ClaudeCredentials? {
        if let cached = readMemoryCache(now: now) {
            return cached
        }

        if let data = readAppKeychainCache(),
           let cached = parseClaudeCredentials(data: data) {
            writeMemoryCache(cached, now: now)
            return cached
        }

        if let data = readClaudeCredentialsFile(),
           let credentials = parseClaudeCredentials(data: data) {
            cache(credentials: credentials, data: data, now: now)
            return credentials
        }

        guard canAttemptClaudeKeychain(now: now) else { return nil }

        if let data = readClaudeKeychainWithSecurityCLI(),
           let credentials = parseClaudeCredentials(data: data) {
            cache(credentials: credentials, data: data, now: now)
            return credentials
        }

        if let data = readClaudeKeychainWithSecurityFramework(now: now),
           let credentials = parseClaudeCredentials(data: data) {
            cache(credentials: credentials, data: data, now: now)
            return credentials
        }

        return nil
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

    private static func cache(credentials: ClaudeCredentials, data: Data, now: Date) {
        writeMemoryCache(credentials, now: now)
        writeAppKeychainCache(data)
    }

    private static func readMemoryCache(now: Date) -> ClaudeCredentials? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        guard let credentials = memoryCredentials,
              let storedAt = memoryStoredAt,
              now.timeIntervalSince(storedAt) < memoryTTL,
              !credentials.isExpired(now: now)
        else { return nil }
        return credentials
    }

    private static func writeMemoryCache(_ credentials: ClaudeCredentials, now: Date) {
        memoryLock.lock()
        memoryCredentials = credentials
        memoryStoredAt = now
        memoryLock.unlock()
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

    private static func writeAppKeychainCache(_ data: Data) {
        let query = appCacheIdentityQuery()
        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        _ = SecItemAdd(add as CFDictionary, nil)
    }

    private static func appCacheIdentityQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: cacheAccount
        ]
    }

    private static func readClaudeKeychainWithSecurityCLI(timeout: TimeInterval = 1.5) -> Data? {
        let security = "/usr/bin/security"
        guard FileManager.default.isExecutableFile(atPath: security) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: security)
        process.arguments = ["find-generic-password", "-s", claudeService, "-w"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.standardInput = nil

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        guard !process.isRunning else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        var data = stdout.fileHandleForReading.readDataToEndOfFile()
        while let last = data.last, last == 0x0A || last == 0x0D {
            data.removeLast()
        }
        return data.isEmpty ? nil : data
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
