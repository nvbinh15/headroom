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

        public init(utilization: Double?, resets_at: Date?) {
            self.utilization = utilization
            self.resets_at = resets_at
        }

        enum CodingKeys: String, CodingKey {
            case utilization
            case resets_at
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? c.decodeIfPresent(Double.self, forKey: .utilization) {
                self.utilization = value
            } else if let value = try? c.decodeIfPresent(Int.self, forKey: .utilization) {
                self.utilization = Double(value)
            } else {
                self.utilization = nil
            }

            if let date = try? c.decodeIfPresent(Date.self, forKey: .resets_at) {
                self.resets_at = date
            } else if let string = try? c.decodeIfPresent(String.self, forKey: .resets_at) {
                self.resets_at = Self.parseDate(string)
            } else if let seconds = try? c.decodeIfPresent(Double.self, forKey: .resets_at) {
                self.resets_at = Date(timeIntervalSince1970: seconds)
            } else {
                self.resets_at = nil
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(utilization, forKey: .utilization)
            try c.encodeIfPresent(resets_at, forKey: .resets_at)
        }

        private static func parseDate(_ string: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        }
    }

    public struct Response: Codable, Sendable {
        public let five_hour: Bucket?
        public let seven_day: Bucket?
        public let seven_day_oauth_apps: Bucket?
        public let seven_day_opus: Bucket?
        public let seven_day_sonnet: Bucket?
        public let seven_day_design: Bucket?
        public let seven_day_routines: Bucket?
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
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

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
