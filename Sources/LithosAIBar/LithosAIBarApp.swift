import SwiftUI
import AppKit
import ServiceManagement

@main
struct LithosAIBarApp: App {
    @State private var store = UsageStore()
    @State private var timer: Timer?

    /// `--verify` runs the data path headlessly instead of showing the menu bar.
    /// `--render-popover <path>` writes the dropdown to a PNG for layout checks.
    /// `--install-login-item` registers the app to start at login.
    init() {
        if CommandLine.arguments.contains("--verify") {
            Task {
                let code = await VerifyCLI.run()
                exit(code)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render-popover"),
           index + 1 < CommandLine.arguments.count {
            let output = CommandLine.arguments[index + 1]
            let forceSample = CommandLine.arguments.contains("--sample")
            Task {
                let code = await PopoverRender.run(outputPath: output, forceSample: forceSample)
                exit(code)
            }
        }
        if CommandLine.arguments.contains("--install-login-item") {
            LoginItem.install()
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            MenuBarLabel(store: store)
                .task {
                    await store.refresh()
                    startTimer()
                }
        }
        .menuBarExtraStyle(.window)
    }

    /// Menu bar apps have no run loop of their own for this, so poll on a timer.
    /// 5 minutes keeps the balance current without hammering the console.
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await store.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// The menu bar item: the provider mark followed by a compact figure, the way
/// CodexBar presents a provider. The mark is a template image, so macOS tints it
/// to match the menu bar in light and dark appearance alike.
struct MenuBarLabel: View {
    let store: UsageStore

    var body: some View {
        HStack(spacing: 3) {
            if let icon = Brand.menuBarIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
            Text(store.menuBarValue)
                .monospacedDigit()
        }
        .help(store.tooltip)
    }
}

/// Registers the app as a login item using the modern service API, so it shows
/// up in System Settings → General → Login Items and can be removed there.
enum LoginItem {
    static func install() {
        do {
            if SMAppService.mainApp.status == .enabled {
                print("login item already enabled")
                return
            }
            try SMAppService.mainApp.register()
            print("login item enabled")
        } catch {
            print("login item failed: \(error.localizedDescription)")
        }
    }
}

/// Bundled artwork. Kept in one place so the views stay declarative.
enum Brand {
    /// Template image: black pixels with alpha, tinted by the system.
    static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }()
}