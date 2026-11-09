import AppKit
import CryptoKit
import ImageIO
import Synchronization

enum ImageThumbnail {
    private static let cache = ThumbnailCache(
        rowBytes: 8 * 1024 * 1024, previewBytes: 8 * 1024 * 1024)

    /// Frees the preview bitmaps on dismiss; row thumbnails stay warm for a re-open.
    static func purgePreviews() {
        cache.purgePreviews()
    }

    /// Cache-only, never touching disk, so a warm thumbnail renders on the same frame.
    static func cached(_ url: URL, maxPixel: CGFloat) -> NSImage? {
        cache.cached(url, maxPixel: maxPixel)
    }

    /// A freshly-decoded, thereafter-immutable `NSImage` is safe to move across the actor boundary.
    private struct Decoded: @unchecked Sendable { let image: NSImage? }

    /// Returns the decode directly; `key` unseals the blob and its copies, made only with one.
    static func loadAsync(
        _ url: URL, maxPixel: CGFloat, copyingWith helper: URL? = nil, key: SymmetricKey? = nil
    ) async -> NSImage? {
        if let cached = cached(url, maxPixel: maxPixel) { return cached }
        var decodable = url
        if let helper, let key,
            let copy = ImageDerivative.covering(url, maxPixel: Int(maxPixel.rounded(.up))),
            await makeCopy(copy, of: url, helper: helper, key: key)
        {
            decodable = copy.url
        }
        // A tile scrolled away mid-copy must not fall back to the full-size decode it was avoiding.
        guard !Task.isCancelled else { return nil }
        return await Task.detached(priority: .userInitiated) { [decodable] in
            if let image = decode(decodable, key: key, cachingAs: url, maxPixel: maxPixel) {
                return Decoded(image: image)
            }
            guard decodable != url else { return Decoded(image: nil) }
            // An unreadable copy is dropped so the next draw remakes it; the original shows now.
            ImageDerivative.queue.async { try? FileManager.default.removeItem(at: decodable) }
            return Decoded(image: decode(url, key: key, cachingAs: url, maxPixel: maxPixel))
        }.value.image
    }

    private static func decode(
        _ file: URL, key: SymmetricKey?, cachingAs url: URL, maxPixel: CGFloat
    ) -> NSImage? {
        guard let source = imageSource(file, key: key),
            let cgImage = downsample(source, maxPixel: maxPixel)
        else { return nil }
        let image = NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.store(
            image, for: url, maxPixel: maxPixel, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }

    /// A sealed file is read into memory whole: ImageIO decodes from bytes, never a plaintext path.
    private static func imageSource(_ file: URL, key: SymmetricKey?) -> CGImageSource? {
        guard let key else { return CGImageSourceCreateWithURL(file as CFURL, nil) }
        guard let data = try? SealedFile.read(file, key: key) else { return nil }
        return CGImageSourceCreateWithData(data as CFData, nil)
    }

    private static func downsample(_ source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Waits on `ImageDerivative.queue`, off the cooperative pool, so a blob's delete waits it out.
    static func makeCopy(
        _ copy: ImageDerivative, of url: URL, helper: URL, key: SymmetricKey,
        timeout: DispatchTimeInterval = .seconds(10)
    ) async -> Bool {
        if exists(copy) { return true }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["thumbnail", String(copy.edge)]
        process.standardError = FileHandle.nullDevice
        let cancelled = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                ImageDerivative.queue.async {
                    let made = run(
                        process, making: copy, of: url, key: key, timeout: timeout,
                        cancelled: cancelled)
                    continuation.resume(returning: made)
                }
            }
        } onCancel: {
            cancelled.flag.withLock { $0 = true }
            terminate(process)
        }
    }

    /// The original goes in over stdin and the copy comes back on stdout, sealed before it lands.
    private static func run(
        _ process: Process, making copy: ImageDerivative, of url: URL, key: SymmetricKey,
        timeout: DispatchTimeInterval, cancelled: Cancellation
    ) -> Bool {
        if exists(copy) { return true }
        guard !cancelled.flag.withLock({ $0 }),
            let original = try? SealedFile.read(url, key: key),
            let size = pixelSize(of: CGImageSourceCreateWithData(original as CFData, nil)),
            Int(max(size.width, size.height)) > copy.edge
        else { return false }
        let input = Pipe()
        let output = Pipe()
        // Close-on-exec: a child another feature spawns meanwhile must not inherit the plaintext.
        for pipe in [input, output] {
            _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        // A helper that exits mid-write must fail the write, not raise SIGPIPE in the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = output
        guard let exit = try? process.runObservingExit() else { return false }
        // A cancel between the check and the launch found nothing running to terminate.
        if cancelled.flag.withLock({ $0 }) { terminate(process) }
        let deadline = DispatchWorkItem { terminate(process) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Written apart from the read below, or a helper filling stdout would block on its stdin.
        DispatchQueue.global(qos: .userInitiated).async {
            try? input.fileHandleForWriting.write(contentsOf: original)
            try? input.fileHandleForWriting.close()
        }
        let thumbnail = (try? output.fileHandleForReading.readToEnd()).flatMap(\.self)
        exit.wait()
        deadline.cancel()
        guard process.terminationStatus == 0, let thumbnail, !thumbnail.isEmpty else { return false }
        let folder = copy.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)
        return (try? SealedFile.write(thumbnail, to: copy.url, key: key)) != nil
    }

    private final class Cancellation: Sendable {
        let flag = Mutex(false)
    }

    /// `terminate()` traps on a process that never launched, so the state has to be asked first.
    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }

    private static func exists(_ copy: ImageDerivative) -> Bool {
        FileManager.default.fileExists(atPath: copy.url.path)
    }

    /// Pixel dimensions from image metadata — no full decode, though a sealed file is unsealed.
    static func pixelSize(of url: URL, key: SymmetricKey? = nil) -> CGSize? {
        pixelSize(of: imageSource(url, key: key))
    }

    private static func pixelSize(of source: CGImageSource?) -> CGSize? {
        guard let source,
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
