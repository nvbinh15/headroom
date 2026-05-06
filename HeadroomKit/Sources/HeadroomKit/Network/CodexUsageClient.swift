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
        req.setValue(auth.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
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
    public let accountID: String
    public let planType: String?

    public static func loadDefault() -> CodexAuth? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let tokens = json["tokens"] as? [String: Any] else { return nil }
        guard let access = tokens["access_token"] as? String,
              let acc = tokens["account_id"] as? String else { return nil }
        // plan_type lives inside the JWT but Codex also surfaces it via /wham/usage,
        // so we don't bother parsing the JWT here.
        return CodexAuth(accessToken: access, accountID: acc, planType: nil)
    }
}
