import CryptoKit
import Foundation

/// Runs one `ClipboardTextHelper` per item, so Vision's allocations leave with the child process.
nonisolated enum ClipboardTextWorker {
    enum Failure: Error { case recognition, outputLimit }

    /// Mirrors `ClipboardTextExtractor.maximumTextBytes`: the helper is not in the app's module.
    private static let maximumOutputBytes = 32_000
    private static let readSize = 4096
    /// The read loop and the exit wait block, so they stay off the cooperative pool.
    private static let queue = DispatchQueue(
        label: "com.tinycast.clipboard-text", qos: .background, attributes: .concurrent)
    static let executable = Bundle.main.bundleURL.appendingPathComponent(
        "Contents/Helpers/ClipboardTextHelper")

    /// An image row is only ever a sealed blob the store owns; a file row is read where it lies.
    static func extract(_ item: ClipboardItem, imageKey: SymmetricKey?) async throws -> String {
        if item.kind == .image {
            guard let path = item.imagePath, let imageKey else { return "" }
            let url = URL(fileURLWithPath: path)
            guard SealedFile.isSealed(url) else { return "" }
            return try await extract(sealedImage: url, key: imageKey, executable: executable)
        }
        guard let path = item.filePath else { return "" }
        let kind = ClipboardFileKind.of(path: path)
        guard kind == .image || kind == .pdf else { return "" }
        return try await extract(
            at: URL(fileURLWithPath: path), isPDF: kind == .pdf, executable: executable)
    }

    static func extract(
        at url: URL, isPDF: Bool, executable: URL, timeout: Duration = .seconds(60)
    ) async throws -> String {
        try await run([isPDF ? "pdf" : "image", url.path], input: nil, executable, timeout)
    }

    /// The plaintext crosses a pipe, so recognition never needs an unsealed copy on disk.
    static func extract(
        sealedImage url: URL, key: SymmetricKey, executable: URL, timeout: Duration = .seconds(60)
    ) async throws -> String {
        try await run(["image-data"], input: (url, key), executable, timeout)
    }

    private static func run(
        _ arguments: [String], input: (url: URL, key: SymmetricKey)?, _ executable: URL,
        _ timeout: Duration
    ) async throws -> String {
        try Task.checkCancellation()
        let process = Process()
        let output = Pipe()
        let stdin = input.map { _ in Pipe() }
        // A helper that exits mid-write must fail the write, not raise SIGPIPE in the app.
        if let stdin { _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) }
        process.executableURL = executable
        process.arguments = arguments
        if let stdin {
            process.standardInput = stdin
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .background
        guard let exit = try? process.runObservingExit() else { throw Failure.recognition }
        // Cancellation can land between the check above and the launch, which nothing else catches.
        if Task.isCancelled { terminate(process) }
        let deadline = Task.detached(priority: .background) {
            do { try await Task.sleep(for: timeout) } catch { return }
            terminate(process)
        }
        if let stdin, let input {
            // Unsealed and written apart from the read, so a full stdout pipe never deadlocks it.
            queue.async {
                if let data = try? SealedFile.read(input.url, key: input.key) {
                    try? stdin.fileHandleForWriting.write(contentsOf: data)
                }
                try? stdin.fileHandleForWriting.close()
            }
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: collect(from: process, awaiting: exit, reading: output))
                }
            }
        } onCancel: {
            terminate(process)
        }
        deadline.cancel()
        try Task.checkCancellation()
        return try result.get()
    }

    /// Blocking throughout, and the only place a helper is reaped: every exit runs the `defer`.
    private static func collect(
        from process: Process, awaiting exit: ProcessExit, reading output: Pipe
    ) -> Result<String, Failure> {
        let reader = output.fileHandleForReading
        defer {
            terminate(process)
            exit.wait()
            try? reader.close()
        }
        var data = Data()
        do {
            while let chunk = try reader.read(upToCount: readSize), !chunk.isEmpty {
                data.append(chunk)
                if data.count > maximumOutputBytes { return .failure(.outputLimit) }
            }
        } catch {
            return .failure(.recognition)
        }
        exit.wait()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            return .failure(.recognition)
        }
        return .success(text)
    }

    /// `terminate()` traps on a process that never launched, so the state has to be asked first.
    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }
}
