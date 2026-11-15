import Foundation

/// Finder doing a file operation for June. Each returns where the item ended up, or nil.
public protocol FinderFileFallback: AnyObject, Sendable {
    func trash(_ url: URL) -> URL?
    func move(_ url: URL, into folder: URL) -> URL?
    func duplicate(_ url: URL, into folder: URL) -> URL?
    func rename(_ url: URL, to name: String) -> URL?
}

/// Copy, paste, move, rename and trash for June, every one of them undoable.
/// Nothing is ever deleted for good: "delete" means the Trash, and undoing a paste moves the new
/// copy to the Trash. Existing files are never overwritten; a clash gets a new name ("Report 2.pdf").
/// System folders and the main folders of the home folder (Desktop, Documents, …) can't be moved,
/// renamed or trashed. Thread-safe; file work runs on the caller's thread.
///
/// When macOS doesn't let Gauntlet into a folder (Desktop, Documents and Downloads need permission),
/// the work is handed to Finder, which already has access, through `finder`.
public final class FileActions: @unchecked Sendable {

    public struct Outcome: Sendable, Equatable {
        public var ok: Bool
        public var message: String
        /// Where the affected items are now (for "this" in the next command).
        public var items: [URL]
    }

    private enum Step {
        case created(URL)
        case moved(from: URL, to: URL)
        case trashed(original: URL, inTrash: URL)
    }

    private let lock = NSLock()
    private var clipboardItems: [URL] = []
    private var history: [(label: String, steps: [Step])] = []
    private let fm = FileManager.default
    private let finder: FinderFileFallback?

    public init(finder: FinderFileFallback? = nil) { self.finder = finder }

    /// What "copy this" put aside for "paste it here".
    public var clipboard: [URL] {
        get { lock.lock(); defer { lock.unlock() }; return clipboardItems }
        set { lock.lock(); clipboardItems = newValue; lock.unlock() }
    }

    public var canUndo: Bool { lock.lock(); defer { lock.unlock() }; return !history.isEmpty }

    // MARK: Actions

    public func copy(_ urls: [URL]) -> Outcome {
        let existing = urls.filter(Self.exists)
        guard !existing.isEmpty else { return fail("That file isn't there any more.") }
        clipboard = existing
        return Outcome(ok: true, message: "Copied \(Self.describe(existing)). Point where it should go and say “paste it here”.",
                       items: existing)
    }

    public func paste(_ urls: [URL], into folder: URL) -> Outcome {
        guard Self.isFolder(folder) else { return fail("That's not a folder.") }
        var created: [URL] = []
        for source in urls {
            guard Self.exists(source) else { continue }
            if Self.contains(source, folder) { return fail("Can't paste a folder inside itself.") }
            let destination = Self.uniqueDestination(named: source.lastPathComponent, in: folder)
            do {
                try fm.copyItem(at: source, to: destination)
                created.append(destination)
            } catch {
                if destination.lastPathComponent == source.lastPathComponent, let copy = finder?.duplicate(source, into: folder) {
                    created.append(copy)
                    continue
                }
                record("paste", created.map { .created($0) })
                return fail("Couldn't paste \(source.lastPathComponent): \(Self.reason(error))")
            }
        }
        guard !created.isEmpty else { return fail("The copied file isn't there any more.") }
        record("paste", created.map { .created($0) })
        return Outcome(ok: true, message: "Pasted \(Self.describe(created)) into \(folder.lastPathComponent)", items: created)
    }

    public func move(_ urls: [URL], to folder: URL) -> Outcome {
        guard Self.isFolder(folder) else { return fail("That's not a folder.") }
        if let protected = urls.first(where: Self.isProtected) {
            return fail("June won't move \(protected.lastPathComponent): it's a system or main folder.")
        }
        var steps: [Step] = []
        var moved: [URL] = []
        for source in urls {
            guard Self.exists(source) else { continue }
            if source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
                moved.append(source)
                continue                                  // already there
            }
            if Self.contains(source, folder) { return fail("Can't move a folder inside itself.") }
            let destination = Self.uniqueDestination(named: source.lastPathComponent, in: folder)
            do {
                try fm.moveItem(at: source, to: destination)
                steps.append(.moved(from: source, to: destination))
                moved.append(destination)
            } catch {
                if destination.lastPathComponent == source.lastPathComponent, let now = finder?.move(source, into: folder) {
                    steps.append(.moved(from: source, to: now))
                    moved.append(now)
                    continue
                }
                record("move", steps)
                return fail("Couldn't move \(source.lastPathComponent): \(Self.reason(error))")
            }
        }
        guard !moved.isEmpty else { return fail("That file isn't there any more.") }
        if steps.isEmpty { return Outcome(ok: true, message: "\(Self.describe(moved)) is already in \(folder.lastPathComponent)", items: moved) }
        record("move", steps)
        return Outcome(ok: true, message: "Moved \(Self.describe(moved)) to \(folder.lastPathComponent)", items: moved)
    }

    public func rename(_ url: URL, to requested: String) -> Outcome {
        guard Self.exists(url) else { return fail("That file isn't there any more.") }
        guard !Self.isProtected(url) else { return fail("June won't rename \(url.lastPathComponent): it's a system or main folder.") }
        guard let name = Self.newName(for: url, requested: requested) else {
            return fail("“\(requested)” can't be a file name.")
        }
        if name == url.lastPathComponent { return Outcome(ok: true, message: "It's already called \(name)", items: [url]) }
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        // Allow changing only the capitalisation ("report" → "Report") on a case-insensitive disk.
        let caseOnly = name.lowercased() == url.lastPathComponent.lowercased()
        if fm.fileExists(atPath: destination.path), !caseOnly {
            return fail("There's already something called \(name) there.")
        }
        do {
            if caseOnly {
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".june-rename-\(UUID().uuidString)")
                try fm.moveItem(at: url, to: temporary)
                try fm.moveItem(at: temporary, to: destination)
            } else {
                try fm.moveItem(at: url, to: destination)
            }
        } catch {
            guard !caseOnly, let renamed = finder?.rename(url, to: name) else {
                return fail("Couldn't rename it: \(Self.reason(error))")
            }
            record("rename", [.moved(from: url, to: renamed)])
            return Outcome(ok: true, message: "Renamed it to \(renamed.lastPathComponent)", items: [renamed])
        }
        record("rename", [.moved(from: url, to: destination)])
        return Outcome(ok: true, message: "Renamed it to \(name)", items: [destination])
    }

    /// Moves items to the Trash, where they can be put back. Never deletes anything.
    public func trash(_ urls: [URL]) -> Outcome {
        if let protected = urls.first(where: Self.isProtected) {
            return fail("June won't put \(protected.lastPathComponent) in the Trash: it's a system or main folder.")
        }
        var steps: [Step] = []
        var trashed: [URL] = []
        for url in urls {
            var inTrash: NSURL?
            do {
                try fm.trashItem(at: url, resultingItemURL: &inTrash)
                if let inTrash = inTrash as URL? { steps.append(.trashed(original: url, inTrash: inTrash)) }
                trashed.append(url)
            } catch let error where Self.isMissing(error) {
                continue                                   // already gone
            } catch {
                // macOS may not let Gauntlet into this folder; Finder can do it.
                if let finderTrash = finder?.trash(url) {
                    steps.append(.trashed(original: url, inTrash: finderTrash))
                    trashed.append(url)
                    continue
                }
                record("trash", steps)
                let done = trashed.isEmpty ? "" : " (\(Self.describe(trashed)) did go to the Trash)"
                return fail("Couldn't move \(url.lastPathComponent) to the Trash: \(Self.reason(error))\(done)")
            }
        }
        guard !trashed.isEmpty else { return fail("That file isn't there any more.") }
        record("trash", steps)
        return Outcome(ok: true, message: "Moved \(Self.describe(trashed)) to the Trash. Say “undo” to put \(trashed.count == 1 ? "it" : "them") back.",
                       items: [])
    }

    /// Reverses the most recent action.
    public func undo() -> Outcome {
        lock.lock()
        let last = history.popLast()
        lock.unlock()
        guard let last else { return fail("There's nothing to undo.") }
        var restored: [URL] = []
        var problems: [String] = []
        for step in last.steps.reversed() {
            do {
                switch step {
                case .created(let url):
                    // Undoing a paste: the copy goes to the Trash, not into oblivion.
                    if Self.exists(url) {
                        do { try fm.trashItem(at: url, resultingItemURL: nil) } catch {
                            if finder?.trash(url) == nil { throw error }
                        }
                    }
                case .moved(let from, let to):
                    guard Self.exists(to) else { problems.append(to.lastPathComponent); continue }
                    restored.append(try putBack(to, at: from))
                case .trashed(let original, let inTrash):
                    guard Self.exists(inTrash) else { problems.append(original.lastPathComponent); continue }
                    restored.append(try putBack(inTrash, at: original))
                }
            } catch {
                problems.append(Self.reason(error))
            }
        }
        if !problems.isEmpty, restored.isEmpty, last.label != "paste" {
            return fail("Couldn't undo the \(last.label): \(problems.joined(separator: ", ")).")
        }
        let message: String
        switch last.label {
        case "paste": message = "Undid the paste; the copy is in the Trash"
        case "trash": message = "Put \(Self.describe(restored)) back"
        case "rename": message = "Changed the name back to \(restored.first?.lastPathComponent ?? "what it was")"
        default: message = "Moved \(Self.describe(restored)) back"
        }
        return Outcome(ok: true, message: message, items: restored)
    }

    // MARK: Helpers

    /// Moves `item` back to `original` (or "name 2" beside it if something took its place).
    private func putBack(_ item: URL, at original: URL) throws -> URL {
        let folder = original.deletingLastPathComponent()
        let back = Self.exists(original) ? Self.uniqueDestination(named: original.lastPathComponent, in: folder) : original
        do {
            try fm.moveItem(at: item, to: back)
            return back
        } catch {
            guard let finder, var now = finder.move(item, into: folder) else { throw error }
            if now.lastPathComponent != back.lastPathComponent, let renamed = finder.rename(now, to: back.lastPathComponent) {
                now = renamed
            }
            return now
        }
    }

    private func record(_ label: String, _ steps: [Step]) {
        guard !steps.isEmpty else { return }
        lock.lock()
        history.append((label, steps))
        if history.count > 20 { history.removeFirst() }
        lock.unlock()
    }

    private func fail(_ message: String) -> Outcome { Outcome(ok: false, message: message, items: []) }

    /// "Projects", "Projects and Portfolio", "A, B and C", or "5 items".
    public static func describe(_ urls: [URL]) -> String {
        let names = urls.map(\.lastPathComponent)
        switch names.count {
        case 0: return "nothing"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names.count) items"
        }
    }

    /// False only when the item is really gone. A folder macOS hasn't let Gauntlet into (Desktop,
    /// Documents) answers "not permitted" rather than "no such file", and the item is still there.
    public static func exists(_ url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        return errno == EPERM || errno == EACCES
    }

    static func isMissing(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(e.code) { return true }
        if e.domain == NSPOSIXErrorDomain, e.code == Int(ENOENT) { return true }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) { return true }
        return false
    }

    static func reason(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription
        return text.isEmpty ? "macOS didn't allow it" : text
    }

    public static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { return false }
            return (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage != true
        }
        // Not allowed to look inside this folder yet: go by what Finder said it is.
        return exists(url) && url.hasDirectoryPath
    }

    /// True when `inner` is `outer` or inside it.
    static func contains(_ outer: URL, _ inner: URL) -> Bool {
        let a = outer.standardizedFileURL.pathComponents
        let b = inner.standardizedFileURL.pathComponents
        return b.count >= a.count && Array(b.prefix(a.count)) == a
    }

    /// System folders, the home folder and its main folders, and anything in Library are off limits.
    public static func isProtected(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let mainFolders = ["", "/Desktop", "/Documents", "/Downloads", "/Library", "/Applications", "/Pictures",
                           "/Movies", "/Music", "/Public", "/Developer"].map { home + $0 }
        if mainFolders.contains(path) { return true }
        // iCloud Drive (and Desktop & Documents kept in iCloud) and Dropbox, Google Drive, OneDrive live
        // inside Library but hold the user's own files: those can be moved and trashed, their top
        // folders can't.
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path.hasPrefix(iCloud + "/") {
            return [iCloud + "/Desktop", iCloud + "/Documents", iCloud + "/Downloads"].contains(path)
        }
        let cloudStorage = home + "/Library/CloudStorage/"
        if path.hasPrefix(cloudStorage) {
            return path.dropFirst(cloudStorage.count).split(separator: "/").count < 2
        }
        if path.hasPrefix(home + "/Library/") || path.hasPrefix(home + "/.") { return true }
        let system = ["/", "/Applications", "/System", "/Library", "/Users", "/Volumes", "/usr", "/bin", "/sbin",
                      "/private", "/opt", "/cores", "/etc", "/var", "/tmp"]
        if system.contains(path) { return true }
        if ["/System/", "/Library/", "/usr/", "/bin/", "/sbin/"].contains(where: { path.hasPrefix($0) }) { return true }
        // A disk itself (/Volumes/Name) can't be moved or trashed.
        let parts = url.standardizedFileURL.pathComponents
        return parts.count == 3 && parts[1] == "Volumes"
    }

    /// `name` in `folder`, or "name 2", "name 3", … if something is already called that.
    public static func uniqueDestination(named name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 2
        repeat {
            let next = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            candidate = folder.appendingPathComponent(next)
            index += 1
        } while fm.fileExists(atPath: candidate.path) && index < 10_000
        return candidate
    }

    /// The new file name for "rename this to …": keeps the old extension unless a new one was said.
    /// Nil if it can't be a file name.
    public static func newName(for url: URL, requested: String) -> String? {
        var name = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.!?,"))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), name.count <= 240 else { return nil }
        let oldExt = url.pathExtension
        let isFolder = Self.isFolder(url)
        if !isFolder, !oldExt.isEmpty, (name as NSString).pathExtension.lowercased() != oldExt.lowercased() {
            name += "." + oldExt
        }
        return name
    }

    /// A folder by spoken name: Desktop, Documents, Downloads, Pictures, Movies, Music, Home, or any
    /// folder of that name in the places people keep things.
    public static func folder(named spoken: String) -> URL? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let words = spoken.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
            .filter { !["the", "my", "folder", "directory", "to", "into", "in", "a", "please"].contains($0) }
        let name = words.joined(separator: " ")
        guard !name.isEmpty else { return nil }
        let known: [String: String] = ["desktop": "Desktop", "documents": "Documents", "document": "Documents", "docs": "Documents",
                                       "downloads": "Downloads", "download": "Downloads", "pictures": "Pictures", "photos": "Pictures",
                                       "movies": "Movies", "videos": "Movies", "music": "Music", "developer": "Developer",
                                       "public": "Public"]
        if let folder = known[name] { return home.appendingPathComponent(folder, isDirectory: true) }
        if name == "home" { return home }
        if let url = ScreenActions.findItem(named: name, preferFolder: true), isFolder(url) { return url }
        return nil
    }
}
