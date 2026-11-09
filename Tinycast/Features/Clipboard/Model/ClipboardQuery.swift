import Foundation

/// A history search: whitespace-separated terms, every one required, in any order.
struct ClipboardQuery: Sendable, Equatable {
    /// Shorter terms stay literal: one edit away from a three-letter word is most of the language.
    static let minimumLooseTermLength = 4

    let terms: [String]
    /// Each term folded once, so matching a row is byte comparison and nothing else.
    private let folded: [[UInt8]]

    init(_ raw: String) {
        terms = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        folded = terms.map(Self.fold)
    }

    var isEmpty: Bool { terms.isEmpty }

    /// Case- and diacritic-insensitive bytes; ASCII is lowered in place, the rest goes to Foundation.
    static func fold(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        if bytes.allSatisfy({ $0 < 0x80 }) {
            for index in bytes.indices where bytes[index] >= 65 && bytes[index] <= 90 {
                bytes[index] += 32
            }
            return bytes
        }
        return Array(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
    }

    /// Case- and diacritic-insensitive substrings, so `cafe` finds `Café`.
    func matchesExactly(_ text: String?) -> Bool {
        text.map { matchesExactly(folded: Self.fold($0)) } ?? false
    }

    func matchesExactly(folded text: [UInt8]) -> Bool {
        !folded.isEmpty && folded.allSatisfy { Self.contains(text, $0) }
    }

    /// Each term found as a substring or, failing that, within a typo of one word of `text`.
    func matchesLoosely(_ text: String?) -> Bool {
        text.map { matchesLoosely(folded: Self.fold($0)) } ?? false
    }

    func matchesLoosely(folded text: [UInt8]) -> Bool {
        guard !folded.isEmpty else { return false }
        for (index, term) in folded.enumerated() where !Self.contains(text, term) {
            let isLast = index == folded.count - 1
            guard Self.allowsTypos(term), Self.containsNear(term, in: text, prefix: isLast) else {
                return false
            }
        }
        return true
    }

    /// Edits tolerated for a term: one up to seven letters, two from eight.
    static func allowedEdits(_ length: Int) -> Int {
        length >= 8 ? 2 : 1
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard haystack.count >= needle.count else { return false }
        return haystack.withUnsafeBytes { text in
            needle.withUnsafeBytes { term in
                memmem(text.baseAddress, text.count, term.baseAddress, term.count) != nil
            }
        }
    }

    /// Ideographic scripts write words without spaces, so a "word" there is a whole sentence.
    private static func allowsTypos(_ term: [UInt8]) -> Bool {
        let scalars = (String(bytes: term, encoding: .utf8) ?? "").unicodeScalars
        return scalars.count >= minimumLooseTermLength
            && scalars.allSatisfy { $0.value < 0x2E80 && ($0.properties.isAlphabetic || isDigit($0)) }
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType == .decimal
    }

    /// ASCII terms compare bytes; any other script compares scalars, or one letter is two edits.
    private static func containsNear(_ term: [UInt8], in text: [UInt8], prefix: Bool) -> Bool {
        guard term.allSatisfy({ $0 < 0x80 }) else {
            let scalars = Array((String(bytes: term, encoding: .utf8) ?? "").unicodeScalars)
            return words(in: text).contains { isNear(scalars, $0[...], prefix: prefix) }
        }
        return term.withUnsafeBufferPointer { term in
            text.withUnsafeBufferPointer { buffer in
                var start: Int?
                for index in 0...buffer.count {
                    if index < buffer.count, isWordByte(buffer[index]) {
                        if start == nil { start = index }
                        continue
                    }
                    guard let first = start else { continue }
                    start = nil
                    if isNear(term, UnsafeBufferPointer(rebasing: buffer[first..<index]), prefix: prefix) {
                        return true
                    }
                }
                return false
            }
        }
    }

    /// The byte twin of the generic `isNear`: no array is built for the words a row holds.
    private static func isNear(
        _ term: UnsafeBufferPointer<UInt8>, _ word: UnsafeBufferPointer<UInt8>, prefix: Bool
    ) -> Bool {
        let edits = allowedEdits(term.count)
        if abs(word.count - term.count) <= edits, distance(term, word, limit: edits) <= edits {
            return true
        }
        guard prefix, word.count > term.count else { return false }
        for length in max(1, term.count - edits)...min(word.count, term.count + edits)
        where distance(term, UnsafeBufferPointer(rebasing: word[0..<length]), limit: edits) <= edits {
            return true
        }
        return false
    }

    /// Multi-byte UTF-8 stays inside a word, so an accented word is not split at its accent.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122) || byte >= 0x80
    }

    private static func words(in text: [UInt8]) -> [[Unicode.Scalar]] {
        var words: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in (String(bytes: text, encoding: .utf8) ?? "").unicodeScalars {
            if scalar.properties.isAlphabetic || isDigit(scalar) {
                current.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// The last term is still being typed, so it may also match the start of a longer word.
    private static func isNear<Element: Equatable>(
        _ term: some Collection<Element>, _ word: some Collection<Element>, prefix: Bool
    ) -> Bool {
        let edits = allowedEdits(term.count)
        if abs(word.count - term.count) <= edits, distance(term, word, limit: edits) <= edits {
            return true
        }
        guard prefix, word.count > term.count else { return false }
        for length in max(1, term.count - edits)...min(word.count, term.count + edits)
        where distance(term, word.prefix(length), limit: edits) <= edits {
            return true
        }
        return false
    }

    static func distance<Element: Equatable>(
        _ a: some Collection<Element>, _ b: some Collection<Element>, limit: Int
    ) -> Int {
        Array(a).withUnsafeBufferPointer { a in
            Array(b).withUnsafeBufferPointer { b in distance(a, b, limit: limit) }
        }
    }

    /// Optimal-string-alignment distance, abandoned once a whole row exceeds `limit`.
    static func distance<Element: Equatable>(
        _ a: UnsafeBufferPointer<Element>, _ b: UnsafeBufferPointer<Element>, limit: Int
    ) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        let width = b.count + 1
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: width * 3) { rows in
            for j in 0..<width {
                rows[width + j] = j
                rows[j] = 0
            }
            var previous2 = 0
            var previous = width
            var current = width * 2
            for i in 1...a.count {
                rows[current] = i
                var rowMinimum = i
                for j in 1...b.count {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    var value = min(
                        rows[previous + j] + 1, rows[current + j - 1] + 1, rows[previous + j - 1] + cost)
                    if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                        value = min(value, rows[previous2 + j - 2] + 1)
                    }
                    rows[current + j] = value
                    rowMinimum = min(rowMinimum, value)
                }
                if rowMinimum > limit { return limit + 1 }
                (previous2, previous, current) = (previous, current, previous2)
            }
            return rows[previous + b.count]
        }
    }
}
