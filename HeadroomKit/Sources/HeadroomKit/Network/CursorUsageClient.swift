import Foundation

/// Hits Cursor's undocumented dashboard usage endpoints on `api2.cursor.sh`.
public struct CursorUsageClient: Sendable {
    public let baseURL: URL
    public let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://api2.cursor.sh")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Responses

    public struct PlanUsage: Codable, Sendable {
        public let totalSpend: Double?
        public let includedSpend: Double?
        public let bonusSpend: Double?
        public let remaining: Double?
        public let limit: Double?
        public let autoPercentUsed: Double?
        public let apiPercentUsed: Double?
        public let totalPercentUsed: Double?
    }

    public struct PeriodUsageResponse: Codable, Sendable {
        public let billingCycleStart: String?
        public let billingCycleEnd: String?
        public let planUsage: PlanUsage?
        public let displayMessage: String?
    }

    public struct PlanInfoResponse: Codable, Sendable {
        public struct PlanInfo: Codable, Sendable {
            public let planName: String?
            public let includedAmountCents: Double?
            public let price: String?
            public let billingCycleEnd: String?
        }

        public let planInfo: PlanInfo?
    }

    public struct LegacyModelUsage: Codable, Sendable {
        public let numRequests: Int?
        public let maxRequestUsage: Int?
    }

    public struct LegacyUsageResponse: Codable, Sendable {
        public let startOfMonth: String?

        private struct DynamicKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        public let modelBuckets: [String: LegacyModelUsage]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicKey.self)
            var buckets: [String: LegacyModelUsage] = [:]
            var startOfMonth: String?

            for key in container.allKeys {
                if key.stringValue == "startOfMonth" {
                    startOfMonth = try container.decodeIfPresent(String.self, forKey: key)
                } else {
                    buckets[key.stringValue] = try container.decode(LegacyModelUsage.self, forKey: key)
                }
            }

            self.startOfMonth = startOfMonth
            self.modelBuckets = buckets
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: DynamicKey.self)
            if let startOfMonth {
                try container.encode(startOfMonth, forKey: DynamicKey(stringValue: "startOfMonth")!)
            }
            for (key, value) in modelBuckets {
                try container.encode(value, forKey: DynamicKey(stringValue: key)!)
            }
        }
    }

    public enum FetchError: Error, Sendable {
        case missingAuth
        case http(Int)
        case decode(Error)
        case network(Error)
        case emptyUsage
    }

    public func fetchCurrentPeriodUsage(token: String) async -> Result<PeriodUsageResponse, FetchError> {
        await postConnect(
            path: "/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
            token: token,
            body: Data("{}".utf8),
            as: PeriodUsageResponse.self
        )
    }

    public func fetchPlanInfo(token: String) async -> Result<PlanInfoResponse, FetchError> {
        await postConnect(
            path: "/aiserver.v1.DashboardService/GetPlanInfo",
            token: token,
            body: Data("{}".utf8),
            as: PlanInfoResponse.self
        )
    }

    public func fetchLegacyUsage(token: String) async -> Result<LegacyUsageResponse, FetchError> {
        var req = URLRequest(url: baseURL.appendingPathComponent("/auth/usage"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
                let decoded = try JSONDecoder().decode(LegacyUsageResponse.self, from: data)
                return .success(decoded)
            } catch {
                return .failure(.decode(error))
            }
        } catch {
            return .failure(.network(error))
        }
    }

    private func postConnect<T: Decodable>(
        path: String,
        token: String,
        body: Data,
        as type: T.Type
    ) async -> Result<T, FetchError> {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
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
                let decoded = try JSONDecoder().decode(T.self, from: data)
                return .success(decoded)
            } catch {
                return .failure(.decode(error))
            }
        } catch {
            return .failure(.network(error))
        }
    }
}

public enum CursorTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://api2.cursor.sh/oauth/token")!
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    public enum RefreshError: Error, Sendable {
        case missingRefreshToken
        case shouldLogout
        case http(Int)
        case invalidResponse
        case network(Error)
    }

    public static func refresh(
        _ credentials: CursorCredentials,
        session: URLSession = .shared
    ) async throws -> CursorCredentials {
        guard let refreshToken = credentials.refreshToken,
              !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw RefreshError.missingRefreshToken
        }

        var req = URLRequest(url: refreshEndpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
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

            if json["shouldLogout"] as? Bool == true {
                throw RefreshError.shouldLogout
            }

            guard let accessToken = json["access_token"] as? String,
                  !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw RefreshError.invalidResponse
            }

            return CursorCredentials(
                accessToken: accessToken,
                refreshToken: credentials.refreshToken,
                membershipType: credentials.membershipType,
                source: credentials.source
            )
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.network(error)
        }
    }
}

public enum CursorUsageMapper {
    public static let defaultLegacyModelKey = "gpt-4"

    public static func providerUsage(
        from period: CursorUsageClient.PeriodUsageResponse,
        planName: String?,
        membershipType: String?
    ) -> ProviderUsage? {
        guard let planUsage = period.planUsage else { return nil }

        let billingEnd = parseCursorTimestamp(period.billingCycleEnd)
        let billingStart = parseCursorTimestamp(period.billingCycleStart)
        let windowMinutes = billingWindowMinutes(start: billingStart, end: billingEnd)

        let autoFraction = planUsage.autoPercentUsed.map { $0 / 100.0 }
        let apiFraction = planUsage.apiPercentUsed.map { $0 / 100.0 }

        let autoWindow = autoFraction.map {
            WindowUsage(fraction: $0, resetsAt: billingEnd, windowMinutes: windowMinutes)
        }
        let apiWindow = apiFraction.map {
            WindowUsage(fraction: $0, resetsAt: billingEnd, windowMinutes: windowMinutes)
        }

        let displayPlan = planName
            ?? membershipType.map { $0.capitalized }
            ?? "Cursor"

        return ProviderUsage(
            fiveHour: autoWindow,
            weekly: apiWindow,
            fiveHourLabel: "Auto",
            weeklyLabel: "API",
            planLabel: displayPlan
        )
    }

    public static func providerUsage(
        from legacy: CursorUsageClient.LegacyUsageResponse,
        modelKey: String = defaultLegacyModelKey,
        membershipType: String?
    ) -> ProviderUsage? {
        let bucket = legacy.modelBuckets[modelKey]
            ?? legacy.modelBuckets.values.first { ($0.maxRequestUsage ?? 0) > 0 }
        guard let bucket,
              let used = bucket.numRequests,
              let limit = bucket.maxRequestUsage,
              limit > 0
        else { return nil }

        let fraction = Double(used) / Double(limit)
        let reset = legacy.startOfMonth.flatMap(parseISO8601)
        let windowMinutes = 30 * 24 * 60

        return ProviderUsage(
            fiveHour: WindowUsage(
                fraction: fraction,
                resetsAt: reset?.addingTimeInterval(TimeInterval(windowMinutes * 60)),
                windowMinutes: windowMinutes
            ),
            weekly: nil,
            fiveHourLabel: "Requests",
            weeklyLabel: nil,
            planLabel: membershipType?.capitalized ?? "Cursor"
        )
    }

    static func parseCursorTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let ms = Double(raw) {
            let seconds = ms > 10_000_000_000 ? ms / 1000.0 : ms
            return Date(timeIntervalSince1970: seconds)
        }
        return parseISO8601(raw)
    }

    static func billingWindowMinutes(start: Date?, end: Date?) -> Int {
        guard let start, let end, end > start else { return 30 * 24 * 60 }
        return max(Int(end.timeIntervalSince(start) / 60), 1)
    }
}
