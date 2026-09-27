import Foundation

/// Talks to the LithosAI console API using the browser's session cookies.
///
/// The console is authenticated by a session cookie plus a CSRF header; there
/// is no public usage API keyed by the inference token, so this mirrors what
/// the web console itself does.
struct LithosAIClient {
    static let baseURL = URL(string: "https://console.lithosai.cloud")!

    let jar: Browser.CookieJar
    var organizationID: String?

    enum APIError: LocalizedError {
        case http(Int, String)
        case unauthenticated
        case decoding(String)

        var errorDescription: String? {
            switch self {
            case .unauthenticated:
                return "Session expired. Sign in again at console.lithosai.cloud."
            case .http(let code, let body):
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return "Request failed (\(code))\(trimmed.isEmpty ? "" : ": \(trimmed.prefix(160))")"
            case .decoding(let detail):
                return "Unexpected response: \(detail)"
            }
        }
    }

    // MARK: - Wire types

    /// Console money is integer nanocents of a cent: the console treats
    /// values below 1e7 as "less than $0.01", so 1e7 nanos = 1 cent and
    /// 1 USD = 100 * 1e7 = 1e9.
    private static let nanocentsPerDollar: Double = 1_000_000_000

    static func dollars(fromNanos nanos: Int64) -> Double {
        Double(nanos) / nanocentsPerDollar
    }

    struct Billing: Decodable {
        let balanceNanos: Int64
        let hasCard: Bool
        let onHold: Bool

        var balance: Double { dollars(fromNanos: balanceNanos) }
    }

    struct Limits: Decodable {
        struct Limit: Decodable {
            let displayName: String
            let modelId: String
            let rpm: Int
            let inputTpm: Int
            let outputTpm: Int
        }
        let limits: [Limit]
    }

    struct SpendReport: Decodable {
        struct Day: Decodable {
            let day: String
            let modelId: String
            let nanos: Int64
            let inputTokens: Int64
            let cachedTokens: Int64
            let outputTokens: Int64

            var cost: Double { dollars(fromNanos: nanos) }
            var totalTokens: Int64 { inputTokens + cachedTokens + outputTokens }
        }
        let days: [Day]
        let start: String
        let end: String
    }

    struct Me: Decodable {
        struct Organization: Decodable {
            let id: String
            let name: String
        }
        struct User: Decodable {
            let email: String
            let givenName: String?
        }
        let activeOrganization: Organization?
        let user: User
    }

    /// A single flattened day for display.
    struct DayTotal: Identifiable {
        let day: String
        let cost: Double
        let inputTokens: Int64
        let cachedTokens: Int64
        let outputTokens: Int64
        var id: String { day }
        var totalTokens: Int64 { inputTokens + cachedTokens + outputTokens }
    }

    /// Per-model rollup across the queried range.
    struct ModelTotal: Identifiable {
        let modelId: String
        let cost: Double
        let inputTokens: Int64
        let cachedTokens: Int64
        let outputTokens: Int64
        var id: String { modelId }
        var totalTokens: Int64 { inputTokens + cachedTokens + outputTokens }

        var displayName: String {
            // Model ids look like "deepseek-ai/DeepSeek-V4.1-Flash"; strip the
            // vendor slug and keep the model's own name, which already carries
            // the provider ("DeepSeek V4.1 Flash").
            let withoutVendor = modelId.split(separator: "/").last.map(String.init) ?? modelId
            return withoutVendor
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }
    }

    // MARK: - Requests

    private func request(path: String) async throws -> Data {
        // Split any query off first; appendingPathComponent would escape it.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let route = String(parts[0])
        let query = parts.count > 1 ? String(parts[1]) : nil

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent(route),
            resolvingAgainstBaseURL: false
        )
        components?.percentEncodedQuery = query
        guard let url = components?.url else {
            throw APIError.decoding("bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        var cookies = ["__Host-console_session=\(jar.session)"]
        if !jar.csrf.isEmpty { cookies.append("__Host-console_csrf=\(jar.csrf)") }
        request.setValue(cookies.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        if !jar.csrf.isEmpty {
            request.setValue(jar.csrf, forHTTPHeaderField: "X-Console-Csrf")
        }
        if let org = organizationID {
            request.setValue(org, forHTTPHeaderField: "X-Organization-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.decoding("no HTTP response")
        }
        if http.statusCode == 401 { throw APIError.unauthenticated }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from path: String) async throws -> T {
        let data = try await request(path: path)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    func me() async throws -> Me {
        try await decode(Me.self, from: "/api/me")
    }

    func billing() async throws -> Billing {
        try await decode(Billing.self, from: "/api/billing")
    }

    func limits() async throws -> Limits {
        try await decode(Limits.self, from: "/api/limits")
    }

    func spend(days: Int = 30) async throws -> SpendReport {
        let calendar = Calendar.current
        let end = Date()
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let query = "start=\(formatter.string(from: start))&end=\(formatter.string(from: end))"
        return try await decode(SpendReport.self, from: "/api/billing/spend?\(query)")
    }

    // MARK: - Aggregation

    static func dayTotals(from report: SpendReport) -> [DayTotal] {
        var byDay: [String: (cost: Double, input: Int64, cached: Int64, output: Int64)] = [:]
        for entry in report.days {
            var current = byDay[entry.day] ?? (0, 0, 0, 0)
            current.cost += entry.cost
            current.input += entry.inputTokens
            current.cached += entry.cachedTokens
            current.output += entry.outputTokens
            byDay[entry.day] = current
        }
        return byDay
            .map { DayTotal(day: $0.key, cost: $0.value.cost,
                            inputTokens: $0.value.input, cachedTokens: $0.value.cached,
                            outputTokens: $0.value.output) }
            .sorted { $0.day < $1.day }
    }

    static func modelTotals(from report: SpendReport) -> [ModelTotal] {
        var byModel: [String: (cost: Double, input: Int64, cached: Int64, output: Int64)] = [:]
        for entry in report.days {
            var current = byModel[entry.modelId] ?? (0, 0, 0, 0)
            current.cost += entry.cost
            current.input += entry.inputTokens
            current.cached += entry.cachedTokens
            current.output += entry.outputTokens
            byModel[entry.modelId] = current
        }
        return byModel
            .map { ModelTotal(modelId: $0.key, cost: $0.value.cost,
                              inputTokens: $0.value.input, cachedTokens: $0.value.cached,
                              outputTokens: $0.value.output) }
            .sorted { $0.cost > $1.cost }
    }

    static func today(_ totals: [DayTotal]) -> DayTotal? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return totals.first { $0.day == formatter.string(from: Date()) }
    }
}

extension Int64 {
    /// Compact token display: 1.2M, 934K.
    var compactTokens: String {
        let value = Double(self)
        switch abs(value) {
        case 1_000_000...: return String(format: "%.2fM", value / 1_000_000)
        case 1_000...: return String(format: "%.1fK", value / 1_000)
        default: return "\(self)"
        }
    }
}