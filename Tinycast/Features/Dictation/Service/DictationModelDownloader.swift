import CryptoKit
import Darwin
import Foundation
import Synchronization

enum DictationModelDownloader {
    /// `files` is the build's pinned list; the host is never asked what a model holds or hashes to.
    static func download(
        _ model: DictationModel, destination: URL,
        baseURL: URL = URL(string: "https://huggingface.co/")!,
        files pinned: [DictationModelFiles.File]? = nil,
        protocolClasses: [AnyClass]? = nil,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = protocolClasses
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let fileManager = FileManager.default
        let root = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true)
        let descriptor = open(
            root.appending(path: ".download-lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw DictationWire.Failure.busy }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        // Keep the lock file's inode stable so every instance locks the same resource.
        for directory in try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        {
            let name = directory.lastPathComponent
            guard name.hasPrefix("."), UUID(uuidString: String(name.dropFirst())) != nil else { continue }
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try fileManager.removeItem(at: directory)
        }
        let staging = root.appendingPathComponent(".\(UUID().uuidString)")
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let files = try locations(of: pinned ?? DictationModelFiles.files(for: model), baseURL: baseURL)
        var total: Int64 = 0
        for (file, _) in files {
            let sum = total.addingReportingOverflow(file.size)
            guard !sum.overflow else { throw URLError(.cannotParseResponse) }
            total = sum.partialValue
        }
        var received: Int64 = 0
        onProgress(received, total)
        for (file, url) in files {
            try Task.checkCancellation()
            let completed = received, expected = total, size = file.size
            let target = staging.appending(path: file.path)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let response = try await downloadFile(from: url, to: target, using: session) { bytes in
                onProgress(completed + min(size, max(0, bytes)), expected)
            }
            try Task.checkCancellation()
            try validate(response)
            let actual = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard actual.map(Int64.init) == file.size else { throw URLError(.badServerResponse) }
            try verify(target, checksum: file.sha256)
            received += file.size
            onProgress(received, total)
        }
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: destination.path) { throw CocoaError(.fileWriteFileExists) }
        try fileManager.moveItem(at: staging, to: destination)
    }

    private static func locations(
        of files: [DictationModelFiles.File], baseURL: URL
    ) throws -> [(DictationModelFiles.File, URL)] {
        guard !files.isEmpty else { throw URLError(.cannotParseResponse) }
        return try files.map { file in
            let path = file.path.split(separator: "/")
            guard file.size >= 0, !path.isEmpty, file.path == path.joined(separator: "/"),
                path.allSatisfy({ $0 != "." && $0 != ".." })
            else {
                throw URLError(.cannotParseResponse)
            }
            let resolved = "\(file.repository)/resolve/\(file.revision)/\(file.path)"
            return (file, baseURL.appending(path: resolved))
        }
    }

    private static func downloadFile(
        from url: URL, to destination: URL, using session: URLSession,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URLResponse {
        let responses = AsyncThrowingStream<URLResponse, any Error> { continuation in
            let task = session.downloadTask(with: url)
            task.delegate = Transfer(
                destination: destination, responses: continuation, onProgress: onProgress)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
        for try await response in responses { return response }
        throw CancellationError()
    }

    private final class Transfer: NSObject, URLSessionDownloadDelegate {
        private let destination: URL
        private let responses: AsyncThrowingStream<URLResponse, any Error>.Continuation
        private let onProgress: @Sendable (Int64) -> Void
        private let lastUpdate = Mutex<ContinuousClock.Instant?>(nil)

        init(
            destination: URL, responses: AsyncThrowingStream<URLResponse, any Error>.Continuation,
            onProgress: @escaping @Sendable (Int64) -> Void
        ) {
            self.destination = destination
            self.responses = responses
            self.onProgress = onProgress
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            let now = ContinuousClock.now
            let shouldUpdate = lastUpdate.withLock { last in
                if let last, now - last < .milliseconds(100) { return false }
                last = now
                return true
            }
            if shouldUpdate { onProgress(totalBytesWritten) }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            do {
                guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
                try FileManager.default.moveItem(at: location, to: destination)
                responses.yield(response)
                responses.finish()
            } catch {
                responses.finish(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?)
        {
            if let error { responses.finish(throwing: error) }
        }
    }

    private static func verify(_ url: URL, checksum: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == checksum else {
            throw URLError(.badServerResponse)
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}
