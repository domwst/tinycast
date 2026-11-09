// Standalone test for clipboard capture and paste, compiling the real sources rather than copies.
// Every case drives `NSPasteboard.withUniqueName()`: writing to `.general` would land in the
// reader's own running Tinycast as a genuine copy.
import AppKit
import CryptoKit

@main
@MainActor
struct PasteboardTests {
    static var failures = 0
    static var passes = 0
    static let cap = ClipboardManager.maxCapturedFiles
    /// `Paster.write` exports into `AppPaths.caches()` with no seam, so Caches must live here.
    static let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("tinycast-pasteboard-home-\(UUID().uuidString)", isDirectory: true)

    static func main() {
        setenv("CFFIXED_USER_HOME", home.path, 1)
        finderCopyReadsAsAFileNotItsName()
        everyFileFlavourIsRead()
        multipleFilesReadNewestLast()
        linksAndTextAreNotFiles()
        volatileAndMissingFilesFallThrough()
        theBatchIsCapped()
        rejectedFilesDoNotCountTowardTheCap()
        theBoundedReaderStopsAtItsLimit()
        aModernFileURLSuppressesTheLegacyFallback()
        richTextWithoutPlainTextReadsAsText()
        fileEntriesWriteBackAsFiles()
        aVanishedFileWritesNothing()
        imageEntriesWriteBackAsPNGAndAnExportedFile()
        exportsAreOwnerOnlyAndSwept()

        try? FileManager.default.removeItem(at: home)
        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Reading
    /// One reader, every flavour: a board naming a file must never fall through to its name.
    static func everyFileFlavourIsRead() {
        withScratch { dir in
            let file = dir.appendingPathComponent("Tinycast-Settings-2026-08-20.json")
            try? Data("{}".utf8).write(to: file)

            // Finder's real shape: one item carrying the URL and the display name together.
            let item = NSPasteboardItem()
            item.setData(file.dataRepresentation, forType: .fileURL)
            item.setString(file.lastPathComponent, forType: .string)
            let single = board()
            single.writeObjects([item])
            expect(
                PasteboardFiles.urls(on: single) == [file],
                "a URL and a display name on one item reads as the file")

            // Some boards carry the URL as a string rather than as UTF-8 data.
            let asString = NSPasteboardItem()
            asString.setString(file.absoluteString, forType: .fileURL)
            let stringBoard = board()
            stringBoard.writeObjects([asString])
            expect(
                PasteboardFiles.urls(on: stringBoard) == [file],
                "and so does one carrying the URL as a string")

            // The pre-UTI flavour, still written by plenty of apps.
            let legacy = board()
            legacy.declareTypes([.init("NSFilenamesPboardType")], owner: nil)
            legacy.setPropertyList([file.path], forType: .init("NSFilenamesPboardType"))
            expect(
                PasteboardFiles.urls(on: legacy) == [file],
                "the legacy filenames flavour is read when no file URL is present")

            let text = board()
            text.declareTypes([.string], owner: nil)
            text.setString("Tinycast-Settings-2026-08-20.json", forType: .string)
            expect(
                PasteboardFiles.urls(on: text).isEmpty,
                "a bare file name is text, not a file")
        }
    }

    /// The reported bug: Finder puts the display name on `.string` beside `public.file-url`.
    static func finderCopyReadsAsAFileNotItsName() {
        withScratch { dir in
            let file = dir.appendingPathComponent("Screen Recording.mov")
            try? Data("movie".utf8).write(to: file)
            let pb = board()
            pb.declareTypes([.fileURL, .string], owner: nil)
            pb.setData(file.dataRepresentation, forType: .fileURL)
            pb.setString("Screen Recording.mov", forType: .string)

            expect(
                ClipboardManager.fileURLs(on: pb, volatileRoots: []) == [file.path],
                "a Finder copy reads as its path, never as its name")
        }
    }

    static func multipleFilesReadNewestLast() {
        withScratch { dir in
            let urls = ["a.txt", "b.txt", "c.txt"].map { name -> URL in
                let url = dir.appendingPathComponent(name)
                try? Data(name.utf8).write(to: url)
                return url
            }
            let pb = board()
            pb.writeObjects(urls as [NSURL])
            // Reversed, so inserting in order leaves the first file copied leading the history.
            expect(
                ClipboardManager.fileURLs(on: pb, volatileRoots: []) == urls.map(\.path).reversed(),
                "three files read back reversed")
        }
    }

    /// Only a real file URL counts, so a copied link stays a link.
    static func linksAndTextAreNotFiles() {
        let pb = board()
        pb.declareTypes([.string], owner: nil)
        pb.setString("https://example.com/report.pdf", forType: .string)
        expect(ClipboardManager.fileURLs(on: pb) == nil, "an http URL is not a file")

        let plain = board()
        plain.declareTypes([.string], owner: nil)
        plain.setString("just some prose", forType: .string)
        expect(ClipboardManager.fileURLs(on: plain) == nil, "and neither is prose")

        expect(ClipboardManager.fileURLs(on: board()) == nil, "an empty pasteboard reads as nil")
    }

    /// An app that stages a temp file beside better inline content must keep the inline content.
    static func volatileAndMissingFilesFallThrough() {
        let temp = URL(fileURLWithPath: "/private/tmp/tinycast-volatile-\(UUID().uuidString).png")
        try? Data("x".utf8).write(to: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let pb = board()
        pb.writeObjects([temp as NSURL])
        expect(
            ClipboardManager.fileURLs(on: pb) == nil,
            "a file under /private/tmp is not durable, against the shipped roots")

        let gone = board()
        gone.writeObjects([URL(fileURLWithPath: "/nowhere/\(UUID().uuidString).txt") as NSURL])
        expect(ClipboardManager.fileURLs(on: gone) == nil, "and neither is one that is not there")
    }

    static func theBatchIsCapped() {
        withScratch { dir in
            let urls = (0..<40).map { index -> URL in
                let url = dir.appendingPathComponent("f\(index).txt")
                try? Data("x".utf8).write(to: url)
                return url
            }
            for legacy in [false, true] {
                for count in [1, cap - 1, cap, cap + 1, 40] {
                    let pb = fileBoard(Array(urls.prefix(count)), legacy: legacy)
                    defer { pb.releaseGlobally() }
                    expect(
                        ClipboardManager.fileURLs(on: pb, volatileRoots: [])
                            == Array(urls.prefix(min(count, cap)).map(\.path).reversed()),
                        "the first durable files stay reversed at the \(count)-file boundary (legacy: \(legacy))"
                    )
                }
            }
        }
    }

    static func rejectedFilesDoNotCountTowardTheCap() {
        withScratch { dir in
            let volatile = dir.appendingPathComponent("volatile", isDirectory: true)
            let staged = volatile.appendingPathComponent("staged.txt")
            let missing = dir.appendingPathComponent("missing.txt")
            let durableLink = dir.appendingPathComponent("durable-link")
            let volatileLink = dir.appendingPathComponent("volatile-link")
            let brokenLink = dir.appendingPathComponent("broken-link")
            let files = (0..<40).map { dir.appendingPathComponent("f\($0).txt") }
            do {
                try FileManager.default.createDirectory(at: volatile, withIntermediateDirectories: true)
                try Data("staged".utf8).write(to: staged)
                for file in files { try Data("file".utf8).write(to: file) }
                try FileManager.default.createSymbolicLink(at: durableLink, withDestinationURL: files[0])
                try FileManager.default.createSymbolicLink(at: volatileLink, withDestinationURL: staged)
                try FileManager.default.createSymbolicLink(at: brokenLink, withDestinationURL: missing)
            } catch {
                fail("cannot create file capture fixtures: \(error)")
                return
            }
            var root = volatile.resolvingSymlinksInPath().path
            if root.hasPrefix("/private/") { root.removeFirst("/private".count) }
            let rejected = [missing, staged, volatileLink, brokenLink]
            let accepted = [durableLink, files[0]] + files
            let mixed = Array(repeating: missing, count: 40) + rejected + accepted
            for legacy in [false, true] {
                let empty = fileBoard(rejected, legacy: legacy)
                defer { empty.releaseGlobally() }
                expect(
                    ClipboardManager.fileURLs(on: empty, volatileRoots: [root + "/"]) == nil,
                    "missing, volatile and broken targets fall through (legacy: \(legacy))")
                let pb = fileBoard(mixed, legacy: legacy)
                defer { pb.releaseGlobally() }
                expect(
                    ClipboardManager.fileURLs(on: pb, volatileRoots: [root + "/"])
                        == Array(accepted.prefix(cap).map(\.standardizedFileURL.path).reversed()),
                    "rejected files do not consume the cap; links and duplicates keep their order (legacy: \(legacy))"
                )
            }
        }
    }

    /// Bounding lives in the reader now, so both the limit and the predicate must stop exactly.
    static func theBoundedReaderStopsAtItsLimit() {
        let urls = (0..<100).map { URL(fileURLWithPath: "/fixture/\($0).txt") }
        let pb = fileBoard(urls, legacy: false)
        defer { pb.releaseGlobally() }
        expect(PasteboardFiles.urls(on: pb) == urls, "the attachment reader stays uncapped")
        for limit in [-1, 0, 1, cap - 1, cap, cap + 1, 100, Int.max] {
            var visited: [URL] = []
            let matched = PasteboardFiles.urls(on: pb, limit: limit) { url in
                visited.append(url)
                return true
            }
            let expected = Array(urls.prefix(max(0, limit)))
            expect(matched == expected, "a limit of \(limit) bounds the result in board order")
            expect(visited == expected, "and nothing is decoded past a limit of \(limit)")
        }
        var visited: [URL] = []
        let afterRejections = PasteboardFiles.urls(on: pb, limit: cap) { url in
            visited.append(url)
            return visited.count > 40
        }
        expect(
            afterRejections == Array(urls[40..<(40 + cap)]),
            "rejected URLs do not consume the limit")
        expect(
            visited == Array(urls.prefix(40 + cap)),
            "and every URL is tested once, with testing stopping at the limit")
    }

    /// A board naming a file in the modern flavour must never fall back, even when we reject it.
    static func aModernFileURLSuppressesTheLegacyFallback() {
        withScratch { dir in
            let legacy = dir.appendingPathComponent("legacy.txt")
            let modern = dir.appendingPathComponent("modern.txt")
            let missing = dir.appendingPathComponent("missing.txt")
            try? Data("legacy".utf8).write(to: legacy)
            try? Data("modern".utf8).write(to: modern)
            for url in [modern, missing, URL(string: "https://example.com/file")!] {
                let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
                let pb = board()
                defer { pb.releaseGlobally() }
                pb.declareTypes([type, .fileURL], owner: nil)
                pb.setPropertyList([legacy.path], forType: type)
                pb.setData(url.dataRepresentation, forType: .fileURL)

                let named = url.isFileURL ? [url] : [legacy]
                expect(
                    PasteboardFiles.urls(on: pb) == named,
                    "a modern file URL outranks the legacy paths beside it")
                var visited: [URL] = []
                let rejected = PasteboardFiles.urls(on: pb, limit: cap) { candidate in
                    visited.append(candidate)
                    return false
                }
                expect(rejected.isEmpty, "rejecting every candidate names no file")
                expect(visited == named, "and a rejected modern URL still suppresses the fallback")
                expect(
                    ClipboardManager.fileURLs(on: pb, volatileRoots: [])
                        == (url == missing ? nil : named.map(\.path)),
                    "so a missing modern file never captures the legacy path instead")
            }
        }
    }

    static func fileBoard(_ urls: [URL], legacy: Bool) -> NSPasteboard {
        let pb = board()
        if legacy {
            let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            pb.declareTypes([type], owner: nil)
            expect(pb.setPropertyList(urls.map(\.path), forType: type), "legacy fixture is written")
        } else {
            expect(pb.writeObjects(urls as [NSURL]), "file URL fixture is written")
        }
        return pb
    }

    static func richTextWithoutPlainTextReadsAsText() {
        let html = board()
        html.declareTypes([.html], owner: nil)
        html.setString("<style>p{}</style><p>brew update</p><div>ls &amp;&amp; pwd</div>", forType: .html)
        expect(
            ClipboardManager.plainText(fromRichTextOn: html) == "brew update\nls && pwd\n",
            "HTML reads as its text, without its style")

        let source = NSAttributedString(string: "from rtf")
        let rtf = board()
        rtf.declareTypes([.rtf], owner: nil)
        rtf.setData(
            source.rtf(from: NSRange(location: 0, length: source.length), documentAttributes: [:]),
            forType: .rtf)
        expect(ClipboardManager.plainText(fromRichTextOn: rtf) == "from rtf", "RTF reads as its text")

        let huge = board()
        huge.declareTypes([.html], owner: nil)
        huge.setString(String(repeating: "<p>x</p>", count: 40_000), forType: .html)
        expect(ClipboardManager.plainText(fromRichTextOn: huge) == nil, "oversized HTML is skipped")

        expect(ClipboardManager.plainText(fromRichTextOn: board()) == nil, "an empty board is nil")
    }

    // MARK: - Writing

    /// The round trip: what Finder handed us goes back out as a file, plus the path as text.
    static func fileEntriesWriteBackAsFiles() {
        withScratch { dir in
            let file = dir.appendingPathComponent("report.pdf")
            try? Data("pdf".utf8).write(to: file)
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"), cipher: .harness)
            store.addFiles([file.path], sourceBundleID: nil)
            let pb = board()

            expect(Paster.write(store.items[0], store: store, to: pb), "a present file writes")
            let read = pb.readObjects(forClasses: [NSURL.self]) as? [URL]
            expect(read?.first?.path == file.path, "and reads back as the same file URL")
            expect(pb.string(forType: .string) == file.path, "with the path as text, not the name")
            expect(
                pb.types?.contains(ClipboardManager.internalType) == true,
                "marked, so the poller skips our own write")
        }
    }

    static func aVanishedFileWritesNothing() {
        withScratch { dir in
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"), cipher: .harness)
            store.addFiles(["/nowhere/\(UUID().uuidString).txt"], sourceBundleID: nil)
            let pb = board()
            pb.declareTypes([.string], owner: nil)
            pb.setString("untouched", forType: .string)

            expect(!Paster.write(store.items[0], store: store, to: pb), "a vanished file refuses")
            expect(pb.string(forType: .string) == "untouched", "and leaves the pasteboard alone")
        }
    }

    /// The blob stays sealed: a receiver that asks for a file is handed an unsealed export.
    static func imageEntriesWriteBackAsPNGAndAnExportedFile() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        guard caches.path.hasPrefix(home.path + "/") else {
            return fail("Caches is not redirected to the harness's home, so no export is written")
        }
        withScratch { dir in
            let image = dir.appendingPathComponent("shot.png")
            let bytes = Data("png bytes of the captured image".utf8)
            try? bytes.write(to: image)
            let store = ClipboardStore(directory: dir.appendingPathComponent("store"), cipher: .harness)
            store.importEntries([ClipboardItem(imagePath: image.path, sourceBundleID: nil)])
            guard let item = store.items.first, let blob = store.imageURL(for: item) else {
                return fail("the image is sealed into the store")
            }
            expect(SealedFile.isSealed(blob), "the stored blob is sealed")
            expect(
                (try? Data(contentsOf: blob))?.range(of: bytes) == nil, "and holds none of the image's bytes")
            let exports = ClipboardExports.directory
            let exportsBefore = (try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? []
            let pb = board()
            defer { pb.releaseGlobally() }

            expect(Paster.write(item, store: store, to: pb), "a present image writes")
            expect(pb.data(forType: .png) == bytes, "as the captured image's bytes")
            expect(pb.types?.contains(.fileURL) == true, "offering a file URL")
            expect(
                (try? FileManager.default.contentsOfDirectory(atPath: exports.path)) ?? [] == exportsBefore,
                "without unsealing anything until a reader asks for the file")
            expect(
                pb.string(forType: .string) == nil,
                "but not as text, which a rich text field would take over the image")
            expect(
                pb.types?.contains(ClipboardManager.internalType) == true,
                "marked, so the poller skips our own write")

            guard let file = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else {
                return fail("the file URL reads back")
            }
            let folder = file.deletingLastPathComponent()
            expect(folder.deletingLastPathComponent().path == exports.path, "it is an export, in its own folder")
            expect(!file.path.hasPrefix(store.imagesDir.path + "/"), "never the store's own blob")
            expect(file.lastPathComponent == ClipboardExports.imageName, "under a readable name")
            if FileManager.default.fileExists(atPath: file.path) {
                expect((try? Data(contentsOf: file)) == bytes, "holding the unsealed image")
                expect(permissions(of: file) == 0o600, "readable by its owner alone")
                expect(permissions(of: folder) == 0o700, "in a folder only its owner can list")
            } else {
                fail("the export is still on disk for the reader that asked for it")
            }
            expect(
                (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first == file,
                "a second reader is handed the same export")
            expect(SealedFile.isSealed(blob), "while the stored blob stays sealed")

            // AppKit reports the provider finished on handover, so the copy outlives the reads above.
            pb.clearContents()
            expect(
                FileManager.default.fileExists(atPath: file.path),
                "the export outlives the provider, for a reader that opens it later")
            ClipboardExports.discardPasteboardCopies(in: exports)
            expect(
                !FileManager.default.fileExists(atPath: folder.path),
                "and goes once the clipboard holds something else")
        }
    }

    /// The export's own calls take a root, so its shape is checked apart from any pasteboard.
    static func exportsAreOwnerOnlyAndSwept() {
        withScratch { dir in
            let root = dir.appendingPathComponent("exports", isDirectory: true)
            let bytes = Data("unsealed".utf8)
            guard let first = try? ClipboardExports.write(bytes, in: root),
                let second = try? ClipboardExports.write(bytes, in: root)
            else { return fail("an export writes under the root it is given") }
            expect(
                [first, second].allSatisfy { $0.lastPathComponent == ClipboardExports.imageName },
                "every export keeps the readable name")
            expect(
                first.deletingLastPathComponent() != second.deletingLastPathComponent(),
                "each in a folder of its own")
            expect((try? Data(contentsOf: first)) == bytes, "holding the bytes it was handed")
            expect(permissions(of: first) == 0o600, "readable by its owner alone")
            expect(permissions(of: first.deletingLastPathComponent()) == 0o700, "in an owner-only folder")
            ClipboardExports.remove(first)
            expect(
                !FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path)
                    && FileManager.default.fileExists(atPath: second.path),
                "removing one export takes its folder and no other")
            ClipboardExports.sweep(in: root)
            expect(!FileManager.default.fileExists(atPath: root.path), "the launch sweep takes every export")

            // A copy belongs to the generation its image was written at; any other one retires it.
            _ = try? ClipboardExports.write(bytes, in: root)
            ClipboardExports.belong(toGeneration: 41)
            ClipboardExports.discardPasteboardCopies(in: root, unlessGeneration: 41)
            expect(FileManager.default.fileExists(atPath: root.path), "the image's own generation keeps it")
            ClipboardExports.discardPasteboardCopies(in: root, unlessGeneration: 42)
            expect(
                !FileManager.default.fileExists(atPath: root.path),
                "any later generation, ours or another app's, removes it")
        }
    }

    static func permissions(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    // MARK: - Harness

    static func board() -> NSPasteboard { NSPasteboard.withUniqueName() }

    static func withScratch(_ body: (URL) -> Void) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-pasteboard-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        body(dir)
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            fail(message)
        }
    }

    static func fail(_ message: String) {
        failures += 1
        print("FAIL: \(message)")
    }
}

// MARK: - Stubs for what the shipped sources reach that this harness does not exercise

@MainActor
final class AppSettings {
    var clipboardDisabledApps: Set<String> = []
}

enum Permissions {
    static func ensureAccessibility() -> Bool { false }
}

final class NotificationToken {
    init(_ observer: Any, center: NotificationCenter) {}
}

extension ClipboardCipher {
    static let harness = ClipboardCipher(rootKey: SymmetricKey(size: .bits256))
}
