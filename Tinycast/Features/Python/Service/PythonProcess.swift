import Darwin
import Foundation
import Synchronization

/// The interpreter as a child: requests in on fd 3, events out on fd 4, beside stdout and stderr.
final class PythonProcess: Sendable {
    enum Message: Sendable {
        case event(PythonEvent)
        /// Written straight to fd 1 or 2, by a subprocess or a C extension.
        case rawOutput(PythonStream, String)
        case exited(status: Int32)
    }

    let processID: pid_t
    let messages: AsyncStream<Message>
    private let requests: Int32
    private let hasExited = Mutex(false)
    private let writer = DispatchQueue(label: "com.tinycast.python.requests")

    /// How long a stopped interpreter is given to leave before its whole group is killed.
    private static let stopGrace: DispatchTimeInterval = .seconds(1)
    private static let readSize = 64 * 1024

    private init(processID: pid_t, requests: Int32, messages: AsyncStream<Message>) {
        self.processID = processID
        self.requests = requests
        self.messages = messages
    }

    /// Fails with the spawn's own error when the interpreter can't be started.
    static func launch(
        interpreter: String, driver: String, environment: [String: String], directory: String
    ) -> Result<PythonProcess, POSIXError> {
        guard let request = RawPipe(), let event = RawPipe(), let output = RawPipe(),
            let errors = RawPipe()
        else { return .failure(POSIXError(.EMFILE)) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own session, so a stop reaches every subprocess the user's code started too.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGINT, SIGTERM, SIGHUP, SIGPIPE] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, output.write, 1)
        posix_spawn_file_actions_adddup2(&actions, errors.write, 2)
        posix_spawn_file_actions_adddup2(&actions, request.read, 3)
        posix_spawn_file_actions_adddup2(&actions, event.write, 4)
        posix_spawn_file_actions_addchdir(&actions, directory)

        let argv = CStrings([interpreter, "-u", "-X", "utf8", driver])
        let envp = CStrings(environment.map { "\($0.key)=\($0.value)" })
        var processID: pid_t = 0
        let status = posix_spawn(&processID, interpreter, &actions, &attributes, argv.pointers, envp.pointers)
        for descriptor in [request.read, event.write, output.write, errors.write] { close(descriptor) }
        guard status == 0, processID > 0 else {
            for descriptor in [request.write, event.read, output.read, errors.read] { close(descriptor) }
            return .failure(POSIXError(POSIXErrorCode(rawValue: status) ?? .ENOEXEC))
        }
        // A request written after the interpreter died must fail, not kill Tinycast with SIGPIPE.
        _ = fcntl(request.write, F_SETNOSIGPIPE, 1)

        let (messages, continuation) = AsyncStream.makeStream(of: Message.self)
        let process = PythonProcess(processID: processID, requests: request.write, messages: messages)
        process.read(event.read, into: continuation)
        process.read(output.read, as: .stdout, into: continuation)
        process.read(errors.read, as: .stderr, into: continuation)
        return .success(process)
    }

    func send(_ request: PythonRequest) {
        let data = request.line()
        writer.async { [requests] in
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(requests, base + offset, buffer.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }

    /// Ctrl-C, sent to the group the way a terminal sends it to its foreground job.
    func interrupt() {
        signalGroup(SIGINT)
    }

    /// Ends the interpreter and anything it started, politely first.
    func stop() {
        writer.async { [requests] in close(requests) }
        signalGroup(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.stopGrace) { [self] in
            signalGroup(SIGKILL)
        }
    }

    /// Never after the exit is reaped: by then the id may belong to someone else's process.
    private func signalGroup(_ signal: Int32) {
        hasExited.withLock { exited in
            guard !exited else { return }
            kill(-processID, signal)
        }
    }

    private func read(_ descriptor: Int32, into continuation: AsyncStream<Message>.Continuation) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var splitter = PythonLineSplitter()
            Self.drain(descriptor) { bytes in
                for line in splitter.append(bytes) {
                    if let event = PythonEvent(line: line) { continuation.yield(.event(event)) }
                }
            }
            // The event pipe closes only when the interpreter is gone, so its exit is reaped here.
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0 && errno == EINTR {}
            hasExited.withLock { $0 = true }
            continuation.yield(.exited(status: status))
            continuation.finish()
        }
    }

    private func read(
        _ descriptor: Int32, as stream: PythonStream,
        into continuation: AsyncStream<Message>.Continuation
    ) {
        DispatchQueue.global(qos: .utility).async {
            var decoder = PythonTextDecoder()
            Self.drain(descriptor) { bytes in
                let text = decoder.decode(bytes)
                if !text.isEmpty { continuation.yield(.rawOutput(stream, text)) }
            }
        }
    }

    private static func drain(_ descriptor: Int32, _ handle: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: readSize)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                handle(Data(buffer[0..<count]))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                break
            }
        }
        close(descriptor)
    }
}

/// A pipe whose ends sit above the standard descriptors and close on exec unless dup'd.
private struct RawPipe {
    let read: Int32
    let write: Int32

    init?() {
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return nil }
        // Kept clear of 0–4, which the child's file actions dup2 onto and must not alias.
        let read = fcntl(ends[0], F_DUPFD_CLOEXEC, 10)
        let write = fcntl(ends[1], F_DUPFD_CLOEXEC, 10)
        close(ends[0])
        close(ends[1])
        guard read >= 0, write >= 0 else {
            if read >= 0 { close(read) }
            if write >= 0 { close(write) }
            return nil
        }
        self.read = read
        self.write = write
    }
}

/// The argv/envp arrays must outlive `posix_spawn`, so this is a real allocation.
private final class CStrings {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ values: [String]) {
        count = values.count
        pointers = .allocate(capacity: count + 1)
        for (index, value) in values.enumerated() { pointers[index] = strdup(value) }
        pointers[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointers[index]) }
        pointers.deallocate()
    }
}
