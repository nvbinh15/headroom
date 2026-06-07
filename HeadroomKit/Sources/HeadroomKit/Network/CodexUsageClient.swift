import Foundation

/// Hits the same endpoint Codex's TUI calls on launch:
/// `GET https://chatgpt.com/backend-api/wham/usage` with the OAuth bearer
/// token from `~/.codex/auth.json` and the `ChatGPT-Account-Id` header.
public struct CodexUsageClient: Sendable {
    public let baseURL: URL
    public let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Response

    public struct Window: Codable, Sendable {
        public let used_percent: Double?
        public let limit_window_seconds: Int?
        public let reset_after_seconds: Int?
        public let reset_at: Double?
    }

    public struct RateLimit: Codable, Sendable {
        public let primary_window: Window?
        public let secondary_window: Window?
    }

    public struct AdditionalLimit: Codable, Sendable {
        public let limit_name: String?
        public let metered_feature: String?
        public let rate_limit: RateLimit?
    }

    public struct Response: Codable, Sendable {
        public let plan_type: String?
        public let rate_limit: RateLimit?
        public let additional_rate_limits: [AdditionalLimit]?
    }

    public enum FetchError: Error {
        case missingAuth
        case http(Int)
        case decode(Error)
        case network(Error)
    }

    public func fetch(auth: CodexAuth) async -> Result<Response, FetchError> {
        var req = URLRequest(url: baseURL.appendingPathComponent("/wham/usage"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = auth.accountID {
            req.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        req.setValue("codex_cli_rs/widget", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .failure(.http(0))
            }
            guard (200..<300).contains(http.statusCode) else {
                return .failure(.http(http.statusCode))
            }
            do {
                let decoded = try JSONDecoder().decode(Response.self, from: data)
                return .success(decoded)
            } catch {
                return .failure(.decode(error))
            }
        } catch {
            return .failure(.network(error))
        }
    }
}

/// Parsed `~/.codex/auth.json` — Codex stores OAuth tokens in a plain file
/// (no keychain) under the user's home dir.
public struct CodexAuth: Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let idToken: String?
    public let accountID: String?
    public let planType: String?
    public let lastRefresh: Date?
    public let authFileURL: URL

    public var canRefresh: Bool {
        !(refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public func needsRefresh(now: Date = Date()) -> Bool {
        guard canRefresh else { return false }
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) > 8 * 24 * 60 * 60
    }

    public static func codexHome(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public static func loadDefault(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> CodexAuth? {
        let url = codexHome(env: env).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data, authFileURL: url)
    }

    static func parse(data: Data, authFileURL: URL) -> CodexAuth? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let rawAPIKey = json["OPENAI_API_KEY"] as? String {
            let apiKey = rawAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !apiKey.isEmpty {
                return CodexAuth(
                    accessToken: apiKey,
                    refreshToken: nil,
                    idToken: nil,
                    accountID: nil,
                    planType: nil,
                    lastRefresh: nil,
                    authFileURL: authFileURL
                )
            }
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let access = stringValue(in: tokens, snakeCaseKey: "access_token", camelCaseKey: "accessToken")
        else { return nil }
        // plan_type lives inside the JWT but Codex also surfaces it via /wham/usage,
        // so we don't bother parsing the JWT here.
        return CodexAuth(
            accessToken: access,
            refreshToken: stringValue(in: tokens, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken"),
            idToken: stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken"),
            accountID: stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId"),
            planType: nil,
            lastRefresh: parseLastRefresh(json["last_refresh"]),
            authFileURL: authFileURL
        )
    }

    public func save() throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: authFileURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var tokens: [String: Any] = [
            "access_token": accessToken
        ]
        if let refreshToken { tokens["refresh_token"] = refreshToken }
        if let idToken { tokens["id_token"] = idToken }
        if let accountID { tokens["account_id"] = accountID }

        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: lastRefresh ?? Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: authFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: authFileURL, options: .atomic)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String
    ) -> String? {
        if let value = dictionary[snakeCaseKey] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let value = dictionary[camelCaseKey] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func parseLastRefresh(_ raw: Any?) -> Date? {
        guard let string = raw as? String, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

public enum CodexTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public enum RefreshError: Error, Sendable {
        case missingRefreshToken
        case http(Int)
        case invalidResponse
        case network(Error)
    }

    public static func refresh(_ auth: CodexAuth, session: URLSession = .shared) async throws -> CodexAuth {
        guard let refreshToken = auth.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RefreshError.missingRefreshToken
        }

        var req = URLRequest(url: refreshEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ])

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw RefreshError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RefreshError.http(http.statusCode)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RefreshError.invalidResponse
            }

            return CodexAuth(
                accessToken: json["access_token"] as? String ?? auth.accessToken,
                refreshToken: json["refresh_token"] as? String ?? auth.refreshToken,
                idToken: json["id_token"] as? String ?? auth.idToken,
                accountID: auth.accountID,
                planType: auth.planType,
                lastRefresh: Date(),
                authFileURL: auth.authFileURL
            )
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.network(error)
        }
    }
}
