import Foundation
import Synchronization

/// Names the process behind each general-pasteboard generation, from `pboard`'s own debug log.
final class PasteboardOwnerMonitor: Sendable {
    struct Owner: Sendable, Equatable {
        let pid: pid_t
        let process: String
    }

    /// What `NSPasteboard.general` is called inside `pboard`; its generation is `changeCount`.
    static let generalPasteboardName = "Apple CFPasteboard general"

    /// Injected so a harness can watch a pasteboard of its own rather than the reader's clipboard.
    let pasteboardName: String

    init(pasteboardName: String = PasteboardOwnerMonitor.generalPasteboardName) {
        self.pasteboardName = pasteboardName
    }

    var predicate: String {
        "process == \"pboard\" AND eventMessage BEGINSWITH \"\(pasteboardName) has new generation \""
    }

    private static let retainedGenerations = 64
    /// A `log` that dies this fast is refused, not crashed; retrying it is pointless.
    private static let minimumHealthyLifetime: TimeInterval = 5
    private static let maximumQuickFailures = 3
    private static let restartDelay: TimeInterval = 10

    private struct State: ~Copyable {
        var process: Process?
        var wanted = false
        var streaming = false
        var quickFailures = 0
        var buffer = Data()
        var owners: [Int: Owner] = [:]
        var order: [Int] = []
    }

    private let state = Mutex(State())

    deinit {
        state.withLock { $0.process?.terminate() }
    }

    /// True while a stream is running, so a caller may wait one beat for a generation's line.
    var isStreaming: Bool { state.withLock { $0.streaming } }

    func owner(ofGeneration generation: Int) -> Owner? {
        state.withLock { $0.owners[generation] }
    }

    func start() {
        let shouldLaunch = state.withLock { state -> Bool in
            guard !state.wanted else { return false }
            state.wanted = true
            state.quickFailures = 0
            return true
        }
        if shouldLaunch { launch() }
    }

    func stop() {
        let process = state.withLock { state -> Process? in
            state.wanted = false
            state.streaming = false
            state.owners = [:]
            state.order = []
            defer { state.process = nil }
            return state.process
        }
        process?.terminate()
    }

    private func launch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "stream", "--level", "debug", "--style", "ndjson", "--predicate", predicate
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(chunk)
        }
        let launched = Date()
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            self?.ended(after: Date().timeIntervalSince(launched))
        }
        let accepted = state.withLock { state -> Bool in
            guard state.wanted, state.process == nil else { return false }
            state.process = process
            return true
        }
        guard accepted else { return }
        do {
            try process.run()
            state.withLock { $0.streaming = $0.process === process }
        } catch {
            state.withLock { state in
                if state.process === process { state.process = nil }
                state.wanted = false
            }
        }
    }

    private func ended(after lifetime: TimeInterval) {
        let retry = state.withLock { state -> Bool in
            state.process = nil
            state.streaming = false
            state.buffer = Data()
            guard state.wanted else { return false }
            state.quickFailures =
                lifetime < Self.minimumHealthyLifetime ? state.quickFailures + 1 : 0
            if state.quickFailures >= Self.maximumQuickFailures { state.wanted = false }
            return state.wanted
        }
        guard retry else { return }
        let delay = DispatchTime.now() + Self.restartDelay
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: delay) { [weak self] in
            self?.relaunchIfWanted()
        }
    }

    private func relaunchIfWanted() {
        guard state.withLock({ $0.wanted && $0.process == nil }) else { return }
        launch()
    }

    private func receive(_ chunk: Data) {
        state.withLock { state in
            state.buffer.append(chunk)
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                let line = state.buffer[state.buffer.startIndex..<newline]
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
                guard let (generation, owner) = Self.parse(line: line, pasteboard: pasteboardName)
                else { continue }
                if state.owners.updateValue(owner, forKey: generation) == nil {
                    state.order.append(generation)
                }
                if state.order.count > Self.retainedGenerations {
                    state.owners[state.order.removeFirst()] = nil
                }
            }
        }
    }

    /// One `ndjson` event; anything else `log` prints, such as its banner, reads as nil.
    static func parse(line: Data, pasteboard: String) -> (generation: Int, owner: Owner)? {
        guard
            let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let message = event["eventMessage"] as? String
        else { return nil }
        return parse(message: message, pasteboard: pasteboard)
    }

    static func parse(message: String, pasteboard: String) -> (generation: Int, owner: Owner)? {
        let lead = pasteboard + " has new generation "
        guard message.hasPrefix(lead),
            let generationStart = message.range(of: lead)?.upperBound,
            let generation = Int(message[generationStart...].prefix(while: \.isNumber)),
            let processStart = message.range(of: " - process: ")?.upperBound,
            let pidRange = message.range(of: " - pid: ", range: processStart..<message.endIndex),
            let pid = pid_t(message[pidRange.upperBound...].prefix(while: \.isNumber)),
            pid > 0
        else { return nil }
        let process = String(message[processStart..<pidRange.lowerBound])
        return (generation, Owner(pid: pid, process: process))
    }
}
