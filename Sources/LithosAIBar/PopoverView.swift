import SwiftUI
import AppKit

/// The dropdown, styled after CodexBar: a provider header, a prominent balance,
/// usage bars, then a small footer of actions.
struct PopoverView: View {
    let store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().padding(.top, 10)

            switch store.state {
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    errorBox(message)
                    diagnosticsBlock
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            default:
                VStack(alignment: .leading, spacing: 14) {
                    balanceBlock
                    usageBlock
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

            Divider()

            footer
        }
        .frame(width: 300)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = Brand.menuBarIcon {
                Image(nsImage: icon)
                    .frame(width: 16, height: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("LithosAI")
                    .font(.system(size: 13, weight: .semibold))
                Text(store.accountEmail.isEmpty ? "DeepSeek V4.1 Flash" : store.accountEmail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if case .loading = store.state {
                ProgressView().controlSize(.small)
            } else if case .loaded = store.state {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                    .help(store.lastUpdated.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    // MARK: - Balance

    private var balanceBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Balance")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text("$" + Money.dollars(store.balance))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    // MARK: - Usage

    private var usageBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            todayBlock

            // The only bar with a real ceiling: month spend measured against the
            // credit available. A ratio of two spend figures (today vs month)
            // always saturates, so it says nothing; against the balance the fill
            // is bounded. `.spent` grows with usage, `.remaining` drains.
            UsageBar(
                title: "This month",
                amount: "$" + Money.precise(store.monthCost),
                detail: "\(store.monthTokens.compactTokens) tokens",
                fill: monthBarFill,
                caption: monthBarCaption
            )

            if store.dailyTotals.count > 1 {
                SpendSparkline(values: store.dailyTotals.map(\.cost))
            }

            if !store.modelTotals.isEmpty {
                modelBlock
            }
        }
    }

    /// Today has no quota, so it is a plain figure rather than a fake-full bar.
    private var todayBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(store.todayTokens.compactTokens) tokens")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Text("$" + Money.precise(store.todayCost))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            VStack(alignment: .leading, spacing: 5) {
                Text("Tokens today")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TokenBreakdown(
                    cached: store.todayCached,
                    input: store.todayInput,
                    output: store.todayOutput
                )
            }
        }
    }

    /// Month spend plus the balance left is the credit that was available, so
    /// spend as a share of it is a bounded fraction that reflects real progress.
    private var monthSpendPlusBalance: Double {
        store.monthCost + max(store.balance, 0)
    }

    /// Fill height for the month bar. `.spent` fills up as spend grows;
    /// `.remaining` is the complement, so the bar empties as credit is consumed.
    private var monthBarFill: Double {
        guard monthSpendPlusBalance > 0 else { return 0 }
        let spent = min(store.monthCost / monthSpendPlusBalance, 1)
        switch store.barDirection {
        case .spent: return spent
        case .remaining: return 1 - spent
        }
    }

    private var monthBarCaption: String {
        switch store.barDirection {
        case .spent:
            return "of $\(Money.dollars(monthSpendPlusBalance)) used"
        case .remaining:
            return "$\(Money.dollars(max(store.balance, 0))) left"
        }
    }

    // MARK: - Models

    private var modelBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("By model · 30 days")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            ForEach(store.modelTotals.prefix(3)) { model in
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Text("$" + Money.precise(model.cost))
                        .font(.system(size: 11))
                        .monospacedDigit()
                    Text(model.totalTokens.compactTokens)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - Errors

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Could not refresh", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12, weight: .medium))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Reading another app's cookie store is gated by macOS privacy
            // protection. Full Disk Access is the grant these menu bar tools
            // need; without it the console session is unreadable.
            if store.needsFullDiskAccess {
                Text("Grant Full Disk Access to “LithosAI Bar”, then relaunch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Open Full Disk Access…") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                        )
                    }
                    Button("Relaunch") { Self.relaunch() }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var diagnosticsBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Diagnostics")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            StatRow(label: "Browser source", value: store.browserName)
            StatRow(label: "Keychain reader", value: store.keychainStatus)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            FooterButton(title: "Usage Dashboard", symbol: "chart.bar.xaxis") {
                NSWorkspace.shared.open(URL(string: "https://console.lithosai.cloud")!)
            }
            FooterToggle(
                title: "Bar shows",
                value: store.barDirection == .spent ? "Spend" : "Remaining",
                symbol: store.barDirection == .spent ? "chart.bar.fill" : "battery.50"
            ) {
                store.barDirection = store.barDirection.toggled
            }
            FooterButton(title: "Refresh", symbol: "arrow.clockwise", shortcut: "r") {
                Task { await store.refresh() }
            }
            FooterButton(title: "Quit", symbol: "power", shortcut: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }

    /// Restarts the app so a freshly granted permission takes effect.
    private static func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}

// MARK: - Reusable pieces

/// A titled bar with an amount on the right and a caption underneath, matching
/// the CodexBar treatment of a usage window. The fill should be a bounded
/// fraction — a ratio of two spend figures saturates and reads as always full.
struct UsageBar: View {
    let title: String
    let amount: String
    let detail: String
    let fill: Double
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(3, geometry.size.width * fill))
                }
            }
            .frame(height: 5)

            HStack(spacing: 6) {
                Text(amount)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let caption {
                    Text(caption)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// A compact 30-day spend trend. Where a single ratio bar cannot show "how am I
/// going", this does: bar heights are relative to the busiest day, so no
/// arbitrary ceiling is needed and the shape stays honest as volume changes.
struct SpendSparkline: View {
    /// Oldest to newest daily costs.
    let values: [Double]

    private var peak: Double { values.max() ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last 30 days")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if let last = values.last {
                    Text("$" + Money.precise(last) + " today")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            GeometryReader { geometry in
                let count = max(values.count, 1)
                let spacing: CGFloat = 2
                let barWidth = max(1, (geometry.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                        let fraction = peak > 0 ? value / peak : 0
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.35 + 0.65 * fraction))
                            .frame(width: barWidth, height: max(2, geometry.size.height * fraction))
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
            }
            .frame(height: 22)
        }
    }
}

/// A single stacked bar showing where today's tokens went. Cached, input and
/// output are all the accent hue but at clearly separated opacities, so the
/// three segments stay distinguishable in light and dark alike.
struct TokenBreakdown: View {
    let cached: Int64
    let input: Int64
    let output: Int64

    private static let cachedColor = Color.accentColor.opacity(0.3)
    private static let inputColor = Color.accentColor.opacity(0.55)
    private static let outputColor = Color.accentColor

    private var total: Double {
        Double(cached + input + output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    segment(cached, of: geometry.size.width, color: Self.cachedColor)
                    segment(input, of: geometry.size.width, color: Self.inputColor)
                    segment(output, of: geometry.size.width, color: Self.outputColor)
                }
            }
            .frame(height: 5)
            .clipShape(Capsule())
            .background(Capsule().fill(Color.secondary.opacity(0.18)))

            HStack(spacing: 10) {
                legend("Cached", cached, Self.cachedColor)
                legend("Input", input, Self.inputColor)
                legend("Output", output, Self.outputColor)
            }
        }
    }

    private func segment(_ value: Int64, of width: CGFloat, color: Color) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: total > 0 ? max(0, width * (Double(value) / total)) : 0)
    }

    private func legend(_ label: String, _ value: Int64, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value.compactTokens).font(.system(size: 9)).monospacedDigit()
        }
    }
}

/// One labelled stat row used by the diagnostics panel.
struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11))
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A full-width menu row: icon, title, optional shortcut glyph.
struct FooterButton: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                if let shortcut {
                    Text("⌘" + shortcut.uppercased())
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A footer row that cycles a two-state setting in place: label on the left,
/// current value plus a switch glyph on the right. Sits visually alongside
/// `FooterButton` so the menu reads as one list.
struct FooterToggle: View {
    let title: String
    let value: String
    let symbol: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}