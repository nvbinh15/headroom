import Foundation

/// Hits GET https://api.anthropic.com/api/oauth/usage — the same endpoint the
/// `/usage` slash command calls internally. Heavily rate-limited (429s for hours
/// when overused), so callers must throttle to no more than a few times per hour.
public struct OAuthUsageClient: Sendable {
    public let baseURL: URL
    public let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public struct Bucket: Codable, Sendable {
        public let utilization: Double?
        public let resets_at: Date?
    }

    public struct Response: Codable, Sendable {
        public let five_hour: Bucket?
        public let seven_day: Bucket?
        public let seven_day_opus: Bucket?
        public let seven_day_sonnet: Bucket?
    }

    public enum FetchError: Error {
        case http(Int)
        case decode(Error)
        case network(Error)
    }

    public func fetch(token: String) async -> Result<Response, FetchError> {
        var req = URLRequest(url: baseURL.appendingPathComponent("/api/oauth/usage"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
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
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let decoded = try decoder.decode(Response.self, from: data)
                return .success(decoded)
            } catch {
                return .failure(.decode(error))
            }
        } catch {
            return .failure(.network(error))
        }
    }
}
