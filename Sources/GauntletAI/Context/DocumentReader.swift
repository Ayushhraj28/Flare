import AppKit
import ApplicationServices
import PDFKit

/// The whole document in the front window, for "summarize this document".
struct DocumentContext: Sendable {
    var text: String
    var title: String
    var frame: CGRect?
    var appName: String
    /// "file", "web page" or "window".
    var kind: String
}

/// Reads the entire document the user is looking at, in this order:
/// 1. the file behind the front window (Preview, TextEdit, Word, Pages exports, code editors): PDF, Word,
///    RTF, HTML and plain text are read straight from disk;
/// 2. the web page under the cursor (Safari, Chrome, Arc, Electron apps), through Accessibility;
/// 3. all the text in the front window.
/// Call off the main thread.
enum DocumentReader {
    static let maxChars = 60_000
    private static let maxFileBytes = 25 * 1024 * 1024

    static func read(at point: CGPoint) -> DocumentContext? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ContextCapture.ownPID else { return nil }
        let appName = front.localizedName ?? "Unknown app"
        ContextCapture.enableWebAccessibility(front.processIdentifier)
        let app = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(app, ContextCapture.messagingTimeout)
        let window = ContextCapture.element(app, kAXFocusedWindowAttribute) ?? ContextCapture.element(app, kAXMainWindowAttribute)
        let windowTitle = window.flatMap { ContextCapture.string($0, kAXTitleAttribute) } ?? appName
        let windowFrame = window.flatMap { ContextCapture.frame(of: $0) }

        // 1. A file on disk.
        if let window, let path = ContextCapture.string(window, "AXDocument"),
           let url = URL(string: path), url.isFileURL,
           let text = fileText(url)?.trimmingCharacters(in: .whitespacesAndNewlines), text.count > 20 {
            return DocumentContext(text: String(text.prefix(maxChars)), title: url.lastPathComponent,
                                   frame: windowFrame, appName: appName, kind: "file")
        }

        // 2. The web page under the cursor (or the first one in the window).
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, ContextCapture.messagingTimeout)
        var hit: AXUIElement?
        if !ContextCapture.isOverOwnWindow(point) {
            AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        }
        if let h = hit, ContextCapture.isOwn(h) { hit = nil }
        if let web = webArea(from: hit, window: window) {
            let text = gatherAll(web)
            if text.count > 40 {
                return DocumentContext(text: text, title: windowTitle, frame: ContextCapture.frame(of: web) ?? windowFrame,
                                       appName: appName, kind: "web page")
            }
        }

        // 3. Everything readable in the window (Notes, Mail, Messages, text views).
        if let window {
            let text = gatherAll(window)
            if text.count > 40 {
                return DocumentContext(text: text, title: windowTitle, frame: windowFrame, appName: appName, kind: "window")
            }
        }
        return nil
    }

    // MARK: Files

    static func fileText(_ url: URL) -> String? {
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maxFileBytes { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string }
        if ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "wordml"].contains(ext) {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
    }

    // MARK: Accessibility

    private static func webArea(from hit: AXUIElement?, window: AXUIElement?) -> AXUIElement? {
        var current = hit
        for _ in 0..<40 {
            guard let element = current else { break }
            if ContextCapture.string(element, kAXRoleAttribute) == "AXWebArea" { return element }
            current = ContextCapture.element(element, kAXParentAttribute)
        }
        guard let window else { return nil }
        return find(role: "AXWebArea", in: window, depth: 8)
    }

    private static func find(role: String, in root: AXUIElement, depth: Int) -> AXUIElement? {
        var stack: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        while case let (element, level)? = stack.popLast(), visited < 600 {
            visited += 1
            if ContextCapture.string(element, kAXRoleAttribute) == role { return element }
            if level < depth { stack.append(contentsOf: children(element).reversed().map { ($0, level + 1) }) }
        }
        return nil
    }

    /// All the text under `root`, in reading order, within a node and time budget.
    static func gatherAll(_ root: AXUIElement) -> String {
        var parts: [String] = []
        var total = 0
        var visited = 0
        var stack: [AXUIElement] = [root]
        let deadline = Date().addingTimeInterval(2.0)
        while let element = stack.popLast(), visited < 8000, total < maxChars, Date() < deadline {
            visited += 1
            let role = ContextCapture.string(element, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole || role == kAXTextAreaRole {
                if let value = ContextCapture.string(element, kAXValueAttribute) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        parts.append(trimmed)
                        total += trimmed.count + 1
                    }
                }
                continue
            }
            if role == kAXMenuBarRole || role == kAXToolbarRole || role == kAXScrollBarRole { continue }
            stack.append(contentsOf: children(element).reversed())
        }
        return String(parts.joined(separator: " ").prefix(maxChars))
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }
}
