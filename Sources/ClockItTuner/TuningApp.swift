import AppKit
import SwiftUI

@main
struct TuningApp: App {
    @NSApplicationDelegateAdaptor(TunerAppDelegate.self) private var delegate

    var body: some Scene {
        Window("ClockIt — gesture tuning", id: "main") {
            TuningView()
        }
        // Not .contentSize: the panel scrolls now, and a fixed-to-content
        // window can end up taller than the screen on a laptop.
        .windowResizability(.contentMinSize)
    }
}

/// `swift run ClockItTuner` produces an unbundled binary, which AppKit
/// launches with no Dock presence — the window opens behind your terminal, or
/// appears not to open at all. Two lines fix it, and the tuner is throwaway
/// enough that it will never be bundled properly.
///
/// Camera permission for an unbundled binary is attributed to the process that
/// launched it, so this inherits Terminal's (or your IDE's) camera grant. If
/// the preview stays black, that grant is what's missing — not the code.
final class TunerAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
