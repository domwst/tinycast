import Foundation

/// Who a copy may have come from. The pasteboard records no source, so three witnesses vote.
struct ClipboardSource: Sendable, Equatable {
    /// Bundle IDs of the writing process's app and every app enclosing it, innermost first.
    var writer: [String] = []
    /// The same chain for the process holding keyboard focus, which a menu-bar panel can own.
    var typingFocus: [String] = []
    var frontmost: String?

    /// Any witness, or any app containing one, being disabled is enough to drop the copy.
    func isBlocked(byDisabled disabled: some Sequence<String>) -> Bool {
        let disabled = Set(disabled)
        return (writer + typingFocus + [frontmost].compactMap(\.self)).contains(where: disabled.contains)
    }

    /// The outermost app holding the writer, so a helper inside `Xcode.app` reads as Xcode.
    var recordedBundleID: String? {
        writer.last ?? frontmost
    }

    /// Every `.app` an executable sits inside, innermost first, so a login item names its parent.
    static func enclosingAppBundles(ofExecutable path: String) -> [String] {
        var bundles: [String] = []
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            prefix += "/" + component
            if component.hasSuffix(".app") { bundles.append(prefix) }
        }
        return bundles.reversed()
    }
}
