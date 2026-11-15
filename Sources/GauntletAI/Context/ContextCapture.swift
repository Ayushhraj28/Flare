import AppKit
import ApplicationServices

/// What June can see at the cursor, read through the Accessibility API.
public struct CaptureResult: Sendable, Equatable {
    public enum Source: String, Sendable { case selection, element, none }
    public var text: String?
    public var imageJPEG: Data?
    /// Screen frame of what was read, global top-left coordinates, for the capture highlight.
    public var frame: CGRect?
    public var appName: String
    /// The focused element is an editable text field (dictation and paste depend on this).
    public var focusedEditable: Bool
    public var source: Source
}

enum ContextCapture {
    static let maxChars = 4000
    private static var enabledPIDs = Set<pid_t>()
    private static let enabledLock = NSLock()
    /// Gauntlet's own process. Accessibility calls into our own windows run synchronously on the
    /// calling thread, so reading them from a background thread touches AppKit/SwiftUI off the main
    /// thread: that deadlocks the UI and corrupts memory. June never reads its own windows.
    static let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Seconds before an Accessibility call to a busy app gives up instead of hanging June.
    static let messagingTimeout: Float = 1.0

    /// The process owning the topmost visible window under `point` (global top-left coordinates),
    /// worked out from the window list, not Accessibility. Asking Accessibility "what is at this
    /// point" when the answer is one of our own windows runs our UI code on the calling thread,
    /// which is what froze June, so this check has to come first.
    static func windowOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list {
            guard let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary), bounds.contains(point) else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        }
        return nil
    }

    /// True when an Accessibility hit test at `point` could land in Flare itself: Flare is the active
    /// app, or any of Flare's windows (the app, June's panel, the menu) covers the point.
    ///
    /// Deliberately conservative. The topmost window at a point is often an invisible system or overlay
    /// window (Stage Manager, notifications, other apps' overlays) that Accessibility looks straight
    /// through, so "who owns the top window" can say "someone else" while the hit test still lands in
    /// Flare. That in-process request is what crashed and froze June (see `ownAppHasFocus`).
    static func isOverOwnWindow(_ point: CGPoint) -> Bool {
        if ownAppHasFocus { return true }
        // Unknown window list: assume the worst rather than risk asking Flare about itself.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == ownPID,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary) else { return false }
            return bounds.contains(point)
        }
    }

    /// True while Flare itself has keyboard focus (its window, or June's panel, is the active one).
    ///
    /// An Accessibility request aimed at Flare is answered inside Flare, on the calling thread.
    /// June calls Accessibility from background threads, where AppKit and SwiftUI raise exceptions
    /// that HIServices then swallows. The unwind skips Swift's per-thread bookkeeping, and the app
    /// crashes moments later on whatever runs next on that thread. So June never asks Flare about
    /// itself: every system-wide "focused element" query must check this first.
    static var ownAppHasFocus: Bool {
        NSRunningApplication.current.isActive || NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID
    }

    /// The focused element of another app, or nil when Flare itself has focus (see `ownAppHasFocus`).
    static func focusedElementElsewhere() -> AXUIElement? {
        guard !ownAppHasFocus else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        guard let focused = element(system, kAXFocusedUIElementAttribute), !isOwn(focused) else { return nil }
        return focused
    }

    static func isOwn(_ el: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return false }
        return pid == ownPID
    }

    /// Reads selected text if there is any, otherwise the text of the element under `point`.
    /// Call off the main thread: Accessibility calls can block briefly.
    static func capture(at point: CGPoint) -> CaptureResult {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName ?? "Unknown app"
        let nothing = CaptureResult(text: nil, imageJPEG: nil, frame: nil, appName: appName,
                                    focusedEditable: false, source: .none)
        // Pointing at Gauntlet itself: nothing to read, and reading it off the main thread is unsafe.
        if front?.processIdentifier == ownPID || ownAppHasFocus { return nothing }
        if let pid = front?.processIdentifier { enableWebAccessibility(pid) }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        let focused = focusedElementElsewhere()
        let editable = focused.map(isEditable) ?? false

        if let focused, let selected = string(focused, kAXSelectedTextAttribute),
           !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CaptureResult(text: String(selected.prefix(maxChars)), imageJPEG: nil, frame: frame(of: focused),
                                 appName: appName, focusedEditable: editable, source: .selection)
        }

        // The pointer may be over June's own panel or Gauntlet's window above another app.
        guard !isOverOwnWindow(point) else {
            return CaptureResult(text: nil, imageJPEG: nil, frame: nil, appName: appName,
                                 focusedEditable: editable, source: .none)
        }
        var hit: AXUIElement?
        AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        if let hit, !isOwn(hit), let found = nearestText(from: hit) {
            return CaptureResult(text: String(found.text.prefix(maxChars)), imageJPEG: nil, frame: frame(of: found.element),
                                 appName: appName, focusedEditable: editable, source: .element)
        }
        return CaptureResult(text: nil, imageJPEG: nil, frame: nil, appName: appName,
                             focusedEditable: editable, source: .none)
    }

    // MARK: Finding text

    private static func nearestText(from start: AXUIElement) -> (text: String, element: AXUIElement)? {
        var current: AXUIElement? = start
        for _ in 0..<6 {
            guard let el = current else { break }
            if let own = ownText(of: el), own.count >= 3 {
                // A tiny hit (one link inside a paragraph): widen to the surrounding block.
                if own.count < 40, let parent = element(el, kAXParentAttribute) {
                    var wide = ""
                    gather(parent, depth: 3, into: &wide)
                    if wide.count > own.count { return (wide, parent) }
                }
                return (own, el)
            }
            current = element(el, kAXParentAttribute)
        }
        return nil
    }

    private static func ownText(of el: AXUIElement) -> String? {
        let candidates = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
        for attribute in candidates {
            if let s = string(el, attribute) {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// Collects the static text under a block (a paragraph, a list item, a message body).
    private static func gather(_ el: AXUIElement, depth: Int, into text: inout String) {
        guard depth >= 0, text.count < maxChars else { return }
        if string(el, kAXRoleAttribute) == kAXStaticTextRole, let value = string(el, kAXValueAttribute) {
            if !text.isEmpty { text += " " }
            text += value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return }
        for child in list.prefix(80) {
            gather(child, depth: depth - 1, into: &text)
            if text.count >= maxChars { return }
        }
    }

    // MARK: Accessibility helpers

    static func element(_ el: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func string(_ el: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func isEditable(_ el: AXUIElement) -> Bool {
        let role = string(el, kAXRoleAttribute) ?? ""
        if role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        return false
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Chromium and Electron only build their accessibility tree when asked.
    static func enableWebAccessibility(_ pid: pid_t) {
        guard pid != ownPID else { return }
        enabledLock.lock()
        let isNew = enabledPIDs.insert(pid).inserted
        enabledLock.unlock()
        guard isNew else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
}
