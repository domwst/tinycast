import Foundation
import Synchronization

/// Names the process behind each general-pasteboard generation, from `pboard`'s own debug log.
final class PasteboardOwnerMonitor: Sendable {
    struct Owner: Sendable, Equatable {
        let pid: pid_t
        let process: String
        /// Resolved as the line arrives, since a short-lived writer may be gone by the next poll.
        var executable: String?
    }

    /// What `NSPasteboard.general` is called inside `pboard`; its generation is `changeCount`.
    static let generalPasteboardName = "Apple CFPasteboard general"
    /// The daemon itself, by path: a process merely named `pboard` must not speak for it.
    static let daemonPath = "/usr/libexec/pboard"

    /// Injected so a harness can watch a pasteboard of its own rather than the reader's clipboard.
    let pasteboardName: String

    init(pasteboardName: String = PasteboardOwnerMonitor.generalPasteboardName) {
        self.pasteboardName = pasteboardName
    }

    var predicate: String {
        "processImagePath == \"\(Self.daemonPath)\" AND eventMessage BEGINSWITH "
            + "\"\(pasteboardName) has new generation \""
    }

    private static let retainedGenerations = 64
    /// A `log` that dies this fast is refused, not crashed; retrying it is pointless.
    private static let minimumHealthyLifetime: TimeInterval = 5
    private static let maximumQuickFailures = 3
    private static let restartDelay: TimeInterval = 10
    /// Past any line `pboard` writes; a longer one is dropped rather than buffered.
    private static let maximumLineBytes = 16 * 1024

    /// Two different owners claimed for one generation means one was forged: neither is trusted.
    private enum Record: Sendable {
        case owner(Owner)
        case conflicted
    }

    private struct State: ~Copyable {
        var process: Process?
        var wanted = false
        var streaming = false
        var quickFailures = 0
        var buffer = Data()
        var records: [Int: Record] = [:]
        var order: [Int] = []
    }

    private let state = Mutex(State())

    deinit {
        state.withLock { state in
            if let process = state.process, process.isRunning { process.terminate() }
        }
    }

    /// True while a stream is running, so a caller may wait one beat for a generation's line.
    var isStreaming: Bool { state.withLock { $0.streaming } }

    /// nil when no line named the generation, or more than one owner claimed it.
    func owner(ofGeneration generation: Int) -> Owner? {
        state.withLock { state in
            guard case .owner(let owner) = state.records[generation] else { return nil }
            return owner
        }
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
            state.records = [:]
            state.order = []
            state.buffer = Data()
            defer { state.process = nil }
            return state.process
        }
        // `terminate()` raises on a process not yet run; `launch` catches that case itself.
        if let process, process.isRunning { process.terminate() }
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
        let identity = ObjectIdentifier(process)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(chunk, from: identity)
        }
        let launched = Date()
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            self?.ended(identity, after: Date().timeIntervalSince(launched))
        }
        let accepted = state.withLock { state -> Bool in
            guard state.wanted, state.process == nil else { return false }
            state.process = process
            state.buffer = Data()
            return true
        }
        guard accepted else { return }
        do {
            try process.run()
            let current = state.withLock { state -> Bool in
                let current = state.process.map(ObjectIdentifier.init) == identity
                state.streaming = current
                return current
            }
            // A `stop` that ran between publishing and launching found nothing it could end.
            if !current, process.isRunning { process.terminate() }
        } catch {
            state.withLock { state in
                if state.process.map(ObjectIdentifier.init) == identity { state.process = nil }
                state.wanted = false
            }
        }
    }

    /// Only the current stream's exit counts: a superseded one must not clear its successor.
    private func ended(_ identity: ObjectIdentifier, after lifetime: TimeInterval) {
        let retry = state.withLock { state -> Bool in
            guard state.process.map(ObjectIdentifier.init) == identity else { return false }
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

    private func receive(_ chunk: Data, from identity: ObjectIdentifier) {
        let lines = state.withLock { state -> [Data] in
            guard state.process.map(ObjectIdentifier.init) == identity else { return [] }
            state.buffer.append(chunk)
            var lines: [Data] = []
            while let newline = state.buffer.firstIndex(of: 0x0A) {
                lines.append(state.buffer[state.buffer.startIndex..<newline])
                state.buffer.removeSubrange(state.buffer.startIndex...newline)
            }
            if state.buffer.count > Self.maximumLineBytes { state.buffer = Data() }
            return lines
        }
        // Parsed and resolved outside the lock: `proc_pidpath` is a syscall per line.
        let parsed = lines.compactMap { line -> (Int, Owner)? in
            guard line.count <= Self.maximumLineBytes,
                let parsed = Self.parse(line: line, pasteboard: pasteboardName)
            else { return nil }
            var owner = parsed.owner
            owner.executable = ProcessExecutable.path(of: owner.pid)
            return (parsed.generation, owner)
        }
        guard !parsed.isEmpty else { return }
        state.withLock { state in
            guard state.process.map(ObjectIdentifier.init) == identity else { return }
            for (generation, owner) in parsed { Self.record(owner, for: generation, in: &state) }
        }
    }

    private static func record(_ owner: Owner, for generation: Int, in state: inout State) {
        switch state.records[generation] {
        case nil:
            state.records[generation] = .owner(owner)
            state.order.append(generation)
        case .owner(let existing) where existing.pid != owner.pid:
            state.records[generation] = .conflicted
        default:
            break
        }
        if state.order.count > retainedGenerations {
            state.records[state.order.removeFirst()] = nil
        }
    }

    /// One `ndjson` event from the daemon itself; anything else `log` prints reads as nil.
    static func parse(line: Data, pasteboard: String) -> (generation: Int, owner: Owner)? {
        guard
            let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            event["processImagePath"] as? String == daemonPath,
            let message = event["eventMessage"] as? String
        else { return nil }
        return parse(message: message, pasteboard: pasteboard)
    }

    /// Each marker exactly once: a name shaped like a second record makes the whole line ambiguous.
    static func parse(message: String, pasteboard: String) -> (generation: Int, owner: Owner)? {
        let markers = [" has new generation ", " with owner ", " - process: ", " - pid: "]
        guard markers.allSatisfy({ message.components(separatedBy: $0).count == 2 }),
            let generationMarker = message.range(of: markers[0]),
            message[..<generationMarker.lowerBound] == pasteboard,
            let ownerMarker = message.range(of: markers[1]),
            let generation = Int(message[generationMarker.upperBound..<ownerMarker.lowerBound]),
            let processMarker = message.range(of: markers[2]),
            let pidMarker = message.range(of: markers[3]),
            ownerMarker.upperBound <= processMarker.lowerBound,
            processMarker.upperBound <= pidMarker.lowerBound
        else { return nil }
        let tail = message[pidMarker.upperBound...]
        let digits = tail.prefix(while: \.isNumber)
        let rest = tail.dropFirst(digits.count)
        guard let pid = pid_t(digits), pid > 0, rest.isEmpty || rest.hasPrefix(" - uuid: ") else {
            return nil
        }
        let process = String(message[processMarker.upperBound..<pidMarker.lowerBound])
        return (generation, Owner(pid: pid, process: process))
    }
}
