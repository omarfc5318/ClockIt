import AppKit
import ClockItCore

/// SwiftUI's `MenuBarExtra` needs an app bundle; an SPM executable can build a
/// status-bar app directly with AppKit and no .xcodeproj. `LSUIElement` in the
/// bundled Info.plist keeps it out of the Dock — see BUILD-PLAN.md step 6.
///
/// This target is main.swift and nothing else. Everything it drives lives in
/// ClockItCore, so the tuner and the tests can reach the same code.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let session = SessionController()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "hand.point.up.left",
            accessibilityDescription: "ClockIt"
        )
        buildMenu()
        session.start()

        // Cheap poll; swap for Combine on `session.$phase` when you add the pill.
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stop()
        timer?.invalidate()
    }

    @MainActor
    private func refreshIcon() {
        let symbol: String
        switch session.phase {
        case .idle: symbol = session.handPresent ? "hand.raised" : "hand.point.up.left"
        case .recording: symbol = session.isLatched ? "lock.fill" : "waveform"
        case .transcribing: symbol = "ellipsis"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Hold thumb to middle finger to dictate", action: nil, keyEquivalent: "")
            .isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
    }
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
