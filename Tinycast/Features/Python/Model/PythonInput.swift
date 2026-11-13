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
