import ApplicationServices
import Foundation

private typealias GetTypingFocus = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
private typealias MainConnection = @convention(c) () -> Int32
private typealias ConnectionForPSN =
    @convention(c) (Int32, UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>) -> Int32
private typealias ConnectionPID = @convention(c) (Int32, UnsafeMutablePointer<pid_t>) -> Int32

/// The process WindowServer sends keystrokes to, which a menu-bar panel holds without activating.
enum TypingFocus {
    /// nil when SkyLight lacks a symbol or no process other than the frontmost holds the focus.
    static func pid() -> pid_t? {
        guard let symbols = Symbols() else { return nil }
        var psn = ProcessSerialNumber()
        guard symbols.typingFocus(&psn) == 0, psn.highLongOfPSN != 0 || psn.lowLongOfPSN != 0
        else { return nil }
        var connection: Int32 = 0
        var pid: pid_t = 0
        guard symbols.connectionForPSN(symbols.mainConnection(), &psn, &connection) == 0,
            symbols.connectionPID(connection, &pid) == 0, pid > 0
        else { return nil }
        return pid
    }
}

private struct Symbols {
    let typingFocus: GetTypingFocus
    let mainConnection: MainConnection
    let connectionForPSN: ConnectionForPSN
    let connectionPID: ConnectionPID

    /// SkyLight stays loaded once any AppKit process has linked it, so this resolves from cache.
    init?() {
        guard
            let skyLight = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let typingFocus = dlsym(skyLight, "SLPSGetTypingFocusProcess"),
            let mainConnection = dlsym(skyLight, "SLSMainConnectionID"),
            let connectionForPSN = dlsym(skyLight, "SLSGetConnectionIDForPSN"),
            let connectionPID = dlsym(skyLight, "SLSConnectionGetPID")
        else { return nil }
        self.typingFocus = unsafeBitCast(typingFocus, to: GetTypingFocus.self)
        self.mainConnection = unsafeBitCast(mainConnection, to: MainConnection.self)
        self.connectionForPSN = unsafeBitCast(connectionForPSN, to: ConnectionForPSN.self)
        self.connectionPID = unsafeBitCast(connectionPID, to: ConnectionPID.self)
    }
}
