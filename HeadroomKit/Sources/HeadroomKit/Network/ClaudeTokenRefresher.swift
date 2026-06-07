import Foundation

public enum ClaudeTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    public enum RefreshError: Error, Sendable {
        case missingRefreshToken
        case http(Int)
        case invalidResponse
        case network(Error)
    }

    public static func refresh(_ creds: ClaudeCredentials, session: URLSession = .shared) async throws -> ClaudeCredentials {
        guard let refreshToken = creds.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RefreshError.missingRefreshToken
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID)
        ]

        var req = URLRequest(url: refreshEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw RefreshError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RefreshError.http(http.statusCode)
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  !accessToken.isEmpty
            else {
                throw RefreshError.invalidResponse
            }

            let newRefresh = json["refresh_token"] as? String ?? creds.refreshToken
            let expiresAt: Date?
            if let expiresIn = json["expires_in"] as? Int {
                expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            } else if let expiresIn = json["expires_in"] as? Double {
                expiresAt = Date().addingTimeInterval(expiresIn)
            } else {
                expiresAt = creds.expiresAt
            }

            let updated = ClaudeCredentials(
                accessToken: accessToken,
                refreshToken: newRefresh,
                expiresAt: expiresAt,
                subscriptionType: creds.subscriptionType,
                rateLimitTier: creds.rateLimitTier
            )
            KeychainCredentialsLoader.persistRefreshedClaude(updated)
            return updated
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.network(error)
        }
    }
}
