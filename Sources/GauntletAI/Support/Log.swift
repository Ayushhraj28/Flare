import Foundation

/// Plain-text log at ~/Library/Logs/Gauntlet/june.log. Never writes the API key.
public enum JuneLog {
    private static let queue = DispatchQueue(label: "june.log")
    private static let url: URL? = {
        guard let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return nil }
        let dir = lib.appendingPathComponent("Logs/Gauntlet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("june.log")
    }()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Debug builds also keep a copy in the project's git-ignored .june/ folder, and print it.
    private static let devURL: URL? = {
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = repo.appendingPathComponent(".june", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return dir.appendingPathComponent("june.log")
        #else
        return nil
        #endif
    }()

    public static func write(_ line: String) {
        let stamped = "\(formatter.string(from: Date())) \(line)\n"
        #if DEBUG
        print("[June] \(line)")
        #endif
        queue.async {
            if let devURL, let data = stamped.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: devURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                } else {
                    try? data.write(to: devURL)
                }
            }
            guard let url, let data = stamped.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
