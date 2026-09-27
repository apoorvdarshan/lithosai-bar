import SwiftUI
import AppKit

/// Renders the popover to a PNG without opening the menu bar, so the layout can
/// be checked from a script: `LithosAIBar --render-popover out.png`.
///
/// It uses real store data when the browser session is readable, and otherwise
/// falls back to representative sample values so the layout can still be
/// inspected on a machine without a LithosAI login.
@MainActor
enum PopoverRender {
    static func run(outputPath: String) async -> Int32 {
        let store = UsageStore()
        await store.refresh()

        if case .failed(let message) = store.state {
            print("live data unavailable (\(message)); rendering sample values")
            store.applyPreviewSample()
        }

        let view = PopoverView(store: store)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2

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

extension UsageStore {
    /// Fills the store with plausible numbers so the layout can be rendered
    /// without a readable console session.
    func applyPreviewSample() {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var days: [LithosAIClient.DayTotal] = []
        for offset in stride(from: 13, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let spent = Double.random(in: 0.05...0.62)
            days.append(
                LithosAIClient.DayTotal(
                    day: formatter.string(from: date),
                    cost: spent,
                    inputTokens: Int64(Double.random(in: 2_000_000...18_000_000)),
                    cachedTokens: Int64(Double.random(in: 5_000_000...42_000_000)),
                    outputTokens: Int64(Double.random(in: 20_000...90_000))
                )
            )
        }
        let today = days.last
        applyPreview(
            balance: 4.5,
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