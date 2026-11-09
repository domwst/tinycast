import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@main
@MainActor
struct ClipboardThumbnailTests {
    static var failures = 0
    static var passes = 0

    static func main() async {
        await removalDuringGenerationLeavesNoCopy()
        await clearDuringGenerationLeavesNoCopy()
        await copiesAreSealedUnderTheBlobKey()
        await onlyAKeyedLargerOriginalGetsACopy()
        await sameNameDifferentExtensionsStayApart()
        await timeoutReleasesTheQueue()
        await cancellationReleasesTheQueue()
        await fallbackReadsTheOriginalUnlessCancelled()
        await failedCopyFallsBackToTheOriginal()
        await unreadableCopyFallsBackAndIsDropped()
        // Flushed first: while the helper's stdin can raise SIGPIPE, the last case kills the run.
        fflush(stdout)
        await helperThatReadsNothingFailsOnlyTheCopy()

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Cases

    static func removalDuringGenerationLeavesNoCopy() async {
        await deletingDuringGeneration("removing") { store, item in store.remove(item) }
    }

    static func clearDuringGenerationLeavesNoCopy() async {
        await deletingDuringGeneration("clearing history") { store, _ in store.clearAll() }
    }

    static func deletingDuringGeneration(
        _ way: String, delete: (ClipboardStore, ClipboardItem) -> Void
    ) async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir.appendingPathComponent("store"), cipher: .harness)
        guard let item = adopt("shot.png", color: .systemRed, into: store, from: dir),
            let url = store.imageURL(for: item), let key = store.imageKey(for: item),
            let copy = ImageDerivative.covering(url, maxPixel: 64)
        else { return fail("\(way): the adopted image has a key and a row copy") }
        let helper = script(in: dir, sleeping: 0.6)

        let making = Task { await ImageThumbnail.makeCopy(copy, of: url, helper: helper, key: key) }
        try? await Task.sleep(for: .milliseconds(200))
        delete(store, item)
        if way == "removing" {
            let gone = !FileManager.default.fileExists(atPath: url.path)
            expect(gone, "the image is gone before any queued work")
        }
        _ = await making.value
        ImageDerivative.queue.sync {}
        expect(!FileManager.default.fileExists(atPath: url.path), "\(way) mid-copy deletes the image")
        expect(!FileManager.default.fileExists(atPath: copy.url.path), "\(way) mid-copy leaves no copy")
    }

    /// The helper's PNG never lands as it is: the copy is sealed beside the sealed original.
    static func copiesAreSealedUnderTheBlobKey() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir.appendingPathComponent("store"), cipher: .harness)
        guard let item = adopt("shot.png", color: .systemRed, into: store, from: dir),
            let url = store.imageURL(for: item), let key = store.imageKey(for: item),
            let copy = ImageDerivative.covering(url, maxPixel: 64)
        else { return fail("the adopted image has a key and a row copy") }
        expect(SealedFile.isSealed(url), "the adopted original is sealed")
        expect(decodedImage(at: url) == nil, "and does not decode as an image")
        expect(
            ImageThumbnail.pixelSize(of: url, key: key) == CGSize(width: 600, height: 400),
            "its pixel size reads through the key")
        expect(ImageThumbnail.pixelSize(of: url) == nil, "and not without it")

        let made = await ImageThumbnail.makeCopy(copy, of: url, helper: script(in: dir, sleeping: 0), key: key)
        expect(made, "a copy is made for the sealed original")
        expect(SealedFile.isSealed(copy.url), "the copy on disk is sealed")
        expect(decodedImage(at: copy.url) == nil, "and is not a plain PNG")
        let plain = try? SealedFile.read(copy.url, key: key)
        let source = plain.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
        expect(
            source.flatMap(CGImageSourceGetType) as String? == UTType.png.identifier,
            "it opens under the blob key to the helper's PNG")
        let size = ImageThumbnail.pixelSize(of: copy.url, key: key)
        expect(size.map { max($0.width, $0.height) } == CGFloat(copy.edge), "at the copy's edge")
        expect(color(of: copy.url, key: key) == "red", "showing the original")
        expect(
            (try? SealedFile.read(copy.url, key: SymmetricKey(size: .bits256))) == nil,
            "and no other key opens it")
        let folder = ImageDerivative.folder(beside: url)
        let excluded = try? folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        expect(excluded?.isExcludedFromBackup == true, "the copies folder is excluded from backup")

        let loaded = await ImageThumbnail.loadAsync(
            url, maxPixel: 64, copyingWith: script(in: dir, sleeping: 0), key: key)
        expect(loaded.map { max($0.size.width, $0.size.height) } == 64, "a row tile decodes from the copy")
    }

    /// Without the key there is nothing to read, and a copy no smaller than its original is waste.
    static func onlyAKeyedLargerOriginalGetsACopy() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = sealedImage("a", color: .systemRed, in: dir)
        let helper = script(in: dir, sleeping: 0)
        guard let row = ImageDerivative.covering(url, maxPixel: 64),
            let preview = ImageDerivative.covering(url, maxPixel: 900)
        else { return fail("a row and a preview copy are covered") }
        let unkeyed = await ImageThumbnail.loadAsync(url, maxPixel: 64, copyingWith: helper)
        expect(unkeyed == nil, "a sealed blob does not decode without its key")
        expect(!FileManager.default.fileExists(atPath: row.url.path), "and grows no copy")
        let made = await ImageThumbnail.makeCopy(preview, of: url, helper: helper, key: ClipboardCipher.harness.blobKey)
        expect(!made, "a 600-pixel original gets no 1080-pixel copy")
        expect(!FileManager.default.fileExists(atPath: preview.url.path), "so none is written")
        let image = await ImageThumbnail.loadAsync(
            url, maxPixel: 900, copyingWith: helper, key: ClipboardCipher.harness.blobKey)
        expect(image != nil, "and the preview decodes the sealed original")
    }

    /// Adopted images are named by stem, so `shot.jpg` and `shot.png` must not become one blob.
    static func sameNameDifferentExtensionsStayApart() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ClipboardStore(directory: dir.appendingPathComponent("store"), cipher: .harness)
        guard let jpeg = adopt("shot.jpg", color: .systemRed, into: store, from: dir),
            let png = adopt("shot.png", color: .systemBlue, into: store, from: dir)
        else { return }
        expect(jpeg.imagePath != png.imagePath, "shot.jpg and shot.png adopt into separate blobs")
        let helper = script(in: dir, sleeping: 0)
        var copies: [URL] = []
        for item in [jpeg, png] {
            guard let url = store.imageURL(for: item), let key = store.imageKey(for: item),
                let copy = ImageDerivative.covering(url, maxPixel: 64),
                await ImageThumbnail.makeCopy(copy, of: url, helper: helper, key: key)
            else { return fail("each image gets its own copy") }
            copies.append(copy.url)
        }
        expect(copies[0] != copies[1], "shot.jpg and shot.png get different copies")
        expect(color(of: copies[0], key: ClipboardCipher.harness.blobKey) == "red", "shot.jpg's copy shows it")
        expect(color(of: copies[1], key: ClipboardCipher.harness.blobKey) == "blue", "shot.png's copy shows it")

        store.remove(jpeg)
        ImageDerivative.queue.sync {}
        expect(!FileManager.default.fileExists(atPath: copies[0].path), "removing shot.jpg drops its copy")
        expect(FileManager.default.fileExists(atPath: copies[1].path), "and keeps shot.png's")
    }

    static func timeoutReleasesTheQueue() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = ClipboardCipher.harness.blobKey
        let stuck = sealedImage("a", color: .systemRed, in: dir)
        let next = sealedImage("b", color: .systemBlue, in: dir)
        let start = ContinuousClock.now
        let made = await ImageThumbnail.makeCopy(
            ImageDerivative.covering(stuck, maxPixel: 64)!, of: stuck,
            helper: script(in: dir, sleeping: 30), key: key, timeout: .milliseconds(300))
        expect(!made && start.duration(to: .now) < .seconds(5), "a stuck helper times out")
        let after = await ImageThumbnail.makeCopy(
            ImageDerivative.covering(next, maxPixel: 64)!, of: next, helper: script(in: dir, sleeping: 0),
            key: key)
        expect(after, "the queue makes the next copy after a timeout")
    }

    static func cancellationReleasesTheQueue() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = ClipboardCipher.harness.blobKey
        let stuck = sealedImage("a", color: .systemRed, in: dir)
        let next = sealedImage("b", color: .systemBlue, in: dir)
        let helper = script(in: dir, sleeping: 30)
        let making = Task {
            await ImageThumbnail.makeCopy(
                ImageDerivative.covering(stuck, maxPixel: 64)!, of: stuck, helper: helper, key: key)
        }
        try? await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        making.cancel()
        let made = await making.value
        expect(!made && start.duration(to: .now) < .seconds(5), "cancelling ends the helper")
        let after = await ImageThumbnail.makeCopy(
            ImageDerivative.covering(next, maxPixel: 64)!, of: next, helper: script(in: dir, sleeping: 0),
            key: key)
        expect(after, "the queue makes the next copy after a cancel")
    }

    static func fallbackReadsTheOriginalUnlessCancelled() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = ClipboardCipher.harness.blobKey
        let shown = sealedImage("a", color: .systemRed, in: dir)
        let scrolledAway = sealedImage("b", color: .systemBlue, in: dir)
        let missing = dir.appendingPathComponent("missing-helper")
        let fallback = await ImageThumbnail.loadAsync(shown, maxPixel: 64, copyingWith: missing, key: key)
        expect(fallback != nil, "a helper that won't launch falls back to the sealed original")
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ImageThumbnail.loadAsync(
                scrolledAway, maxPixel: 64, copyingWith: missing, key: key) != nil
        }
        expect(!(await cancelled.value), "a cancelled load skips the full-size fallback")
    }

    static func failedCopyFallsBackToTheOriginal() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = ClipboardCipher.harness.blobKey
        for (name, body) in [("failing", "cat >/dev/null; exit 1"), ("silent", "cat >/dev/null")] {
            let url = sealedImage(name, color: .systemRed, in: dir)
            guard let copy = ImageDerivative.covering(url, maxPixel: 64) else { return fail("a row copy is due") }
            let image = await ImageThumbnail.loadAsync(
                url, maxPixel: 64, copyingWith: helper(body, in: dir), key: key)
            ImageDerivative.queue.sync {}
            expect(image != nil, "a \(name) helper falls back to the original")
            expect(!FileManager.default.fileExists(atPath: copy.url.path), "and a \(name) helper leaves no copy")
        }
    }

    static func unreadableCopyFallsBackAndIsDropped() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = ClipboardCipher.harness.blobKey
        let unreadable: [(String, (URL) -> Void)] = [
            ("a plaintext copy", { try? Data("not a png".utf8).write(to: $0) }),
            ("a copy under another key", { try? SealedFile.write(Data(), to: $0, key: SymmetricKey(size: .bits256)) })
        ]
        for (index, (way, write)) in unreadable.enumerated() {
            let url = sealedImage("a\(index)", color: .systemRed, in: dir)
            guard let copy = ImageDerivative.covering(url, maxPixel: 64) else { return fail("a row copy is due") }
            try? FileManager.default.createDirectory(
                at: ImageDerivative.folder(beside: url), withIntermediateDirectories: true)
            write(copy.url)
            let image = await ImageThumbnail.loadAsync(
                url, maxPixel: 64, copyingWith: dir.appendingPathComponent("missing-helper"), key: key)
            ImageDerivative.queue.sync {}
            expect(image != nil, "\(way) falls back to the original")
            let dropped = !FileManager.default.fileExists(atPath: copy.url.path)
            expect(dropped, "and \(way) is dropped so the next draw remakes it")
        }
    }

    /// Past the pipe buffer, so the write is still in flight when the helper has already gone.
    static func helperThatReadsNothingFailsOnlyTheCopy() async {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = ClipboardCipher.harness.blobKey
        let url = dir.appendingPathComponent("noise.sealed")
        try? SealedFile.write(noisePNG(edge: 1200), to: url, key: key)
        guard let copy = ImageDerivative.covering(url, maxPixel: 64) else { return fail("a row copy is due") }
        let made = await ImageThumbnail.makeCopy(copy, of: url, helper: helper("exit 1", in: dir), key: key)
        expect(!made, "a helper that exits without reading fails the copy, not the app")
    }

    // MARK: - Fixtures

    /// Stand-in helper: reads the whole original from stdin first and answers on stdout last.
    static func script(in dir: URL, sleeping seconds: Double) -> URL {
        helper(
            """
            [ "$1" = thumbnail ] || exit 2
            in=$(mktemp) && out=$(mktemp) || exit 1
            trap 'rm -f "$in" "$out"' EXIT
            trap 'kill $! 2>/dev/null; exit 1' TERM
            cat > "$in" || exit 1
            sleep \(seconds) >/dev/null & wait $!
            sips -s format png -Z "$2" "$in" --out "$out" >/dev/null 2>&1 || exit 1
            cat "$out"
            """, in: dir)
    }

    static func helper(_ body: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent("helper-\(UUID().uuidString).sh")
        try? ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Wider than the row copy's edge, so a copy is due; JPEG or PNG by extension.
    static func imageData(color: NSColor, type: UTType) -> Data {
        let context = CGContext(
            data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// Random pixels, so the PNG stays megabytes and outruns the pipe's buffer.
    static func noisePNG(edge: Int) -> Data {
        var pixels = (0..<(edge * edge)).map { _ in UInt32.random(in: 0...UInt32.max) | 0xFF00_0000 }
        let image = pixels.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: edge, height: edge, bitsPerComponent: 8,
                bytesPerRow: edge * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!.makeImage()!
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A blob as the store keeps one: sealed under the harness's blob key, named `<stem>.sealed`.
    static func sealedImage(_ stem: String, color: NSColor, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(stem + "." + SealedFile.fileExtension)
        try? SealedFile.write(
            imageData(color: color, type: .png), to: url, key: ClipboardCipher.harness.blobKey)
        return url
    }

    /// Found by id: the adopted path is the store's to choose.
    static func adopt(
        _ name: String, color: NSColor, into store: ClipboardStore, from dir: URL
    ) -> ClipboardItem? {
        let staged = dir.appendingPathComponent("staged-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let blob = staged.appendingPathComponent(name)
        let type = blob.pathExtension == "jpg" ? UTType.jpeg : UTType.png
        try? imageData(color: color, type: type).write(to: blob)
        let item = ClipboardItem(imagePath: blob.path, sourceBundleID: nil)
        _ = ClipboardStore.importStoredItems(
            inDatabaseAt: store.dbURL, adoptingImagesInto: store.imagesDir, cipher: .harness, [item])
        store.load()
        guard let adopted = store.items.first(where: { $0.id == item.id }) else {
            let names = store.items.compactMap(\.imagePath).map { URL(fileURLWithPath: $0).lastPathComponent }
            fail("\(name) is adopted beside \(names)")
            return nil
        }
        return adopted
    }

    static func decodedImage(at url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    static func color(of url: URL, key: SymmetricKey) -> String {
        guard let data = try? SealedFile.read(url, key: key),
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let pixel = NSBitmapImageRep(cgImage: image).colorAt(x: 10, y: 10)?.usingColorSpace(.sRGB)
        else { return "unreadable" }
        return pixel.redComponent > pixel.blueComponent ? "red" : "blue"
    }

    static func scratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tinycast-clipboard-thumbnail-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passes += 1
        } else {
            fail(label)
        }
    }

    static func fail(_ label: String) {
        print("FAIL: \(label)")
        failures += 1
    }
}

extension ClipboardCipher {
    static let harness = ClipboardCipher(rootKey: SymmetricKey(size: .bits256))
}
