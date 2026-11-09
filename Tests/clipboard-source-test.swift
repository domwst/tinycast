import AppKit
import Foundation

/// Compiles the shipped attribution sources: who a copy came from, and the log line naming it.
@main
@MainActor
struct ClipboardSourceTest {
    static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static func main() async {
        enclosingBundles()
        blocking()
        recording()
        parsing()
        processPaths()
        typingFocus()
        await liveStream()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Model

    static func enclosingBundles() {
        let helper =
            "/System/Applications/Passwords.app/Contents/Library/LoginItems/"
            + "PasswordsMenuBarExtra.app/Contents/MacOS/PasswordsMenuBarExtra"
        check(
            "a login item names itself, then the app it ships inside",
            ClipboardSource.enclosingAppBundles(ofExecutable: helper) == [
                "/System/Applications/Passwords.app/Contents/Library/LoginItems/"
                    + "PasswordsMenuBarExtra.app",
                "/System/Applications/Passwords.app"
            ])
        check(
            "a bare tool sits in no app",
            ClipboardSource.enclosingAppBundles(ofExecutable: "/usr/bin/pbcopy").isEmpty)
        check(
            "a folder merely containing .app in its name is not a bundle",
            ClipboardSource.enclosingAppBundles(ofExecutable: "/Users/me/my.apps/tool").isEmpty)
        check(
            "an ordinary app names only itself",
            ClipboardSource.enclosingAppBundles(
                ofExecutable: "/Applications/Zen Browser.app/Contents/MacOS/zen")
                == ["/Applications/Zen Browser.app"])
    }

    static func blocking() {
        let disabled = ["com.apple.Passwords", "com.apple.keychainaccess"]
        let menuBarCopy = ClipboardSource(
            writer: ["com.apple.Passwords.MenuBarExtra", "com.apple.Passwords"],
            typingFocus: [], frontmost: "com.apple.finder")
        check(
            "a menu-bar helper inside a disabled app is blocked whatever is frontmost",
            menuBarCopy.isBlocked(byDisabled: disabled))
        let focusOnly = ClipboardSource(
            writer: [], typingFocus: ["com.apple.Passwords"], frontmost: "com.apple.finder")
        check("the keyboard-focus owner blocks on its own", focusOnly.isBlocked(byDisabled: disabled))
        let frontmostOnly = ClipboardSource(
            writer: ["com.apple.Safari"], typingFocus: [], frontmost: "com.apple.keychainaccess")
        check(
            "a disabled frontmost app still blocks, as it always did",
            frontmostOnly.isBlocked(byDisabled: disabled))
        let ordinary = ClipboardSource(
            writer: ["com.apple.Safari"], typingFocus: [], frontmost: "com.apple.Safari")
        check("an ordinary copy is kept", !ordinary.isBlocked(byDisabled: disabled))
        check("nothing is blocked by an empty list", !menuBarCopy.isBlocked(byDisabled: []))
    }

    static func recording() {
        check(
            "the writer's outermost app is what history records",
            ClipboardSource(
                writer: ["com.apple.dt.Xcode.helper", "com.apple.dt.Xcode"], frontmost: "com.apple.finder"
            ).recordedBundleID == "com.apple.dt.Xcode")
        check(
            "a writer in no app falls back to the frontmost app",
            ClipboardSource(writer: [], frontmost: "com.apple.Terminal").recordedBundleID
                == "com.apple.Terminal")
        check("no witness at all records nothing", ClipboardSource().recordedBundleID == nil)
    }

    // MARK: - The pboard log line

    static func parsing() {
        let general = PasteboardOwnerMonitor.generalPasteboardName
        check(
            "the shipped pasteboard name is NSPasteboard.general's",
            general == NSPasteboard.Name.general.rawValue)
        let observed =
            "Apple CFPasteboard general has new generation 1187 with owner "
            + "<_CFPasteboardClientInstanceID: 0x7add08c000> - process: zen - pid: 62045 - uuid: AB3F65"
        let parsed = PasteboardOwnerMonitor.parse(message: observed, pasteboard: general)
        check("a generation line yields its generation", parsed?.generation == 1187)
        check("a generation line yields the writer's pid", parsed?.owner.pid == 62045)
        check("a generation line yields the writer's name", parsed?.owner.process == "zen")
        let spaced =
            "Apple CFPasteboard general has new generation 9 with owner <x> "
            + "- process: Passwords Menu Bar - pid: 4242 - uuid: 1"
        check(
            "a process name with spaces survives",
            PasteboardOwnerMonitor.parse(message: spaced, pasteboard: general)?.owner.process
                == "Passwords Menu Bar")
        let other = observed.replacingOccurrences(of: "general", with: "find")
        check(
            "another pasteboard's generation is ignored",
            PasteboardOwnerMonitor.parse(message: other, pasteboard: general) == nil)
        let lookalike = observed.replacingOccurrences(of: "general has", with: "generalized has")
        check(
            "a pasteboard whose name only starts the same is ignored",
            PasteboardOwnerMonitor.parse(message: lookalike, pasteboard: general) == nil)
        check(
            "a line without a pid is ignored",
            PasteboardOwnerMonitor.parse(
                message: "Apple CFPasteboard general has new generation 3 with owner <x>",
                pasteboard: general) == nil)
        let event = try? JSONSerialization.data(
            withJSONObject: ["eventMessage": observed, "processImagePath": "/usr/libexec/pboard"])
        check(
            "an ndjson event from the daemon parses through its eventMessage",
            event.flatMap { PasteboardOwnerMonitor.parse(line: $0, pasteboard: general) }?
                .owner.pid == 62045)
        let impostor = try? JSONSerialization.data(
            withJSONObject: ["eventMessage": observed, "processImagePath": "/tmp/evil/pboard"])
        check(
            "a process merely named pboard is not the daemon",
            impostor.flatMap { PasteboardOwnerMonitor.parse(line: $0, pasteboard: general) } == nil)
        // A pasteboard named to look like a whole record, which the daemon echoes before its own.
        let injected =
            "Apple CFPasteboard general has new generation 5 with owner <a> - process: Safe - pid: 1 "
            + "- uuid: X has new generation 1187 with owner <b> - process: zen - pid: 62045 - uuid: Y"
        check(
            "a name carrying a second record makes the line ambiguous, so it is dropped",
            PasteboardOwnerMonitor.parse(message: injected, pasteboard: general) == nil)
        let doubledPid =
            "Apple CFPasteboard general has new generation 9 with owner <x> "
            + "- process: evil - pid: 1 - pid: 4242 - uuid: 1"
        check(
            "a process named to smuggle a pid is dropped",
            PasteboardOwnerMonitor.parse(message: doubledPid, pasteboard: general) == nil)
        check(
            "trailing junk after the pid is dropped",
            PasteboardOwnerMonitor.parse(message: observed.replacingOccurrences(of: " - uuid: AB3F65", with: "99x"),
                pasteboard: general) == nil)
        check(
            "log's banner line is not an event",
            PasteboardOwnerMonitor.parse(
                line: Data("Filtering the log data using \"process == pboard\"".utf8),
                pasteboard: general) == nil)
    }

    // MARK: - Platform

    static func processPaths() {
        let own = ProcessExecutable.path(of: getpid()).map { URL(fileURLWithPath: $0) }
        let expected = Bundle.main.executablePath.map { URL(fileURLWithPath: $0) }
        // `proc_pidpath` spells /var as /private/var, so compare the files, not the strings.
        let ownID = (try? own?.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
            .fileResourceIdentifier as? NSObject
        let expectedID = (try? expected?.resourceValues(forKeys: [.fileResourceIdentifierKey]))?
            .fileResourceIdentifier as? NSObject
        check("this process's executable path is found", ownID != nil && ownID == expectedID)
        check("an unused pid has no path", ProcessExecutable.path(of: 999_999) == nil)
    }

    static func typingFocus() {
        let pid = TypingFocus.pid()
        check("the keyboard-focus owner is absent or a real pid", pid.map { $0 > 0 } ?? true)
    }

    /// Against a pasteboard of its own: a harness that wrote the general one would land in history.
    static func liveStream() async {
        let name = "tinycast-source-test-\(UUID().uuidString)"
        let monitor = PasteboardOwnerMonitor(pasteboardName: name)
        monitor.start()
        defer { monitor.stop() }
        try? await Task.sleep(for: .seconds(2))
        guard monitor.isStreaming else {
            print("SKIP  the live log stream: `log stream` is unavailable to this user")
            return
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("probe", forType: .string)
        let generation = pasteboard.changeCount
        var owner: PasteboardOwnerMonitor.Owner?
        for _ in 0..<40 where owner == nil {
            try? await Task.sleep(for: .milliseconds(50))
            owner = monitor.owner(ofGeneration: generation)
        }
        check("the live stream names this process as the writer", owner?.pid == getpid())
        monitor.stop()
        check("stopping ends the stream", !monitor.isStreaming)
        check("stopping forgets every owner", monitor.owner(ofGeneration: generation) == nil)
    }
}
