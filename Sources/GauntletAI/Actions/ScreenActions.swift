import AppKit
import ApplicationServices

/// Closing windows and opening files or folders for June, aimed at what the pointer is on.
/// Everything here talks to other apps through Accessibility, so call it off the main thread.
/// Gauntlet's own windows are never touched (see ContextCapture.ownPID).
enum ScreenActions {
    struct Outcome: Sendable {
        var ok: Bool
        var message: String
    }

    enum CloseScope: Equatable, Sendable {
        case window, allWindows, tab, app
    }

    // MARK: What is under the pointer

    private struct Target {
        var pid: pid_t
        var app: NSRunningApplication?
        var element: AXUIElement
        var window: AXUIElement?
    }

    private static func target(at point: CGPoint) -> Target? {
        guard !ContextCapture.isOverOwnWindow(point) else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, ContextCapture.messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ContextCapture.ownPID else { return nil }
        return Target(pid: pid, app: NSRunningApplication(processIdentifier: pid), element: hit, window: window(of: hit))
    }

    private static func window(of element: AXUIElement) -> AXUIElement? {
        if let w = ContextCapture.element(element, kAXWindowAttribute) { return w }
        var current: AXUIElement? = element
        for _ in 0..<12 {
            guard let el = current else { return nil }
            if ContextCapture.string(el, kAXRoleAttribute) == kAXWindowRole { return el }
            current = ContextCapture.element(el, kAXParentAttribute)
        }
        return nil
    }

    private static func appName(_ t: Target) -> String { t.app?.localizedName ?? "that app" }

    // MARK: Close

    /// Closes the window under the pointer (or all its app's windows, or quits the app).
    /// `appName` closes or quits a running app by name instead of the one under the pointer.
    /// Returns `needsKeyCombo` when the caller should send ⌘W to the (now frontmost) app.
    static func close(_ scope: CloseScope, at point: CGPoint, appName requested: String?) -> (Outcome, needsCommandW: Bool) {
        if let requested, !requested.isEmpty {
            guard let app = runningApp(named: requested) else {
                return (Outcome(ok: false, message: "No open app called “\(requested)”."), false)
            }
            return (closeApp(app, scope: scope == .window ? .app : scope), false)
        }
        guard let t = target(at: point) else {
            return (Outcome(ok: false, message: "Point at the window you want closed."), false)
        }
        switch scope {
        case .app:
            guard let app = t.app else { return (Outcome(ok: false, message: "Couldn't find that app."), false) }
            return (closeApp(app, scope: .app), false)
        case .allWindows:
            return (closeAllWindows(pid: t.pid, name: appName(t)), false)
        case .tab:
            t.app?.activate()
            return (Outcome(ok: true, message: "Closed the tab"), true)
        case .window:
            guard let window = t.window else {
                return (Outcome(ok: false, message: "That isn't a window. Point at the window you want closed."), false)
            }
            if press(window, kAXCloseButtonAttribute) {
                return (Outcome(ok: true, message: "Closed the \(appName(t)) window"), false)
            }
            // No close button exposed: bring the app forward and let ⌘W close its front window.
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            t.app?.activate()
            return (Outcome(ok: true, message: "Closed the \(appName(t)) window"), true)
        }
    }

    private static func closeApp(_ app: NSRunningApplication, scope: CloseScope) -> Outcome {
        let name = app.localizedName ?? "the app"
        if app.processIdentifier == ContextCapture.ownPID {
            return Outcome(ok: false, message: "June won't close Flare.")
        }
        // Finder can't really quit; close its windows instead.
        if scope == .allWindows || app.bundleIdentifier == "com.apple.finder" {
            return closeAllWindows(pid: app.processIdentifier, name: name)
        }
        // A normal quit: the app still asks about unsaved changes.
        return app.terminate()
            ? Outcome(ok: true, message: "Quit \(name)")
            : Outcome(ok: false, message: "\(name) didn't quit.")
    }

    private static func closeAllWindows(pid: pid_t, name: String) -> Outcome {
        guard pid != ContextCapture.ownPID else { return Outcome(ok: false, message: "June won't close Flare.") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, ContextCapture.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else {
            return Outcome(ok: false, message: "\(name) has no windows open.")
        }
        let closed = windows.prefix(50).filter { press($0, kAXCloseButtonAttribute) }.count
        return closed > 0
            ? Outcome(ok: true, message: "Closed \(closed) \(name) window\(closed == 1 ? "" : "s")")
            : Outcome(ok: false, message: "\(name) didn't let June close its windows.")
    }

    /// Presses a button attribute of an element (the close button of a window).
    private static func press(_ element: AXUIElement, _ buttonAttribute: String) -> Bool {
        guard let button = ContextCapture.element(element, buttonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    static func runningApp(named name: String) -> NSRunningApplication? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ContextCapture.ownPID
        }
        return apps.first { normalize($0.localizedName ?? "") == wanted }
            ?? apps.first { normalize($0.localizedName ?? "").hasPrefix(wanted) }
            ?? apps.first { normalize($0.localizedName ?? "").contains(wanted) }
    }

    // MARK: Open

    /// Opens what the pointer is on (a file, folder or link), or a file, folder or app by name.
    static func open(name requested: String?, preferFolder: Bool, at point: CGPoint) -> Outcome {
        if let requested, !requested.isEmpty {
            if let url = findItem(named: requested, preferFolder: preferFolder) {
                NSWorkspace.shared.open(url)
                return Outcome(ok: true, message: "Opened \(displayName(url))")
            }
            if let app = findApp(named: requested) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                return Outcome(ok: true, message: "Opened \(displayName(app))")
            }
            // Maybe it's the name of something visible under the pointer; fall through to that.
            if target(at: point) == nil {
                return Outcome(ok: false, message: "Couldn't find “\(requested)” on your Desktop, Documents, Downloads or Applications.")
            }
        }
        return openUnderPointer(at: point)
    }

    private static func openUnderPointer(at point: CGPoint) -> Outcome {
        guard let t = target(at: point) else {
            return Outcome(ok: false, message: "Point at the file or folder you want opened.")
        }
        // 1. Finder icons and list rows carry the item's URL.
        var current: AXUIElement? = t.element
        for _ in 0..<4 {
            guard let el = current else { break }
            if let url = url(of: el) {
                NSWorkspace.shared.open(url)
                return Outcome(ok: true, message: "Opened \(displayName(url))")
            }
            current = ContextCapture.element(el, kAXParentAttribute)
        }
        // 2. An "open" action on the element.
        if AXUIElementPerformAction(t.element, "AXOpen" as CFString) == .success {
            return Outcome(ok: true, message: "Opened it")
        }
        // 3. Same as the user double-clicking it.
        doubleClick(at: point)
        return Outcome(ok: true, message: "Opened it")
    }

    private static func url(of element: AXUIElement) -> URL? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &value) == .success else { return nil }
        if let url = value as? URL { return url }
        if let text = value as? String { return URL(string: text) }
        return nil
    }

    private static func doubleClick(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for click in 1...2 {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                          mouseButton: .left) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event.post(tap: .cghidEventTap)
            }
            usleep(60_000)
        }
    }

    /// Looks for a file or folder by name where people keep things, two levels deep.
    static func findItem(named name: String, preferFolder: Bool) -> URL? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = ["Desktop", "Documents", "Downloads", "Developer", ""].map { home.appendingPathComponent($0, isDirectory: true) }

        var candidates: [URL] = []
        var queue = roots.map { ($0, 0) }
        while !queue.isEmpty, candidates.count < 5000 {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                         options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                candidates.append(item)
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                // The home folder itself is only searched one level deep (its folders are the roots).
                if depth < 1, dir != home, values?.isDirectory == true, values?.isPackage != true {
                    queue.append((item, depth + 1))
                }
            }
        }
        func isFolder(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        func score(_ url: URL) -> Int? {
            let full = normalize(url.lastPathComponent)
            let stem = normalize(url.deletingPathExtension().lastPathComponent)
            var s: Int
            if full == wanted || stem == wanted { s = 0 }
            else if stem.hasPrefix(wanted) { s = 2 }
            else if stem.contains(wanted) { s = 4 }
            else { return nil }
            if preferFolder, !isFolder(url) { s += 1 }
            return s
        }
        return candidates.compactMap { url in score(url).map { (url, $0) } }
            .min { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.pathComponents.count < b.0.pathComponents.count }?.0
    }

    static func findApp(named name: String) -> URL? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        let apps = dirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: dir).appendingPathComponent($0) }
        }
        let stem: (URL) -> String = { normalize($0.deletingPathExtension().lastPathComponent) }
        return apps.first { stem($0) == wanted } ?? apps.first { stem($0).hasPrefix(wanted) }
    }

    private static func displayName(_ url: URL) -> String {
        url.pathExtension == "app" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    /// Lowercased letters and digits only, so "Resume 2026.pdf" matches "resume 2026".
    static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}
