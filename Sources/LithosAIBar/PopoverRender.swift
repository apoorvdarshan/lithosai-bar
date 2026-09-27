import SwiftUI
import AppKit

/// Renders the popover to a PNG without opening the menu bar, so the layout can
/// be checked from a script: `LithosAIBar --render-popover out.png`.
///
/// It uses real store data when the browser session is readable, and otherwise
/// falls back to representative sample values so the layout can still be
/// inspected on a machine without a LithosAI login. Pass `--sample` to force the
/// sample data, which is what the README screenshot uses so no real account
/// details are published.
///
/// `--render-status out.png` renders the menu bar item itself, in both readings,
/// so the figure that follows the bar toggle can be checked headlessly too.
@MainActor
enum PopoverRender {
    static func run(outputPath: String, forceSample: Bool = false) async -> Int32 {
        let store = UsageStore()
        if forceSample {
            store.applyPreviewSample()
        } else {
            await store.refresh()
            if case .failed(let message) = store.state {
                print("live data unavailable (\(message)); rendering sample values")
                store.applyPreviewSample()
            }
        }

        let view = PopoverView(store: store)
            .background(Color(nsColor: .windowBackgroundColor))

        print("menu bar: \(store.menuBarValue) (\(store.barDirection.rawValue))")

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return write(renderer, to: outputPath)
    }

    /// Renders the menu bar item on a dark strip, the way it appears at the top
    /// of the screen, with both readings shown so the toggle's effect is visible.
    /// The dark background matches the menu bar's translucent appearance.
    static func runStatus(outputPath: String, forceSample: Bool = false) async -> Int32 {
        let store = UsageStore()
        if forceSample {
            store.applyPreviewSample()
        } else {
            await store.refresh()
            if case .failed = store.state {
                store.applyPreviewSample()
            }
        }

        let strip = StatusStrip(store: store)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 3
        return write(renderer, to: outputPath)
    }

    private static func write(_ renderer: ImageRenderer<some View>, to outputPath: String) -> Int32 {
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("render failed")
            return 1
        }
        do {
            try png.write(to: URL(fileURLWithPath: outputPath))
            print("wrote \(outputPath)")
            return 0
        } catch {
            print("write failed: \(error.localizedDescription)")
            return 1
        }
    }
}

/// A mock of the menu bar's right-hand side, showing the item in both readings.
private struct StatusStrip: View {
    let store: UsageStore

    /// The debug CLI has no app bundle, so `Brand.menuBarIcon` is nil there.
    /// Fall back to the checked-in artwork so the README shot keeps the mark.
    private static let icon: NSImage? = {
        if let bundled = Brand.menuBarIcon { return bundled }
        let path = "Resources/MenuBarIcon.png"
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        return image
    }()

    var body: some View {
        HStack(spacing: 14) {
            row("Spend", .spent)
            row("Remaining", .remaining)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(red: 0.11, green: 0.11, blue: 0.12))
        .environment(\.colorScheme, .dark)
    }

    private func row(_ label: String, _ direction: UsageStore.BarDirection) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.white.opacity(0.5))
            HStack(spacing: 3) {
                if let icon = Self.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 14, height: 14)
                }
                Text(label == "Spend" ? spendValue : remainingValue)
                    .font(.system(size: 13))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
        }
    }

    /// Recomputes the two readings from the same store values the label uses, so
    /// the sample render needs no live refresh to switch direction.
    private var spendValue: String { "$" + Money.dollars(store.monthCost) }
    private var remainingValue: String { "$" + Money.dollars(max(store.balance, 0)) }
}

extension UsageStore {
    /// Fills the store with plausible numbers so the layout can be rendered
    /// without a readable console session. The values are fixed rather than
    /// random so the README screenshot is reproducible.
    func applyPreviewSample() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        // A gentle two-week pattern with a busy day in the middle.
        let spend = [0.18, 0.42, 0.31, 0.55, 0.24, 0.61, 0.38,
                     0.29, 0.47, 0.22, 0.58, 0.35, 0.44, 0.52]
        var days: [LithosAIClient.DayTotal] = []
        for (index, offset) in stride(from: 13, through: 0, by: -1).enumerated() {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let cost = spend[index % spend.count]
            days.append(
                LithosAIClient.DayTotal(
                    day: formatter.string(from: date),
                    cost: cost,
                    inputTokens: Int64(cost * 12_000_000),
                    cachedTokens: Int64(cost * 42_000_000),
                    outputTokens: Int64(cost * 130_000)
                )
            )
        }
        let today = days.last
        applyPreview(
            balance: 42.10,
            today: today,
            daily: days,
            models: [
                LithosAIClient.ModelTotal(
                    modelId: "deepseek-ai/DeepSeek-V4.1-Flash",
                    cost: 3.82, inputTokens: 61_000_000,
                    cachedTokens: 240_000_000, outputTokens: 1_200_000
                ),
                LithosAIClient.ModelTotal(
                    modelId: "moonshotai/Kimi-K3",
                    cost: 0.41, inputTokens: 4_100_000,
                    cachedTokens: 12_000_000, outputTokens: 220_000
                ),
            ],
            email: "you@example.com"
        )
    }
}