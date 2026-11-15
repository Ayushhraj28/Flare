import Foundation

/// Spoken names for files and folders: "select Projects and Portfolio", "delete the Resume PDF".
/// Splits what was said into names, then finds each one among the items Finder is showing.
/// Pure and thread-safe, so it can be tested without Finder.
public enum FileNames {
    /// What "select all" asks for.
    public static let everything = "*"

    /// A name the user said, and whether they said "folder" or "file" with it.
    public struct Spoken: Equatable, Sendable {
        public var text: String
        public var kind: Kind?
        public enum Kind: Sendable { case folder, file }
    }

    public struct Resolution: Equatable, Sendable {
        /// Matching items, in the order they were said.
        public var found: [URL] = []
        /// Names with no matching item.
        public var missing: [String] = []
        /// Names that match more than one item, with the candidates.
        public var ambiguous: [Ambiguity] = []
        public struct Ambiguity: Equatable, Sendable {
            public var name: String
            public var candidates: [URL]
        }
    }

    // MARK: Words

    /// The words of an utterance as written, keeping digits, dots and dashes ("Budget-2026.pdf").
    /// Commas become "," and "&" becomes "and"; "resume dot pdf" becomes "resume.pdf".
    public static func tokens(_ text: String) -> [String] {
        var raw: [String] = []
        var current = ""
        func flush() {
            let token = current.trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"'“”‘’()[]:;"))
            if !token.isEmpty { raw.append(token) }
            current = ""
        }
        for ch in text {
            if ch == "," || ch == ";" { flush(); raw.append(",") }
            else if ch == "&" { flush(); raw.append("and") }
            else if ch.isWhitespace { flush() }
            else { current.append(ch) }
        }
        flush()
        var out: [String] = []
        var i = 0
        while i < raw.count {
            if raw[i].lowercased() == "dot", let previous = out.last, previous != ",", i + 1 < raw.count,
               raw[i + 1].count <= 5, raw[i + 1].allSatisfy({ $0.isLetter || $0.isNumber }) {
                out[out.count - 1] = previous + "." + raw[i + 1].lowercased()
                i += 2
                continue
            }
            out.append(raw[i])
            i += 1
        }
        return out
    }

    /// Words that only point ("this", "the", "both"): a phrase made of these alone names nothing.
    static let pointing: Set<String> = ["this", "that", "it", "these", "those", "them", "the", "a", "an", "my", "our", "your",
                                        "both", "all", "of", "one", "ones", "here", "there", "please", "now", "for", "me",
                                        "selected", "selection", "item", "items", "thing", "things", "file", "files",
                                        "folder", "folders", "directory", "document", "pdf", "image", "photo", "picture",
                                        "video", "current", "front", "too", "also"]
    /// Things on screen that aren't files: "delete this sentence" is about text, not Finder.
    static let notFiles: Set<String> = ["sentence", "sentences", "word", "words", "line", "lines", "paragraph", "paragraphs",
                                        "text", "letter", "letters", "character", "characters", "comma", "period", "space",
                                        "spaces", "tab", "tabs", "window", "windows", "app", "answer", "reply", "response",
                                        "message", "messages", "email", "emails", "link", "links", "url", "address", "code",
                                        "part", "bit", "last", "first", "next", "previous", "background", "page", "pages",
                                        "slide", "slides", "row", "rows", "column", "columns", "cell", "cells", "note", "notes",
                                        "event", "events", "reminder", "contact", "song", "track", "chat", "conversation",
                                        "history", "emoji", "highlight", "comment", "comments", "bullet", "list", "duplicates",
                                        "formatting", "spaces", "everything", "summary", "translation", "number"]
    private static let separators: Set<String> = [",", "and", "plus", "also", "then"]
    private static let leading: Set<String> = ["the", "my", "this", "that", "these", "those", "a", "an", "both", "our", "your",
                                               "called", "named", "item", "items", "of", "one"]
    private static let kindWords: [String: Spoken.Kind] = ["folder": .folder, "folders": .folder, "directory": .folder,
                                                           "file": .file, "files": .file, "document": .file,
                                                           "image": .file, "photo": .file, "picture": .file, "video": .file]
    /// Extensions people say as a word: "the resume pdf" is resume.pdf.
    private static let spokenExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic", "gif", "doc", "docx", "txt", "csv",
                                                        "zip", "mp3", "mp4", "mov", "xlsx", "pptx", "json", "md"]

    /// True when the words name something (not only "this", "the file", or text like "this sentence").
    public static func namesSomething(_ words: [String]) -> Bool {
        let lower = words.map { $0.lowercased() }.filter { $0 != "," }
        guard !lower.isEmpty, !lower.allSatisfy({ pointing.contains($0) || separators.contains($0) }) else { return false }
        let meaningful = lower.filter { !pointing.contains($0) && !separators.contains($0) }
        return !meaningful.allSatisfy { notFiles.contains($0) }
    }

    /// Cleans one spoken name: "the Projects folder" → "Projects" (folder), "folder called Old" → "Old".
    static func clean(_ words: [String]) -> Spoken? {
        var w = words.filter { $0 != "," }
        var kind: Spoken.Kind?
        while w.count > 1, let first = w.first?.lowercased(), leading.contains(first) || kindWords[first] != nil {
            if let k = kindWords[first] { kind = k }
            w.removeFirst()
        }
        while w.count > 1, let last = w.last?.lowercased(), let k = kindWords[last] {
            kind = k
            w.removeLast()
        }
        // A spoken extension: "the resume pdf" is resume.pdf.
        if w.count > 1, let last = w.last?.lowercased(), spokenExtensions.contains(last), !(w[w.count - 2].contains(".")) {
            w.removeLast()
            w[w.count - 1] += "." + last
            kind = .file
        }
        guard !w.isEmpty else { return nil }
        if w.count == 1, let only = w.first?.lowercased(), leading.contains(only) { return nil }
        return Spoken(text: w.joined(separator: " "), kind: kind)
    }

    // MARK: Matching

    /// Lowercase letters and digits, with number words as digits: "Report Two" → "report2".
    static func normalize(_ text: String) -> String {
        words(text).joined()
    }

    static func words(_ text: String) -> [String] {
        let numbers = ["zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
                       "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12"]
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        return folded.split { !$0.isLetter && !$0.isNumber }.map { numbers[String($0)] ?? String($0) }
    }

    /// Finds the names in `phrase` among `places` (each place's items, most likely place first).
    /// Names joined by "and" are tried together first, so "Pride and Prejudice.pdf" stays one name.
    public static func resolve(_ phrase: String, places: [[URL]]) -> Resolution {
        let tokens = Self.tokens(phrase)
        var chunks: [[String]] = [[]]
        var joiners: [String] = []
        for token in tokens {
            if separators.contains(token.lowercased()) {
                if !(chunks.last ?? []).isEmpty { chunks.append([]); joiners.append(token) }
            } else {
                chunks[chunks.count - 1].append(token)
            }
        }
        chunks = chunks.filter { !$0.isEmpty }

        var result = Resolution()
        var i = 0
        while i < chunks.count {
            var advanced = false
            // Longest run of chunks that is itself the exact name of something.
            var j = chunks.count - 1
            while j > i {
                var together = chunks[i]
                for k in (i + 1)...j { together += [joiners[k - 1]] + chunks[k] }
                if let spoken = clean(together), case .one(let url) = match(spoken, places: places, exactOnly: true) {
                    append(url, to: &result)
                    i = j + 1
                    advanced = true
                    break
                }
                j -= 1
            }
            if advanced { continue }
            if let spoken = clean(chunks[i]) {
                switch match(spoken, places: places, exactOnly: false) {
                case .one(let url): append(url, to: &result)
                case .many(let urls): result.ambiguous.append(.init(name: spoken.text, candidates: urls))
                case .none: result.missing.append(spoken.text)
                }
            }
            i += 1
        }
        return result
    }

    private static func append(_ url: URL, to result: inout Resolution) {
        if !result.found.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { result.found.append(url) }
    }

    enum Match: Equatable { case none, one(URL), many([URL]) }

    static func match(_ spoken: Spoken, places: [[URL]], exactOnly: Bool) -> Match {
        let wanted = normalize(spoken.text)
        let wantedWords = words(spoken.text)
        guard !wanted.isEmpty else { return .none }
        let hasExtension = spoken.text.contains(".")

        func isFolder(_ url: URL) -> Bool { url.hasDirectoryPath || FileActions.isFolder(url) }
        func fits(_ url: URL) -> Bool {
            switch spoken.kind {
            case .folder?: return isFolder(url)
            case .file?: return !isFolder(url)
            case nil: return true
            }
        }
        func pick(_ urls: [URL]) -> Match {
            guard !urls.isEmpty else { return .none }
            if urls.count == 1 { return .one(urls[0]) }
            let kinded = urls.filter(fits)
            if kinded.count == 1 { return .one(kinded[0]) }
            return .many(kinded.isEmpty ? urls : kinded)
        }

        // 1. The exact name, with or without its extension ("resume" is Resume.pdf).
        for items in places {
            let exact = items.filter { url in
                let full = normalize(url.lastPathComponent)
                let stem = normalize(url.deletingPathExtension().lastPathComponent)
                return hasExtension ? full == wanted : (stem == wanted || full == wanted)
            }
            if !exact.isEmpty { return pick(exact) }
        }
        if exactOnly || wanted.count < 3 { return .none }
        // 2. The start of a name ("portfolio" is Portfolio 2025), or every word in it.
        for items in places {
            let partial = items.filter { url in
                let stem = normalize(url.deletingPathExtension().lastPathComponent)
                if stem.hasPrefix(wanted) { return true }
                let nameWords = Set(words(url.deletingPathExtension().lastPathComponent))
                return wantedWords.count > 1 && wantedWords.allSatisfy { nameWords.contains($0) }
            }
            if !partial.isEmpty { return pick(partial) }
        }
        return .none
    }
}
