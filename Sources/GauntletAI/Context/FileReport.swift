import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Describes a file or folder for Gemini: real facts (counts, kinds, sizes, dates) and real contents
/// (text with page markers, or a picture), so follow-up questions are answered from what's there.
public enum FileReport {
    public struct Description: Sendable {
        public var text: String
        public var imageJPEG: Data?
        public var isFolder: Bool
        public var name: String
    }

    public struct Entry: Sendable {
        public var url: URL
        public var isFolder: Bool
        public var kind: String
        public var size: Int64
        public var modified: Date?
    }

    static let maxTextChars = 60_000
    static let maxReadBytes = 40 * 1024 * 1024

    /// A file's metadata and contents, or a folder's summary and listing.
    public static func describe(_ url: URL, timeLimit: TimeInterval = 2.5) -> Description? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        if isDirectory.boolValue, !isPackage {
            return Description(text: folderReport(url, timeLimit: timeLimit), imageJPEG: nil, isFolder: true, name: url.lastPathComponent)
        }
        let file = fileReport(url)
        return Description(text: file.text, imageJPEG: file.imageJPEG, isFolder: false, name: url.lastPathComponent)
    }

    /// Several selected items: a short report on each (the first five in full, then a list).
    public static func describe(_ urls: [URL]) -> Description? {
        if urls.count == 1 { return describe(urls[0]) }
        let reports = urls.prefix(5).compactMap { url in describe(url, timeLimit: 1.0).map { (url, $0) } }
        guard !reports.isEmpty else { return nil }
        var text = "\(urls.count) items are selected in Finder.\n"
        for (url, report) in reports {
            text += "\n=== \(url.lastPathComponent) ===\n" + String(report.text.prefix(maxTextChars / 6)) + "\n"
        }
        if urls.count > 5 {
            text += "\nAlso selected: " + urls.dropFirst(5).map(\.lastPathComponent).joined(separator: ", ")
        }
        let images = reports.compactMap(\.1.imageJPEG)
        return Description(text: String(text.prefix(maxTextChars)), imageJPEG: images.count == 1 ? images[0] : nil,
                           isFolder: false, name: "\(urls.count) selected items")
    }

    // MARK: Kinds

    /// A plain-English kind: "PDF", "image", "document", "spreadsheet", "code", "folder", ...
    public static func kind(of url: URL, isFolder: Bool) -> String {
        let ext = url.pathExtension.lowercased()
        if isFolder { return "folder" }
        if ext == "app" { return "app" }
        if ["doc", "docx", "pages", "rtf", "rtfd", "odt", "wpd"].contains(ext) { return "document" }
        if ["xls", "xlsx", "numbers", "csv", "tsv", "ods"].contains(ext) { return "spreadsheet" }
        if ["ppt", "pptx", "key", "odp"].contains(ext) { return "presentation" }
        guard let type = UTType(filenameExtension: ext) else { return ext.isEmpty ? "file" : "\(ext.uppercased()) file" }
        if type.conforms(to: .pdf) { return "PDF" }
        if type.conforms(to: .image) { return "image" }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
        if type.conforms(to: .audio) { return "audio file" }
        if type.conforms(to: .archive) { return "archive" }
        if type.conforms(to: .diskImage) { return "disk image" }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || ["swift", "py", "js", "ts", "java", "kt", "go", "rs", "c", "cpp",
                                                                              "h", "m", "rb", "php", "sh", "json", "yaml", "yml", "toml",
                                                                              "html", "css", "sql"].contains(ext) { return "code" }
        if type.conforms(to: .text) { return "text file" }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return "app" }
        return ext.isEmpty ? "file" : "\(ext.uppercased()) file"
    }

    static func plural(_ kind: String, _ count: Int) -> String {
        if count == 1 { return "1 \(kind)" }
        switch kind {
        case "PDF": return "\(count) PDFs"
        case "audio file": return "\(count) audio files"
        case "text file": return "\(count) text files"
        case "code": return "\(count) code files"
        default: return kind.hasSuffix(" file") ? "\(count) \(kind)s" : "\(count) \(kind)s"
        }
    }

    // MARK: Folders

    public static func listing(of folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        return items.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            return Entry(url: url, isFolder: isFolder, kind: kind(of: url, isFolder: isFolder),
                         size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
        }
    }

    /// Counts, kinds, total size, newest items, the listing and short previews of documents.
    public static func folderReport(_ folder: URL, timeLimit: TimeInterval = 2.5) -> String {
        let started = Date()
        var entries = listing(of: folder)

        // Total size, and the size of each subfolder, within a time budget.
        var total: Int64 = 0
        var fileCount = 0
        var truncated = false
        var subfolderSizes: [String: Int64] = [:]
        let depth = folder.standardizedFileURL.pathComponents.count
        if let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                       options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                if fileCount % 500 == 0, Date().timeIntervalSince(started) > timeLimit {
                    truncated = true
                    break
                }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
                let size = Int64(values.fileSize ?? 0)
                total += size
                fileCount += 1
                let components = url.standardizedFileURL.pathComponents
                if components.count > depth + 1 { subfolderSizes[components[depth], default: 0] += size }
            }
        }
        for index in entries.indices where entries[index].isFolder {
            entries[index].size = subfolderSizes[entries[index].url.lastPathComponent] ?? 0
        }

        let folders = entries.filter(\.isFolder).count
        let files = entries.count - folders
        var kindCounts: [String: Int] = [:]
        for entry in entries where !entry.isFolder { kindCounts[entry.kind, default: 0] += 1 }
        let kinds = kindCounts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { plural($0.key, $0.value) }
        let newest = entries.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        let biggest = entries.sorted { $0.size > $1.size }

        var lines: [String] = []
        lines.append("Folder: \(folder.lastPathComponent) (\(abbreviate(folder.path)))")
        lines.append("Directly inside: \(entries.count) items (\(files) files, \(folders) folders).")
        lines.append("Total size: \(truncated ? "at least " : "")\(size(total)) in \(fileCount)\(truncated ? "+" : "") files, counting everything inside subfolders.")
        if !kinds.isEmpty { lines.append("Kinds of files: \(kinds.joined(separator: ", ")).") }
        if !newest.isEmpty {
            lines.append("Newest: " + newest.prefix(5).map { "\($0.url.lastPathComponent) (\(date($0.modified)))" }.joined(separator: "; ") + ".")
        }
        if let top = biggest.first, top.size > 0 {
            lines.append("Biggest: " + biggest.prefix(3).filter { $0.size > 0 }
                .map { "\($0.url.lastPathComponent) (\(size($0.size)))" }.joined(separator: "; ") + ".")
        }
        lines.append("")
        lines.append("Listing, newest first (name | kind | size | modified):")
        for entry in newest.prefix(300) {
            lines.append("- \(entry.url.lastPathComponent) | \(entry.kind) | \(size(entry.size)) | \(date(entry.modified))")
        }
        if entries.count > 300 { lines.append("… and \(entries.count - 300) more.") }

        // Short previews of documents so "any PDFs about taxes?" can look inside, not just at names.
        let readable = newest.filter { ["PDF", "document", "text file", "code", "spreadsheet"].contains($0.kind) && $0.size < 8_000_000 }
        var previews: [String] = []
        for entry in readable.prefix(15) {
            if Date().timeIntervalSince(started) > timeLimit + 1.5 { break }
            if let text = textContents(of: entry.url, limit: 400), !text.isEmpty {
                previews.append("[\(entry.url.lastPathComponent)] \(text.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        if !previews.isEmpty {
            lines.append("")
            lines.append("Start of each document:")
            lines.append(contentsOf: previews)
        }
        return String(lines.joined(separator: "\n").prefix(maxTextChars))
    }

    // MARK: Files

    /// A file's facts plus its text (PDF pages marked "[Page N]") or a picture of it.
    public static func fileReport(_ url: URL) -> (text: String, imageJPEG: Data?) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .isPackageKey])
        let fileKind = kind(of: url, isFolder: false)
        let bytes = Int64(values?.fileSize ?? 0)
        var lines = ["File: \(url.lastPathComponent)", "Kind: \(fileKind)", "Size: \(size(bytes))",
                     "Location: \(abbreviate(url.deletingLastPathComponent().path))",
                     "Created: \(date(values?.creationDate))", "Modified: \(date(values?.contentModificationDate))"]
        var image: Data?

        if fileKind == "image" {
            if let preview = jpegPreview(of: url) {
                image = preview.0
                if !preview.1.isEmpty { lines.append("Picture size: \(preview.1)") }
                lines.append("The picture itself is attached.")
            }
        } else if fileKind == "PDF", let document = PDFDocument(url: url) {
            lines.append("Pages: \(document.pageCount)")
            lines.append("")
            var text = ""
            for index in 0..<document.pageCount {
                guard text.count < maxTextChars, let page = document.page(at: index) else { break }
                text += "\n[Page \(index + 1)]\n" + (page.string ?? "")
            }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 * max(1, document.pageCount) / 4,
               let first = document.page(at: 0) {
                // Scanned PDF with no text layer: send a picture of the first page.
                let thumbnail = first.thumbnail(of: CGSize(width: 1400, height: 1800), for: .mediaBox)
                if let tiff = thumbnail.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                    image = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
                    lines.append("This PDF has little or no text; a picture of page 1 is attached.")
                }
            }
            lines.append(String(text.prefix(maxTextChars)))
        } else if bytes <= maxReadBytes, let text = textContents(of: url, limit: maxTextChars), !text.isEmpty {
            lines.append("")
            lines.append("Contents:")
            lines.append(text)
        } else {
            lines.append("June can't read inside this kind of file; describe it from its name, kind, size and dates.")
        }
        return (lines.joined(separator: "\n"), image)
    }

    /// Text of PDFs, Word/RTF/HTML documents, and plain text or code files.
    static func textContents(of url: URL, limit: Int) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return nil }
            var text = ""
            for index in 0..<document.pageCount where text.count < limit {
                text += (document.page(at: index)?.string ?? "") + "\n"
            }
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        let kindName = kind(of: url, isFolder: false)
        guard ["document", "text file", "code", "spreadsheet"].contains(kindName) || ext.isEmpty || ext == "md" else { return nil }
        if let text = DocumentReader.fileText(url) {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        return nil
    }

    private static func jpegPreview(of url: URL) -> (Data, String)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var pixels = ""
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int {
            pixels = "\(width) × \(height) pixels"
        }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1600,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.75]) else { return nil }
        return (jpeg, pixels)
    }

    // MARK: Formatting

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date?) -> String {
        guard let date else { return "unknown date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
