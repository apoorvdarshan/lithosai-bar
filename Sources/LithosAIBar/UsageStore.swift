import Foundation
import Observation

/// Currency formatting shared by the UI and the headless verifier.
/// Kept outside the actor so it is callable from any context.
enum Money {
    static func dollars(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Sub-dollar amounts need more precision to be meaningful.
    static func precise(_ value: Double) -> String {
        value != 0 && abs(value) < 1 ? String(format: "%.4f", value) : String(format: "%.2f", value)
    }
}

/// Owns the refresh loop and exposes display-ready state to the menu bar.
@MainActor
@Observable
final class UsageStore {
    enum State {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// How the month bar reads. `.spent` fills as spend grows; `.remaining`
    /// drains toward zero as credit is used, for people who think of the
    /// balance as the thing being consumed.
    enum BarDirection: String {
        case spent
        case remaining

        var toggled: BarDirection { self == .spent ? .remaining : .spent }
    }

    private static let barDirectionKey = "barDirection"

    var barDirection: BarDirection {
        didSet {
            UserDefaults.standard.set(barDirection.rawValue, forKey: Self.barDirectionKey)
        }
    }

    private(set) var state: State = .idle
    private(set) var balance: Double = 0
    private(set) var todayCost: Double = 0
    private(set) var todayTokens: Int64 = 0
    private(set) var todayInput: Int64 = 0
    private(set) var todayCached: Int64 = 0
    private(set) var todayOutput: Int64 = 0
    private(set) var monthCost: Double = 0
    private(set) var monthTokens: Int64 = 0
    private(set) var dailyTotals: [LithosAIClient.DayTotal] = []
    private(set) var modelTotals: [LithosAIClient.ModelTotal] = []
    private(set) var lastUpdated: Date?
    private(set) var browserName: String = "—"
    private(set) var accountEmail: String = ""
    private(set) var keychainStatus: String = "not attempted"
    private(set) var needsFullDiskAccess = false

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.barDirectionKey)
        barDirection = stored.flatMap(BarDirection.init(rawValue:)) ?? .spent
    }

    /// Menu bar title. The mark sits beside this, so keep it terse: a compact
/// balance, and a warning glyph when the session cannot be read.
    var menuBarValue: String {
        switch state {
        case .failed: return "!"
        case .loading, .idle: return "…"
        case .loaded: return "$" + Money.dollars(menuBarAmount)
        }
    }

    /// The figure beside the mark. Matches the bar's reading: `.remaining` shows
    /// the balance still available, `.spent` shows what this month has cost so
    /// far, so the menu bar and the dropdown tell the same story.
    var menuBarAmount: Double {
        switch barDirection {
        case .remaining: return max(balance, 0)
        case .spent: return monthCost
        }
    }

    var tooltip: String {
        switch state {
        case .failed(let message): return "LithosAI: \(message)"
        case .loading, .idle: return "LithosAI: refreshing…"
        case .loaded:
            let reading = barDirection == .spent ? "spent this month" : "balance"
            return "LithosAI — \(reading) $\(Money.dollars(menuBarAmount)), today $\(Money.precise(todayCost))"
        }
    }

    static func money(_ value: Double) -> String { Money.dollars(value) }
    static func moneyPrecise(_ value: Double) -> String { Money.precise(value) }

    /// Seeds the store with sample values for the layout renderer. Only the
    /// preview path calls this; live refreshes overwrite everything.
    func applyPreview(
        balance: Double,
        today: LithosAIClient.DayTotal?,
        daily: [LithosAIClient.DayTotal],
        models: [LithosAIClient.ModelTotal],
        email: String
    ) {
        self.balance = balance
        self.dailyTotals = daily
        self.modelTotals = models
        self.browserName = "Brave"
        self.accountEmail = email
        self.keychainStatus = "read ok (Brave)"
        self.todayCost = today?.cost ?? 0
        self.todayTokens = today?.totalTokens ?? 0
        self.todayInput = today?.inputTokens ?? 0
        self.todayCached = today?.cachedTokens ?? 0
        self.todayOutput = today?.outputTokens ?? 0
        let monthPrefix = String(daily.last?.day.prefix(7) ?? "")
        let monthDays = daily.filter { $0.day.hasPrefix(monthPrefix) }
        self.monthCost = monthDays.reduce(0) { $0 + $1.cost }
        self.monthTokens = monthDays.reduce(0) { $0 + $1.totalTokens }
        self.lastUpdated = Date()
        self.state = .loaded
    }

    func refresh() async {
        if case .loaded = state {} else { state = .loading }
        do {
            let jar = try Browser.loadConsoleCookies()
            keychainStatus = "read ok (\(jar.browserName))"
            let client = LithosAIClient(jar: jar)

            // /api/me gives the active organization, which the billing and
            // spend endpoints expect on the X-Organization-Id header.
            let me = try await client.me()
            let scoped = LithosAIClient(jar: jar, organizationID: me.activeOrganization?.id)

            async let billing = scoped.billing()
            async let report = scoped.spend(days: 30)

            let (billingResult, reportResult) = try await (billing, report)
            let days = LithosAIClient.dayTotals(from: reportResult)
            let models = LithosAIClient.modelTotals(from: reportResult)
            let today = LithosAIClient.today(days)
            let monthPrefix = String(reportResult.end.prefix(7))

            balance = billingResult.balance
            dailyTotals = days
            modelTotals = models
            browserName = jar.browserName
            accountEmail = me.user.email
            todayCost = today?.cost ?? 0
            todayTokens = today?.totalTokens ?? 0
            todayInput = today?.inputTokens ?? 0
            todayCached = today?.cachedTokens ?? 0
            todayOutput = today?.outputTokens ?? 0

            let monthDays = days.filter { $0.day.hasPrefix(monthPrefix) }
            monthCost = monthDays.reduce(0) { $0 + $1.cost }
            monthTokens = monthDays.reduce(0) { $0 + $1.totalTokens }
            lastUpdated = Date()
            needsFullDiskAccess = false
            state = .loaded
        } catch {
            let message = error.localizedDescription
            needsFullDiskAccess = message.localizedCaseInsensitiveContains("authorization denied")
                || message.localizedCaseInsensitiveContains("don’t have permission")
                || message.localizedCaseInsensitiveContains("operation not permitted")
            if keychainStatus == "not attempted" {
                keychainStatus = "FAILED — \(message)"
            }
            Log.write("refresh failed: \(message)")
            state = .failed(message)
        }
    }
}