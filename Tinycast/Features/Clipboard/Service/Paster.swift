import AppKit
import Carbon.HIToolbox

enum Paster {
    /// Stamped on Tinycast's own synthetic keystrokes so the snippet keyword tap can skip them.
    static let tinycastEventTag: Int64 = 0x54494E59

    /// Covers the gap between `activate()` returning and the target app accepting a keystroke.
    private static let activationDelay: TimeInterval = 0.08

    /// Shorter: no activation to wait on, only the pasteboard write reaching the target's process.
    private static let directPostDelay: TimeInterval = 0.05

    /// How long a slow app may take to come forward before the paste is dropped, not misplaced.
    private static let activationLimit: TimeInterval = 0.5

    /// Write the item and paste it into `previousApp`, activating it so ⌘V lands there.
    @MainActor @discardableResult
    static func paste(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?
    ) -> Bool {
        guard write(item, store: store) else { return false }
        store.promote(item)
        activateAndPaste(into: previousApp)
        return true
    }

    /// Paste only the item's text, so a file arrives as its path and the receiver's style applies.
    @MainActor @discardableResult
    static func pastePlainText(
        _ item: ClipboardItem, store: ClipboardStore, previousApp: NSRunningApplication?
    ) -> Bool {
        guard let text = item.plainText else { return false }
        pasteString(text, previousApp: previousApp)
        store.promote(item)
        return true
    }

    /// Put the item on the pasteboard without pasting; the marker stops re-capture.
    @MainActor @discardableResult
    static func copy(_ item: ClipboardItem, store: ClipboardStore) -> Bool {
        guard write(item, store: store) else { return false }
        store.promote(item)
        return true
    }

    /// Put a string on the pasteboard unmarked, so it enters history like any other copy.
    @MainActor @discardableResult
    static func copyPlainText(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        ClipboardExports.discardPasteboardCopies()
        pb.clearContents()
        pb.declareTypes([.string], owner: nil)
        return pb.setString(text, forType: .string)
    }

    /// String counterpart of `paste`, marker-stamped so the text doesn't re-enter history.
    @MainActor
    static func pasteString(_ text: String, previousApp: NSRunningApplication?) {
        writeString(text)
        activateAndPaste(into: previousApp)
    }

    @MainActor
    static func pasteFile(_ url: URL, previousApp: NSRunningApplication?) {
        ClipboardExports.discardPasteboardCopies()
        PasteboardFiles.write(url, to: .general)
        activateAndPaste(into: previousApp)
    }

    @MainActor
    static func copyString(_ text: String) {
        writeString(text)
    }

    /// String counterpart of `pasteInPlace`; the palette stays frontmost.
    @MainActor
    static func pasteStringInPlace(_ text: String, into app: NSRunningApplication?) {
        writeString(text)
        guard let pid = app?.processIdentifier else { return }
        let generation = NSPasteboard.general.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + directPostDelay) {
            guard NSPasteboard.general.changeCount == generation else { return }
            postCommandV(toPid: pid)
        }
    }

    /// ⌘V goes to the HID tap, so it lands wherever focus is; it waits for `app` or is dropped.
    @MainActor
    private static func activateAndPaste(into app: NSRunningApplication?) {
        let generation = NSPasteboard.general.changeCount
        app?.activate()
        let deadline = Date().addingTimeInterval(activationLimit)
        DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
            postCommandV(into: app?.processIdentifier, generation: generation, until: deadline)
        }
    }

    @MainActor
    private static func postCommandV(into pid: pid_t?, generation: Int, until deadline: Date) {
        // Another copy in the wait means what would land is no longer what was chosen.
        guard NSPasteboard.general.changeCount == generation else { return }
        guard let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else {
            return postCommandV()
        }
        guard Date() < deadline else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            postCommandV(into: pid, generation: generation, until: deadline)
        }
    }

    @MainActor
    private static func writeString(_ text: String) {
        let pb = NSPasteboard.general
        ClipboardExports.discardPasteboardCopies()
        pb.clearContents()
        pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setData(Data(), forType: ClipboardManager.internalType)
    }

    /// Paste into `app` without activating or promoting, so the palette and its rows hold still.
    @MainActor @discardableResult
    static func pasteInPlace(
        _ item: ClipboardItem, store: ClipboardStore, into app: NSRunningApplication?
    ) -> Bool {
        guard write(item, store: store) else { return false }
        if let pid = app?.processIdentifier {
            let generation = NSPasteboard.general.changeCount
            DispatchQueue.main.asyncAfter(deadline: .now() + directPostDelay) {
                guard NSPasteboard.general.changeCount == generation else { return }
                postCommandV(toPid: pid)
            }
        }
        return true
    }

    /// Whether anything was written; a vanished item leaves the pasteboard untouched.
    @MainActor @discardableResult
    static func write(
        _ item: ClipboardItem, store: ClipboardStore, to pb: NSPasteboard = .general
    ) -> Bool {
        if pb == .general { ClipboardExports.discardPasteboardCopies() }
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pb.clearContents()
            pb.declareTypes([.string, ClipboardManager.internalType], owner: nil)
            pb.setString(text, forType: .string)
        case .image:
            guard let data = store.imageData(for: item) else { return false }
            let entry = NSPasteboardItem()
            entry.setData(data, forType: .png)
            entry.setData(Data(), forType: ClipboardManager.internalType)
            let generation = pb.clearContents()
            // A text-only receiver ignores image data but pastes a file URL as its path.
            ClipboardImageFileProvider.attach(data, to: entry, generation: generation)
            guard pb.writeObjects([entry]) else { return false }
            if pb == .general { ClipboardExports.belong(toGeneration: pb.changeCount) }
            return true
        case .file:
            guard let url = store.fileURL(for: item),
                FileManager.default.fileExists(atPath: url.path)
            else { return false }
            pb.clearContents()
            pb.declareTypes([.fileURL, .string, ClipboardManager.internalType], owner: nil)
            pb.setData(url.dataRepresentation, forType: .fileURL)
            // Both types: a file-taking app receives the file, a text field receives the path.
            pb.setString(url.path, forType: .string)
        }
        pb.setData(Data(), forType: ClipboardManager.internalType)
        return true
    }

    @MainActor
    static func postCommandV(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_V), toPid: pid)
    }

    /// Synthesize ⌘C, for reading a selection an app will not surface over Accessibility.
    @MainActor
    static func postCommandC(toPid pid: pid_t? = nil) {
        postCommand(key: CGKeyCode(kVK_ANSI_C), toPid: pid)
    }

    @MainActor
    private static func postCommand(key: CGKeyCode, toPid pid: pid_t?) {
        guard Permissions.ensureAccessibility() else { return }
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: tinycastEventTag)
        up.setIntegerValueField(.eventSourceUserData, value: tinycastEventTag)

        if let pid {
            down.postToPid(pid)
            up.postToPid(pid)
        } else {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
