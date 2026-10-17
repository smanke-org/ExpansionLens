import CryptoKit
import Foundation

/// Notices sentences you type again and again, to offer them as snippets.
///
/// Only a count per sentence is kept, under a SHA-256 of its text. The text itself is
/// remembered only once a sentence has come up `threshold` times and becomes a suggestion.
public struct PhraseTracker: Codable, Equatable, Sendable {
    public var counts: [String: Int] = [:]
    public var suggestions: [Suggestion] = []
    /// Hashes of suggestions turned down, never offered again.
    public var rejected: Set<String> = []

    public var threshold = 3
    public var minimumWords = 4
    public var maximumWords = 40
    /// Counts kept at most, so the table can't grow without end.
    public var capacity = 5_000

    public init() {}

    public static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(normalize(text).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Records a finished sentence. Returns the suggestion if this made one.
    @discardableResult
    public mutating func record(_ sentence: String, now: Date = Date()) -> Suggestion? {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= minimumWords, words.count <= maximumWords, text.count >= 20 else { return nil }
        let key = Self.hash(text)
        guard !rejected.contains(key) else { return nil }
        if let i = suggestions.firstIndex(where: { $0.hash == key }) {
            suggestions[i].count += 1
            suggestions[i].lastSeen = now
            return nil
        }
        let count = (counts[key] ?? 0) + 1
        counts[key] = count
        if counts.count > capacity {
            // Forget the rarest first.
            for (k, _) in counts.sorted(by: { $0.value < $1.value }).prefix(counts.count - capacity) { counts[k] = nil }
        }
        guard count >= threshold else { return nil }
        counts[key] = nil
        let suggestion = Suggestion(hash: key, text: text, count: count, lastSeen: now)
        suggestions.append(suggestion)
        return suggestion
    }

    public mutating func reject(_ hash: String) {
        rejected.insert(hash)
        suggestions.removeAll { $0.hash == hash }
    }

    public mutating func remove(_ hash: String) {
        suggestions.removeAll { $0.hash == hash }
    }
}

/// Fixes capitalization as you type: a capital at the start of a sentence, and words typed
/// with two leading capitals ("THe").
public enum AutoCapitalizer {
    public struct Fix: Equatable, Sendable {
        /// Characters to erase (the word).
        public var eraseCount: Int
        public var replacement: String
    }

    /// `before` is what was typed ahead of `word`; `word` was just ended by a delimiter.
    /// `contraction` lists extra characters that belong inside words (the apostrophe always does).
    public static func fix(word: String, before: String, sentences: Bool, doubleCaps: Bool,
                           contraction: Set<Character> = []) -> Fix? {
        let inWord: Set<Character> = contraction.union(["'", "’"])
        guard word.count >= 2, word.allSatisfy({ $0.isLetter || inWord.contains($0) }) else { return nil }
        var fixed = word
        if doubleCaps {
            let letters = Array(word)
            if letters.count >= 3, letters[0].isUppercase, letters[1].isUppercase,
               letters[2...].contains(where: \.isLowercase), letters[2...].allSatisfy({ !$0.isUppercase }) {
                fixed = String(letters[0]) + String(letters[1...]).lowercased()
            }
        }
        if sentences, startsSentence(before), let first = fixed.first, first.isLowercase {
            fixed = first.uppercased() + fixed.dropFirst()
        }
        return fixed == word ? nil : Fix(eraseCount: word.count, replacement: fixed)
    }

    /// Whether the next word begins a sentence: after ". ", "! ", "? " or a new line. An empty
    /// `before` (nothing seen since the last reset) isn't counted, since the cursor could be anywhere.
    static func startsSentence(_ before: String) -> Bool {
        let trimmed = before.reversed().drop(while: { $0 == " " })
        guard trimmed.count < before.count || before.hasSuffix("\n") else { return false }
        guard let last = trimmed.first else { return false }
        if last == "\n" { return true }
        guard ".!?".contains(last) else { return false }
        // "e.g. this" and "3.5 x" aren't sentence ends.
        let token = String(trimmed.dropFirst().prefix(while: { !$0.isWhitespace }).reversed())
        if token.isEmpty { return false }
        if token.contains(".") || token.count == 1 { return false }
        return true
    }
}
