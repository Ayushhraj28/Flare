import Foundation

/// Finds "Hey June" in a live transcript. Speech recognisers often write the name differently
/// ("hey jun", "hey june's", "a june", "hey, june"), so a few close variants count too, depending
/// on the sensitivity setting.
public enum WakePhrase {
    public struct Match: Equatable, Sendable {
        /// Character offset just after the wake phrase in the transcript it was found in.
        public let end: Int
        /// The words that followed it so far (may be empty).
        public let command: String
    }

    static func variants(_ sensitivity: WakeSensitivity) -> [[String]] {
        switch sensitivity {
        case .strict:
            return [["hey", "june"]]
        case .normal:
            return [["hey", "june"], ["hey", "jun"], ["hey", "junie"], ["hi", "june"], ["hey", "joon"], ["okay", "june"], ["ok", "june"]]
        case .loose:
            return [["hey", "june"], ["hey", "jun"], ["hey", "junie"], ["hi", "june"], ["hey", "joon"], ["okay", "june"], ["ok", "june"],
                    ["a", "june"], ["hey", "jude"], ["hey", "joan"], ["june"]]
        }
    }

    /// Looks for the most recent wake phrase in `transcript`. A bare "June" only counts (loose
    /// sensitivity) at the very start of what was said.
    public static func find(in transcript: String, sensitivity: WakeSensitivity) -> Match? {
        // Tokenise with character offsets, lowercased, letters and apostrophes only.
        var tokens: [(word: String, end: Int)] = []
        var current = ""
        var offset = 0
        for ch in transcript {
            offset += 1
            if ch.isLetter || ch == "'" {
                current.append(Character(ch.lowercased()))
            } else if !current.isEmpty {
                tokens.append((current, offset - 1))
                current = ""
            }
        }
        if !current.isEmpty { tokens.append((current, offset)) }
        guard !tokens.isEmpty else { return nil }

        var best: (index: Int, length: Int)?
        for variant in variants(sensitivity) {
            let n = variant.count
            guard tokens.count >= n else { continue }
            for start in stride(from: tokens.count - n, through: 0, by: -1) {
                let words = tokens[start..<(start + n)].map { strip($0.word) }
                guard words == variant else { continue }
                if n == 1 && start != 0 { continue }          // bare "June" only at the start
                if best == nil || start > best!.index { best = (start, n) }
                break
            }
        }
        guard let found = best else { return nil }
        let endOffset = tokens[found.index + found.length - 1].end
        let rest = String(transcript.dropFirst(endOffset))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.:;!?-").union(.whitespacesAndNewlines))
        return Match(end: endOffset, command: rest)
    }

    private static func strip(_ word: String) -> String {
        word.hasSuffix("'s") ? String(word.dropLast(2)) : word
    }
}
