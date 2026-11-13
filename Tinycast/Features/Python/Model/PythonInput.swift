import Foundation

/// The editing rules of the input, kept apart from any view so the harness can check them.
enum PythonInput {
    /// What Return inserts when the driver says the code isn't finished: a newline, indented.
    static func continuation(after code: String) -> String {
        let lastLine = code.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let indent = String(lastLine.prefix { $0 == " " || $0 == "\t" })
        let opensBlock = lastLine.trimmingCharacters(in: .whitespaces).hasSuffix(":")
        return "\n" + indent + (opensBlock ? Self.indentUnit : "")
    }

    static let indentUnit = "    "

    /// An edit's result: the new text and where the caret lands, both in characters.
    struct Edit: Sendable, Equatable {
        let text: String
        let caret: Int
    }

    /// ⇧↵: the selection becomes a newline indented for the line before it.
    static func lineBreak(in text: String, replacing selection: Range<Int>) -> Edit {
        let before = String(text.prefix(selection.lowerBound))
        return replace(selection, in: text, with: continuation(after: before))
    }

    /// ⇥: the selection becomes one level of indent.
    static func indent(in text: String, replacing selection: Range<Int>) -> Edit {
        replace(selection, in: text, with: indentUnit)
    }

    /// ⇧⇥: up to one level of leading spaces comes off the caret's line.
    static func outdent(in text: String, caret: Int) -> Edit {
        let characters = Array(text)
        let caret = min(max(caret, 0), characters.count)
        let lineStart = characters[..<caret].lastIndex(of: "\n").map { $0 + 1 } ?? 0
        let removable = characters[lineStart...].prefix(indentUnit.count).prefix { $0 == " " }.count
        var kept = characters
        kept.removeSubrange(lineStart..<(lineStart + removable))
        return Edit(text: String(kept), caret: max(caret - removable, lineStart))
    }

    /// Where ↑ leaves the input for history: no line above the caret.
    static func isOnFirstLine(_ text: String, caret: Int) -> Bool {
        !text.prefix(caret).contains("\n")
    }

    /// Where ↓ leaves the input for history: no line below the caret.
    static func isOnLastLine(_ text: String, caret: Int) -> Bool {
        !text.dropFirst(caret).contains("\n")
    }

    private static func replace(_ selection: Range<Int>, in text: String, with insertion: String) -> Edit {
        let characters = Array(text)
        let lower = min(max(selection.lowerBound, 0), characters.count)
        let upper = min(max(selection.upperBound, lower), characters.count)
        let result = String(characters[..<lower]) + insertion + String(characters[upper...])
        return Edit(text: result, caret: lower + insertion.count)
    }

    /// The cell as shown and remembered: a block's closing empty lines are only how it was ended.
    static func trimmed(_ code: String) -> String {
        var lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// `py 2**64` or `python 2**64` in the launcher: the code to run, or nil for any other query.
    static func launcherCode(in query: String) -> String? {
        let leading = query.drop { $0.isWhitespace }
        for prefix in launcherPrefixes {
            guard leading.count > prefix.count,
                leading.prefix(prefix.count).lowercased() == prefix,
                let separator = leading.dropFirst(prefix.count).first, separator.isWhitespace
            else { continue }
            let code = leading.dropFirst(prefix.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
            return code.isEmpty ? nil : code
        }
        return nil
    }

    private static let launcherPrefixes = ["python", "py"]
}
