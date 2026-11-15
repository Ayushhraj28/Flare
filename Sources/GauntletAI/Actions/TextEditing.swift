import AppKit
import ApplicationServices

/// Writing in another app for June: the text selected in the focused field, replacing it so the
/// app's own ⌘Z undoes it, finding a reply box, and pressing Send when (and only when) asked.
/// The Accessibility helpers block briefly: call them off the main thread. `paste` and
/// `copySelection` use the clipboard and keystrokes, so they run on the main thread.
public enum TextEditing {
    /// The focused text field in the front app.
    struct Field: @unchecked Sendable {
        let element: AXUIElement
        let pid: pid_t
        let role: String
        /// The selected text; "" when nothing is selected; nil when the app doesn't say (some web apps).
        let selected: String?
        /// Everything in the field, when the app reports it.
        let value: String?
    }

    // MARK: Reading

    static func focusedField() -> Field? {
        // Never ask Flare about itself (see ContextCapture.ownAppHasFocus).
        guard let element = ContextCapture.focusedElementElsewhere(), isEditable(element) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return Field(element: element, pid: pid, role: ContextCapture.string(element, kAXRoleAttribute) ?? "",
                     selected: ContextCapture.string(element, kAXSelectedTextAttribute),
                     value: ContextCapture.string(element, kAXValueAttribute))
    }

    static func isEditable(_ element: AXUIElement) -> Bool {
        let role = ContextCapture.string(element, kAXRoleAttribute) ?? ""
        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
           role != kAXSliderRole, role != kAXCheckBoxRole {
            return true
        }
        return false
    }

    /// Selects `range` (UTF-16) in the field. True if the app now reports that selection.
    static func select(_ range: NSRange, in element: AXUIElement, expecting text: String) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange),
              AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        usleep(60_000)
        return ContextCapture.string(element, kAXSelectedTextAttribute) == text
    }

    /// Selects the last place `text` appears in the field (what June just wrote).
    static func select(_ text: String, in element: AXUIElement) -> Bool {
        guard let value = ContextCapture.string(element, kAXValueAttribute) else { return false }
        let range = (value as NSString).range(of: text, options: .backwards)
        guard range.location != NSNotFound else { return false }
        return select(range, in: element, expecting: text)
    }

    /// Selects everything in the field.
    static func selectAll(in element: AXUIElement, value: String) -> Bool {
        select(NSRange(location: 0, length: (value as NSString).length), in: element, expecting: value)
    }

    // MARK: Clipboard and keys (main thread)

    /// Everything on the clipboard, so it can be put back after June borrows it.
    struct ClipboardSnapshot {
        private let items: [[NSPasteboard.PasteboardType: Data]]

        init(_ pasteboard: NSPasteboard = .general) {
            items = (pasteboard.pasteboardItems ?? []).map { item in
                var copy: [NSPasteboard.PasteboardType: Data] = [:]
                for type in item.types { if let data = item.data(forType: type) { copy[type] = data } }
                return copy
            }
        }

        func restore(_ pasteboard: NSPasteboard = .general) {
            pasteboard.clearContents()
            let restored = items.map { saved -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in saved { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }

    /// Replaces the selection (or types at the caret) by pasting, so the app records one undo step
    /// and ⌘Z puts the old text back. The user's clipboard is restored afterwards.
    @MainActor
    static func paste(_ text: String, sendKeyCombo: ((UInt16, UInt64) -> Void)?) async -> Bool {
        guard let sendKeyCombo else { return false }
        let pasteboard = NSPasteboard.general
        let saved = ClipboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        sendKeyCombo(9, CGEventFlags.maskCommand.rawValue)                 // ⌘V
        // Web apps read the clipboard a little later than native ones; long text takes longer.
        let wait = UInt64(min(1_200, 450 + text.count / 20)) * 1_000_000
        try? await Task.sleep(nanoseconds: wait)
        saved.restore(pasteboard)
        return true
    }

    /// The selection, copied with ⌘C, for apps that don't report it through Accessibility.
    /// Nil if nothing was copied. The clipboard is put back.
    @MainActor
    static func copySelection(sendKeyCombo: ((UInt16, UInt64) -> Void)?) async -> String? {
        guard let sendKeyCombo else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = ClipboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        sendKeyCombo(8, CGEventFlags.maskCommand.rawValue)                 // ⌘C
        var copied: String?
        for _ in 0..<8 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if pasteboard.changeCount != before {
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before { saved.restore(pasteboard) }
        return copied
    }

    // MARK: Replying

    /// Apps where ⌘R opens a reply with the cursor in its body.
    static let replyShortcutApps: Set<String> = ["com.apple.mail", "com.microsoft.Outlook"]

    /// Chat apps where Return sends the message and there's no Send button to press.
    static let returnSendsApps: Set<String> = ["com.apple.MobileSMS", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp",
                                               "desktop.WhatsApp", "com.hnc.Discord", "ru.keepcoder.Telegram",
                                               "com.microsoft.teams2", "com.microsoft.teams", "com.facebook.archon",
                                               "org.whispersystems.signal-desktop"]

    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
                                        "com.microsoft.edgemac", "org.mozilla.firefox", "com.brave.Browser",
                                        "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]

    /// The message box of a chat app's front window: the lowest multi-line text area (search and
    /// address fields don't count). Not used in browsers, where a page's search box looks the same.
    static func replyBox(pid: pid_t) -> AXUIElement? {
        guard pid != ContextCapture.ownPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ContextCapture.messagingTimeout)
        guard let window = ContextCapture.element(app, kAXFocusedWindowAttribute) ?? ContextCapture.element(app, kAXMainWindowAttribute)
        else { return nil }
        var best: (element: AXUIElement, bottom: CGFloat, area: Bool)?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = ContextCapture.string(element, kAXRoleAttribute) ?? ""
            let subrole = ContextCapture.string(element, kAXSubroleAttribute) ?? ""
            if (role == kAXTextAreaRole || role == kAXTextFieldRole), subrole != kAXSearchFieldSubrole, subrole != "AXSecureTextField",
               isEditable(element), let frame = ContextCapture.frame(of: element), frame.height > 12, frame.width > 120 {
                let area = role == kAXTextAreaRole
                if best == nil || (area && !(best?.area ?? false)) || (area == best?.area && frame.maxY > (best?.bottom ?? 0)) {
                    best = (element, frame.maxY, area)
                }
            }
            if depth < 25 {
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                   let list = children as? [AXUIElement] {
                    queue.append(contentsOf: list.map { ($0, depth + 1) })
                }
            }
        }
        return best?.element
    }

    /// Puts the text cursor in `element`. True if it's now the focused field.
    static func focus(_ element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        usleep(120_000)
        guard let field = focusedField() else { return false }
        return CFEqual(field.element, element)
    }

    // MARK: Sending

    /// Presses the Send button in the app's front window. Only ever called when the user said "click Send".
    static func pressSendButton(pid: pid_t) -> Bool {
        guard pid != ContextCapture.ownPID else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ContextCapture.messagingTimeout)
        guard let window = ContextCapture.element(app, kAXFocusedWindowAttribute) ?? ContextCapture.element(app, kAXMainWindowAttribute)
        else { return false }
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role = ContextCapture.string(element, kAXRoleAttribute) ?? ""
            if role == kAXButtonRole, isSendLabel(element), isEnabled(element) {
                return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
            }
            if depth < 30 {
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                   let list = children as? [AXUIElement] {
                    queue.append(contentsOf: list.map { ($0, depth + 1) })
                }
            }
        }
        return false
    }

    private static func isEnabled(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else { return true }
        return (value as? Bool) ?? true
    }

    private static func isSendLabel(_ element: AXUIElement) -> Bool {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
            if let label = ContextCapture.string(element, attribute), isSendLabel(label) { return true }
        }
        return false
    }

    /// "Send", "Send ‪(⌘Enter)‬", "Send message" — not "Send feedback" or "Send later".
    public static func isSendLabel(_ label: String) -> Bool {
        var text = label.lowercased()
        while let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") {
            text.removeSubrange(open...close)
        }
        let words = text.split { !$0.isLetter }.map(String.init)
        return ["send", "send message", "send email", "send now", "send reply", "send mail"].contains(words.joined(separator: " "))
    }

    // MARK: Text

    /// Gemini's text, with the original's surrounding spaces and line breaks, and without quotes or a
    /// code fence the original didn't have.
    public static func cleaned(_ output: String, like original: String) -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let core = original.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), !core.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'")] where text.count > 1 && text.hasPrefix(open) && text.hasSuffix(close)
            && !(core.hasPrefix(open) && core.hasSuffix(close)) {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let leading = String(original.prefix { $0.isWhitespace || $0.isNewline })
        let trailing = String(original.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : leading + text + trailing
    }
}
