import Foundation
import Security
import SQLite3

public struct CursorCredentials: Sendable {
    public enum Source: Sendable {
        case sqlite(URL)
        case keychain
    }

    public let accessToken: String
    public let refreshToken: String?
    public let membershipType: String?
    public let source: Source

    public var canRefresh: Bool {
        !(refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public func isExpired(leeway: TimeInterval = 60, now: Date = Date()) -> Bool {
        guard let exp = CursorCredentialsLoader.jwtExpiryDate(accessToken) else { return false }
        return exp <= now.addingTimeInterval(leeway)
    }

    public func needsRefresh(now: Date = Date()) -> Bool {
        guard canRefresh else { return false }
        return isExpired(now: now)
    }
}

public enum CursorCredentialsLoader {
    private static let accessTokenKey = "cursorAuth/accessToken"
    private static let refreshTokenKey = "cursorAuth/refreshToken"
    private static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    private static let keychainAccessService = "cursor-access-token"
    private static let keychainRefreshService = "cursor-refresh-token"

    public static func defaultStateDatabaseURL(
        fileManager: FileManager = .default
    ) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    public static func cursorAppSupportExists(
        fileManager: FileManager = .default
    ) -> Bool {
        let dir = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
        return fileManager.fileExists(atPath: dir.path)
    }

    public static func load(
        stateDatabaseURL: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> CursorCredentials? {
        let dbURL = stateDatabaseURL ?? defaultStateDatabaseURL(fileManager: fileManager)
        if let sqlite = loadFromSQLite(at: dbURL) {
            return sqlite
        }
        return loadFromKeychain()
    }

    public static func save(_ credentials: CursorCredentials) throws {
        switch credentials.source {
        case .sqlite(let url):
            try writeSQLiteValue(credentials.accessToken, key: accessTokenKey, at: url)
            if let refreshToken = credentials.refreshToken {
                try writeSQLiteValue(refreshToken, key: refreshTokenKey, at: url)
            }
        case .keychain:
            try writeKeychainValue(credentials.accessToken, service: keychainAccessService)
            if let refreshToken = credentials.refreshToken {
                try writeKeychainValue(refreshToken, service: keychainRefreshService)
            }
        }
    }

    static func loadFromSQLite(at url: URL) -> CursorCredentials? {
        guard let accessToken = readSQLiteValue(key: accessTokenKey, at: url)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else { return nil }

        return CursorCredentials(
            accessToken: accessToken,
            refreshToken: readSQLiteValue(key: refreshTokenKey, at: url),
            membershipType: readSQLiteValue(key: membershipTypeKey, at: url),
            source: .sqlite(url)
        )
    }

    static func loadFromKeychain() -> CursorCredentials? {
        guard let accessToken = readKeychainValue(service: keychainAccessService)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty
        else { return nil }

        return CursorCredentials(
            accessToken: accessToken,
            refreshToken: readKeychainValue(service: keychainRefreshService),
            membershipType: nil,
            source: .keychain
        )
    }

    static func readSQLiteValue(key: String, at url: URL) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let db
        else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0)
        else { return nil }

        return String(cString: cString)
    }

    static func writeSQLiteValue(_ value: String, key: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let db
        else {
            throw CursorCredentialsError.sqliteOpenFailed
        }
        defer { sqlite3_close(db) }

        let updateSQL = "UPDATE ItemTable SET value = ? WHERE key = ?;"
        var updateStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK,
              let updateStatement
        else {
            throw CursorCredentialsError.sqliteWriteFailed
        }
        defer { sqlite3_finalize(updateStatement) }

        sqlite3_bind_text(updateStatement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(updateStatement, 2, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(updateStatement) == SQLITE_DONE, sqlite3_changes(db) > 0 {
            return
        }

        let insertSQL = "INSERT INTO ItemTable (key, value) VALUES (?, ?);"
        var insertStatement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK,
              let insertStatement
        else {
            throw CursorCredentialsError.sqliteWriteFailed
        }
        defer { sqlite3_finalize(insertStatement) }

        sqlite3_bind_text(insertStatement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_text(insertStatement, 2, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(insertStatement) == SQLITE_DONE else {
            throw CursorCredentialsError.sqliteWriteFailed
        }
    }

    static func readKeychainValue(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeKeychainValue(_ value: String, service: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        let update: [String: Any] = [
            kSecValueData as String: data
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else {
            throw CursorCredentialsError.keychainWriteFailed
        }
    }

    static func jwtExpiryDate(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - payload.count % 4) % 4
        payload += String(repeating: "=", count: padding)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? Double
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

public enum CursorCredentialsError: Error {
    case sqliteOpenFailed
    case sqliteWriteFailed
    case keychainWriteFailed
}
