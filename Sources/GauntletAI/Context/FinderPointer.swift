import AppKit
import ApplicationServices

/// What the pointer is on in Finder or on the Desktop.
public enum FinderTarget: Equatable, Sendable {
    /// A file or folder icon (or list row).
    case item(URL)
    /// The empty part of a Finder window (its folder) or of the Desktop.
    case folder(URL)
    /// Several items selected in Finder.
    case items([URL])

    /// The empty part of a window or the Desktop, rather than a particular item.
    public var isWindowBackground: Bool {
        if case .folder = self { return true }
        return false
    }

    /// The items "this" refers to.
    public var urls: [URL] {
        switch self {
        case .item(let url), .folder(let url): return [url]
        case .items(let urls): return urls
        }
    }
}

/// Works out which file or folder the pointer is on in Finder, through Accessibility.
/// Finder items carry their URL; when they don't, the name under the pointer is joined with the
/// folder the window shows. Call `resolve` off the main thread.
enum FinderPointer {
    static let finderBundle = "com.apple.finder"

    /// True when what's under `point` belongs to Finder (a Finder window or the Desktop). Asks
    /// Accessibility, not the window list: macOS keeps invisible full-screen windows (Stage Manager,
    /// notifications) on top of the Desktop, and those would hide Finder from a window-list check.
    static func isFinder(at point: CGPoint) -> Bool {
        hitElement(at: point) != nil
    }

    static var finderIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundle
    }

    /// The Accessibility element under `point`, if it belongs to Finder.
    private static func hitElement(at point: CGPoint) -> AXUIElement? {
        // Never hit-test our own windows through Accessibility (see ContextCapture.isOverOwnWindow).
        guard !ContextCapture.isOverOwnWindow(point) else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, ContextCapture.messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success, pid != ContextCapture.ownPID,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == finderBundle else { return nil }
        return hit
    }

    /// `windowFolders` maps Finder window titles to the folders they show (from `FinderScript`),
    /// used when Accessibility doesn't say which folder a window is showing.
    static func resolve(at point: CGPoint, windowFolders: [(name: String, url: URL)]) -> FinderTarget? {
        guard let hit = hitElement(at: point) else { return nil }

        let window = windowElement(of: hit)
        var folder: URL?
        if let window {
            folder = documentURL(of: window)
            if folder == nil, let title = ContextCapture.string(window, kAXTitleAttribute) {
                folder = windowFolders.first(where: { $0.name == title })?.url
            }
        } else {
            folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        }

        // Walk up from what's under the pointer: the item's URL, or its name.
        var names: [String] = []
        var current: AXUIElement? = hit
        for _ in 0..<6 {
            guard let element = current else { break }
            let role = ContextCapture.string(element, kAXRoleAttribute) ?? ""
            if role == kAXWindowRole { break }
            if let url = fileURL(of: element), url.standardizedFileURL != folder?.standardizedFileURL {
                return .item(url.standardizedFileURL)
            }
            for attribute in ["AXFilename", kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                if let text = ContextCapture.string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty, text.count < 256, !names.contains(text) {
                    names.append(text)
                }
            }
            if role == kAXRowRole || role == kAXCellRole { names.append(contentsOf: childTexts(element)) }
            current = ContextCapture.element(element, kAXParentAttribute)
        }
        guard let folder else { return nil }
        for name in names {
            if let url = match(name, in: folder) { return .item(url) }
        }
        return .folder(folder)
    }

    // MARK: Helpers

    private static func windowElement(of element: AXUIElement) -> AXUIElement? {
        if let window = ContextCapture.element(element, kAXWindowAttribute) { return window }
        var current: AXUIElement? = element
        for _ in 0..<14 {
            guard let el = current else { return nil }
            if ContextCapture.string(el, kAXRoleAttribute) == kAXWindowRole { return el }
            current = ContextCapture.element(el, kAXParentAttribute)
        }
        return nil
    }

    /// The URL Accessibility gives for an element (`AXURL`, sometimes `AXDocument`), if it's a file.
    static func fileURL(of element: AXUIElement) -> URL? {
        for attribute in [kAXURLAttribute, "AXDocument"] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { continue }
            if let url = value as? URL, url.isFileURL { return url }
            if let text = value as? String, let url = URL(string: text), url.isFileURL { return url }
        }
        return nil
    }

    private static func documentURL(of window: AXUIElement) -> URL? {
        guard let url = fileURL(of: window) else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue ? url : nil
    }

    /// Text of the first few text fields inside a list row (the name column comes first).
    private static func childTexts(_ element: AXUIElement) -> [String] {
        var found: [String] = []
        var stack: [(AXUIElement, Int)] = [(element, 0)]
        var visited = 0
        while case let (el, depth)? = stack.popLast(), visited < 40, found.count < 3 {
            visited += 1
            let role = ContextCapture.string(el, kAXRoleAttribute) ?? ""
            if role == kAXTextFieldRole || role == kAXStaticTextRole,
               let value = ContextCapture.string(el, kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                found.append(value)
            }
            if depth < 3 {
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &children) == .success,
                   let list = children as? [AXUIElement] {
                    stack.append(contentsOf: list.prefix(12).reversed().map { ($0, depth + 1) })
                }
            }
        }
        return found
    }

    /// Finds `name` in `folder`: the exact name, the name without its (hidden) extension, or one or
    /// two levels down (list view with folders opened).
    static func match(_ name: String, in folder: URL) -> URL? {
        let fm = FileManager.default
        let direct = folder.appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        var queue: [(URL, Int)] = [(folder, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 3000 {
            let (dir, depth) = queue.removeFirst()
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                         options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                visited += 1
                if item.lastPathComponent == name || item.deletingPathExtension().lastPathComponent == name { return item }
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
                if depth < 2, values?.isDirectory == true, values?.isPackage != true { queue.append((item, depth + 1)) }
            }
        }
        return nil
    }
}

/// Asks Finder directly (Apple Events) for its selection and which folders its windows show.
/// macOS asks once for permission to control Finder. Main thread only.
@MainActor
enum FinderScript {
    private static func run(_ source: String) -> String? {
        checked(source).text
    }

    /// Runs a script; `ok` is false if it failed (permission denied, no such item, …).
    private static func checked(_ source: String) -> (ok: Bool, text: String?) {
        var error: NSDictionary?
        // Finder busy (or the permission prompt left open): give up rather than freeze June.
        let result = NSAppleScript(source: "with timeout of 30 seconds\n\(source)\nend timeout")?.executeAndReturnError(&error)
        if let error {
            JuneLog.write("Finder script failed: \(error[NSAppleScript.errorMessage] ?? error)")
            return (false, nil)
        }
        return (true, result?.stringValue)
    }

    /// An AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func item(_ url: URL) -> String { "(POSIX file \(quoted(url.path)) as alias)" }

    private static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Selects `urls` in Finder, in the window that shows them (or on the Desktop); if no window
    /// shows them, Finder opens their folder with them selected. True if Finder now has them selected.
    @discardableResult
    static func select(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        let wanted = Set(urls.map(key))
        let list = urls.map(item).joined(separator: ", ")
        _ = checked("tell application \"Finder\" to select {\(list)}")
        if Set(selection().map(key)) == wanted { return true }
        _ = checked("tell application \"Finder\" to reveal {\(list)}")
        return Set(selection().map(key)) == wanted
    }

    /// What's in `folder`, as Finder lists it (no hidden files). For folders macOS hasn't let
    /// Gauntlet read yet; nil if Finder can't either.
    static func contents(of folder: URL) -> [URL]? {
        let script = """
        tell application "Finder"
            set f to \(item(folder))
            set out to ""
            repeat with n in (get name of every folder of f)
                set out to out & "D" & tab & n & linefeed
            end repeat
            repeat with n in (get name of every file of f)
                set out to out & "F" & tab & n & linefeed
            end repeat
            return out
        end tell
        """
        let result = checked(script)
        guard result.ok else { return nil }
        return (result.text ?? "").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return folder.appendingPathComponent(String(parts[1]), isDirectory: parts[0] == "D")
        }
    }

    // MARK: File operations (when macOS hasn't let Gauntlet into the folder)

    /// Moves `url` to the Trash with Finder. Returns where it is in the Trash.
    static func trash(_ url: URL) -> URL? {
        let script = """
        tell application "Finder"
            set t to delete \(item(url))
            try
                return POSIX path of (t as alias)
            on error
                return ""
            end try
        end tell
        """
        let result = checked(script)
        guard result.ok else { return nil }
        if let path = result.text, !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/\(url.lastPathComponent)")
    }

    static func move(_ url: URL, into folder: URL) -> URL? {
        transfer("move", url, folder)
    }

    static func duplicate(_ url: URL, into folder: URL) -> URL? {
        transfer("duplicate", url, folder)
    }

    private static func transfer(_ verb: String, _ url: URL, _ folder: URL) -> URL? {
        let script = """
        tell application "Finder"
            set m to \(verb) \(item(url)) to \(item(folder))
            try
                return POSIX path of (m as alias)
            on error
                return ""
            end try
        end tell
        """
        let result = checked(script)
        guard result.ok else { return nil }
        if let path = result.text, !path.isEmpty { return URL(fileURLWithPath: path) }
        return folder.appendingPathComponent(url.lastPathComponent)
    }

    static func rename(_ url: URL, to name: String) -> URL? {
        guard checked("tell application \"Finder\" to set name of \(item(url)) to \(quoted(name))").ok else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
    }

    /// The files and folders selected in Finder.
    static func selection() -> [URL] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with anItem in (get selection)
                set out to out & (POSIX path of (anItem as alias)) & linefeed
            end repeat
            return out
        end tell
        """
        return (run(script) ?? "").split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }

    /// Each open Finder window's title and the folder it shows.
    static func windowFolders() -> [(name: String, url: URL)] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with w in Finder windows
                try
                    set out to out & (name of w) & tab & (POSIX path of (target of w as alias)) & linefeed
                end try
            end repeat
            return out
        end tell
        """
        return (run(script) ?? "").split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), URL(fileURLWithPath: String(parts[1]), isDirectory: true))
        }
    }
}

/// Lets `FileActions` (which runs off the main thread) ask Finder to do what macOS won't let
/// Gauntlet do itself, such as trashing something on the Desktop before folder access is granted.
public final class FinderBridge: FinderFileFallback, @unchecked Sendable {
    public init() {}

    private func onMain<T: Sendable>(_ label: String, _ work: @MainActor () -> T?) -> T? {
        let result: T?
        if Thread.isMainThread {
            result = MainActor.assumeIsolated(work)
        } else {
            result = DispatchQueue.main.sync { MainActor.assumeIsolated(work) }
        }
        JuneLog.write("Finder did the \(label): \(result == nil ? "failed" : "ok")")
        return result
    }

    public func trash(_ url: URL) -> URL? { onMain("trash") { FinderScript.trash(url) } }
    public func move(_ url: URL, into folder: URL) -> URL? { onMain("move") { FinderScript.move(url, into: folder) } }
    public func duplicate(_ url: URL, into folder: URL) -> URL? { onMain("copy") { FinderScript.duplicate(url, into: folder) } }
    public func rename(_ url: URL, to name: String) -> URL? { onMain("rename") { FinderScript.rename(url, to: name) } }
}
