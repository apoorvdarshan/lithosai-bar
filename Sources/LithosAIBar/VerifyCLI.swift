import Foundation

/// Headless diagnostics: `LithosAIBar --verify` reads the browser session,
/// calls the console, and prints what the menu bar would show. Useful for
/// confirming the cookie/keychain path without launching the UI.
enum VerifyCLI {
    static func run() async -> Int32 {
        print("LithosAI Bar — verification")
        print("────────────────────────────")

        let jar: Browser.CookieJar
        do {
            jar = try Browser.loadConsoleCookies()
        } catch {
            print("session:   FAILED")
            print("reason:    \(error.localizedDescription)")
            return 1
        }
        print("session:   loaded from \(jar.browserName)")
        print("csrf:      \(jar.csrf.isEmpty ? "absent" : "present")")

        let client = LithosAIClient(jar: jar)
        do {
            let me = try await client.me()
            print("account:   \(me.user.email)")
            print("org:       \(me.activeOrganization?.name ?? "—")")

            let scoped = LithosAIClient(jar: jar, organizationID: me.activeOrganization?.id)
            async let billingTask = scoped.billing()
            async let reportTask = scoped.spend(days: 30)
            let (billing, report) = try await (billingTask, reportTask)

            let days = LithosAIClient.dayTotals(from: report)
            let models = LithosAIClient.modelTotals(from: report)
            let today = LithosAIClient.today(days)
            let monthPrefix = String(report.end.prefix(7))
            let monthDays = days.filter { $0.day.hasPrefix(monthPrefix) }

            print("balance:   $\(Money.dollars(billing.balance))")
            print("hasCard:   \(billing.hasCard)")
            print("today:     $\(Money.precise(today?.cost ?? 0))  " +
                  "\(today?.totalTokens.compactTokens ?? "0") tokens")
            print("month:     $\(Money.precise(monthDays.reduce(0) { $0 + $1.cost }))  " +
                  "\(monthDays.reduce(Int64(0)) { $0 + $1.totalTokens }.compactTokens) tokens")
            print("")
            print("by model (30d):")
            for model in models {
                print(String(format: "  %-34@ $%-9@ %@ tokens",
                             model.displayName as NSString,
                             Money.precise(model.cost) as NSString,
                             model.totalTokens.compactTokens as NSString))
            }
            print("")
            print("daily (last 7):")
            for day in days.suffix(7) {
                print(String(format: "  %@  $%-9@ %@ tokens",
                             day.day as NSString,
                             Money.precise(day.cost) as NSString,
                             day.totalTokens.compactTokens as NSString))
            }
            print("")
            print("menu bar would show: $\(Money.dollars(billing.balance)) (remaining)  /  " +
                  "$\(Money.precise(monthDays.reduce(0) { $0 + $1.cost })) (spent this month)")
            return 0
        } catch {
            print("api:       FAILED")
            print("reason:    \(error.localizedDescription)")
            return 1
        }
    }
}