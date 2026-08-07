import AppKit
import ApplicationServices

/// Types text into whatever app has focus.
///
/// Deliberately does NOT synthesize Cmd+V. Pasting clobbers the user's
/// clipboard and breaks in apps with their own paste handling; posting Unicode
/// keystrokes works in native apps, Electron, web views, and terminals alike.
/// A copy still lands on the pasteboard as a safety net.
enum TextInjector {

    /// `keyboardSetUnicodeString` is reliable up to about 20 UTF-16 units per
    /// event, so long transcripts go out in chunks.
    private static let chunkSize = 20

    /// Small gap between events. Without it, fast apps drop characters.
    private static let interChunkDelay: TimeInterval = 0.002

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    /// Opens System Settings at the Accessibility pane if permission is missing.
    @discardableResult
    static func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// - Returns: `false` if Accessibility isn't granted. Text is on the
    ///   clipboard either way, so the user can always paste manually.
    @discardableResult
    static func deliver(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }

        copyToPasteboard(text)

        guard hasAccessibilityPermission else { return false }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }

        // Suppress local keyboard so the user's own typing can't interleave.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        for chunk in text.utf16Chunks(of: chunkSize) {
            type(chunk, source: source)
            Thread.sleep(forTimeInterval: interChunkDelay)
        }
        return true
    }

    private static func type(_ utf16: [UniChar], source: CGEventSource) {
        var units = utf16

        // virtualKey 0 with a unicode string attached: the key code is ignored,
        // the string is what gets delivered.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private extension String {
    /// Splits into UTF-16 chunks without ever cutting a surrogate pair —
    /// splitting one produces a replacement character instead of the emoji.
    func utf16Chunks(of size: Int) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []

        for scalar in unicodeScalars {
            let units = Array(String(scalar).utf16)
            if current.count + units.count > size, !current.isEmpty {
                chunks.append(current)
                current = []
            }
            current.append(contentsOf: units)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
