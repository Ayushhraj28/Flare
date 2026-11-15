import Foundation
import Security

/// Where the Gemini key lives: the Keychain (saved from Settings › June) first, then the
/// GEMINI_API_KEY environment variable. The key is never written to disk in plain text or logged.
public enum GeminiKey {
    static let service = "dev.sunhacks.gauntlet"
    static let account = "gemini-api-key"

    public static func load() -> String? {
        #if DEBUG
        if let developerKey { return developerKey }
        #endif
        return keychainKey() ?? environmentKey()
    }

    #if DEBUG
    /// Debug builds read GEMINI_API_KEY from the project's git-ignored .env, so rebuilding from Xcode
    /// doesn't make macOS ask for Keychain access every time. Release builds never look at it.
    static let developerKey: String? = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: repo.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "GEMINI_API_KEY" {
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }()
    #endif

    // The Keychain is read once per launch and kept in memory: every read can make macOS ask for
    // permission (each debug rebuild counts as a new app to the Keychain).
    private static let cacheLock = NSLock()
    private static var cached: String??

    static func cachedKeychainKey() -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cached { return cached }
        let value = readKeychain()
        cached = .some(value)
        return value
    }

    private static func resetCache(_ value: String?) {
        cacheLock.lock(); cached = .some(value); cacheLock.unlock()
    }

    /// "Keychain", "GEMINI_API_KEY", or nil when there is no key.
    public static var source: String? {
        #if DEBUG
        if developerKey != nil { return "GEMINI_API_KEY" }
        #endif
        if keychainKey() != nil { return "Keychain" }
        if environmentKey() != nil { return "GEMINI_API_KEY" }
        return nil
    }

    static func environmentKey() -> String? {
        guard let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !env.isEmpty, !env.hasPrefix("<"), env != "paste-your-key-here" else { return nil }
        return env
    }

    static func keychainKey() -> String? { cachedKeychainKey() }

    private static func readKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    @discardableResult
    public static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { resetCache(nil); return true }
        var add = base
        add[kSecValueData as String] = data
        let ok = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        resetCache(ok ? trimmed : nil)
        return ok
    }

    public static var hasKey: Bool { load() != nil }

    /// Moves a key left in one of `files` (default: Application Support/Gauntlet/gemini-key.txt) into
    /// the Keychain and deletes the file. Lets a key be handed to the app without typing it.
    @discardableResult
    public static func importKeyFile(from extra: [URL] = []) -> Bool {
        var files = extra
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            files.append(support.appendingPathComponent("Gauntlet/gemini-key.txt"))
        }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: file)
            guard !key.isEmpty, save(key) else { continue }
            JuneLog.write("imported a Gemini key into the Keychain")
            return true
        }
        return false
    }
}
