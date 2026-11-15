import AppKit
import ApplicationServices

/// Types text into whatever text field has focus in the front app: first through Accessibility
/// (inserts at the caret), and if the app ignores that (many web and Electron apps do), through
/// the clipboard and ⌘V, putting the user's clipboard back afterwards.
enum TextInserter {
    /// The focused element, if it accepts text.
    static func focusedTextField() -> AXUIElement? {
        // Never ask Flare about itself (see ContextCapture.ownAppHasFocus).
        guard let focused = ContextCapture.focusedElementElsewhere() else { return nil }
        let role = ContextCapture.string(focused, kAXRoleAttribute) ?? ""
        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole { return focused }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return focused
        }
        return nil
    }

    @MainActor
    static func insert(_ text: String, sendKeyCombo: ((UInt16, UInt64) -> Void)?) async -> Bool {
        guard let field = focusedTextField() else { return false }
        let before = ContextCapture.string(field, kAXValueAttribute)
        if AXUIElementSetAttributeValue(field, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            try? await Task.sleep(nanoseconds: 120_000_000)
            let after = ContextCapture.string(field, kAXValueAttribute)
            if let after, after != before, after.contains(text.prefix(20)) { return true }
        }
        // Clipboard fallback.
        guard let sendKeyCombo else { return false }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendKeyCombo(9, CGEventFlags.maskCommand.rawValue)            // ⌘V
        try? await Task.sleep(nanoseconds: 450_000_000)
        pasteboard.clearContents()
        if let saved { pasteboard.setString(saved, forType: .string) }
        return true
    }
}
