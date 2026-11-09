import AppleArchive
import Foundation
import System

/// Compiles the shipped bundle and archive layer, so a `.tinycast` can't quietly change shape.
@main
@MainActor
struct BackupArchiveTest {
    static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    /// UUID-suffixed, per docs/testing.md: harnesses run in parallel against the real system.
    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-archive-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func main() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }

        roundTrip(in: root)
        encryption(in: root)
        clipboardLines(in: root)
        noAbsolutePathsEscape(in: root)
        formatGuard(in: root)
        rejectsGarbage(in: root)
        refusesTraversal(in: root)
        refusesSymbolicLinks(in: root)
        refusesSpecialFiles(in: root)
        categoriesAreComplete()
        staging()
        launchSweep()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Round trip

    static func roundTrip(in root: URL) {
        let source = root.appendingPathComponent("seal")
        let bundle = BackupBundle(root: source)
        try? bundle.prepare(BackupCategory.all)

        // A binary blob, so a wrong keyset or a text-only path shows up as corruption.
        let png = Data((0..<200_000).map { UInt8($0 % 251) })
        try? bundle.write(png, to: bundle.clipboardImagesDirectory.appendingPathComponent("a.png"))
        _ = try? bundle.writeDocument(
            title: "Café — notes/with:separators", extension: "md", contents: "héllo\nwörld",
            in: bundle.notesDirectory)
        try? bundle.write(Data(), to: bundle.snippetsDirectory.appendingPathComponent("empty.md"))
        let manifest = BackupManifest(
            appVersion: "1.2.3", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            counts: ["clipboard": 1, "notes": 1])
        try? bundle.writeManifest(manifest)

        let archive = root.appendingPathComponent("out.tinycast")
        let opened = root.appendingPathComponent("open")
        do {
            try BackupArchive.seal(directory: source, into: archive, passphrase: passphrase)
            try BackupArchive.open(file: archive, into: opened, passphrase: passphrase)
        } catch {
            check("seal and open succeed (\(error))", false)
            return
        }

        let reopened = BackupBundle(root: opened)
        check(
            "a binary blob survives the round trip",
            (try? Data(
                contentsOf: reopened.clipboardImagesDirectory.appendingPathComponent("a.png")))
                == png)
        let notes = reopened.documents(in: reopened.notesDirectory, extension: "md")
        check("a note with separators and non-ASCII survives", notes.first?.contents == "héllo\nwörld")
        check(
            "a title's path separators never become directories",
            notes.first.map { !$0.name.contains("/") } ?? false)
        check(
            "a zero-byte file survives",
            reopened.documents(
                in: reopened.snippetsDirectory, extension: "md"
            ).first?.contents == "")
        let decoded = try? reopened.readManifest()
        check("the manifest round trips", decoded == manifest)
        check("an absent category reads as absent", decoded?.categories == [.clipboard, .notes])
        check("a present category keeps its count", decoded?.count(.clipboard) == 1)
        check("an absent category counts zero", decoded?.count(.snippets) == 0)

        // Ownership must not travel: the extract belongs to whoever opened it.
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: reopened.clipboardImagesDirectory.appendingPathComponent("a.png").path)
        check(
            "the extracted file is owned by the current user",
            (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
    }

    // MARK: - Encryption

    static let passphrase = "correct horse battery staple"

    static func encryption(in root: URL) {
        let source = root.appendingPathComponent("secret")
        let bundle = BackupBundle(root: source)
        try? bundle.prepare([.clipboard])
        let marker = "MARKER-\(UUID().uuidString)"
        if let writer = try? bundle.clipboardWriter() {
            try? writer.write(
                BackupClipboardItem(
                    kind: .text, text: marker, imageName: nil, createdAt: Date(),
                    sourceBundleID: nil, pinnedAt: nil))
        }
        try? bundle.writeManifest(
            BackupManifest(appVersion: "1", createdAt: Date(), counts: ["clipboard": 1]))
        let archive = root.appendingPathComponent("secret.tinycast")
        do {
            try BackupArchive.seal(directory: source, into: archive, passphrase: passphrase)
        } catch {
            check("an encrypted backup seals (\(error))", false)
            return
        }
        let sealed = (try? Data(contentsOf: archive)) ?? Data()
        check("a sealed backup is recognised as encrypted", BackupArchive.isEncrypted(file: archive))
        check("no clip text survives in the sealed bytes", sealed.range(of: Data(marker.utf8)) == nil)

        check(
            "opening without a passphrase asks for one",
            openError(archive, passphrase: nil, in: root) == .passphraseRequired)
        check(
            "an empty passphrase asks for one",
            openError(archive, passphrase: "", in: root) == .passphraseRequired)
        check(
            "a wrong passphrase is reported as one",
            openError(archive, passphrase: "correct horse battery stapler", in: root)
                == .incorrectPassphrase)

        let decomposed = "caf\u{0065}\u{0301} au lait et croissant"
        let composed = "caf\u{00E9} au lait et croissant"
        let accented = root.appendingPathComponent("accented.tinycast")
        try? BackupArchive.seal(directory: source, into: accented, passphrase: decomposed)
        check(
            "a passphrase typed composed opens one typed decomposed",
            openError(accented, passphrase: composed, in: root) == nil)

        do {
            try BackupArchive.seal(
                directory: source, into: root.appendingPathComponent("short.tinycast"),
                passphrase: "seven77")
            check("a short passphrase is refused", false)
        } catch {
            check(
                "a short passphrase is refused",
                error as? BackupArchive.ArchiveError == .passphraseTooShort)
        }
        let derived = BackupArchive.archivePassword(
            for: "x", salt: [UInt8](repeating: 0, count: 16), rounds: 100_000)
        check("the derived password fits AEA's bounds", (20...256).contains(derived.utf8.count))
        check(
            "a different salt derives a different password",
            derived
                != BackupArchive.archivePassword(
                    for: "x", salt: [UInt8](repeating: 1, count: 16), rounds: 100_000))
        do {
            try BackupArchive.seal(
                directory: source, into: root.appendingPathComponent("nine.tinycast"),
                passphrase: "ninechars")
            check("nine characters is still too short", false)
        } catch {
            check("nine characters is still too short", error as? BackupArchive.ArchiveError == .passphraseTooShort)
        }

        let previewed = root.appendingPathComponent("preview")
        try? BackupArchive.open(
            file: archive, into: previewed, passphrase: passphrase, only: [BackupBundle.manifestName])
        let previewNames = (try? FileManager.default.subpathsOfDirectory(atPath: previewed.path)) ?? []
        check("a preview unpacks the manifest and nothing else", previewNames == [BackupBundle.manifestName])

        // A file whose header claims a single round must not get a near-free derivation.
        let weak = root.appendingPathComponent("weak.tinycast")
        let weakBuilt = writeFixture(weak, encrypted: true, rounds: 1) { encoder in
            try encoder.writeDirectoryContents(
                archiveFrom: FilePath(source.path),
                keySet: ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,MTM")!)
        }
        check("the weak fixture can be built", weakBuilt)
        check("rounds outside the accepted range are refused", openError(weak, passphrase: passphrase, in: root) == .cannotRead)

        // Written before encryption existed: plain LZFSE, which must keep importing.
        let legacy = root.appendingPathComponent("legacy.tinycast")
        let legacyBuilt = writeFixture(legacy, encrypted: false) { encoder in
            try encoder.writeDirectoryContents(
                archiveFrom: FilePath(source.path),
                keySet: ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,MTM")!)
        }
        check("the legacy fixture can be built", legacyBuilt)
        check("a legacy backup is not mistaken for encrypted", !BackupArchive.isEncrypted(file: legacy))
        let legacyOut = root.appendingPathComponent("legacy-out")
        do {
            try BackupArchive.open(file: legacy, into: legacyOut, passphrase: nil)
            check(
                "a legacy backup still opens",
                Array(BackupBundle(root: legacyOut).clipboardItems()).first?.text == marker)
        } catch {
            check("a legacy backup still opens (\(error))", false)
        }
    }

    static func openError(
        _ archive: URL, passphrase: String?, in root: URL
    ) -> BackupArchive.ArchiveError? {
        let into = root.appendingPathComponent("open-\(UUID().uuidString)")
        do {
            try BackupArchive.open(file: archive, into: into, passphrase: passphrase)
            return nil
        } catch {
            return error as? BackupArchive.ArchiveError ?? .cannotRead
        }
    }

    /// Hand-built archives, so each guard runs behind both the encrypted and the legacy reader.
    static func writeFixture(
        _ archive: URL, encrypted: Bool, rounds: UInt32 = 100_000, _ body: (ArchiveStream) throws -> Void
    ) -> Bool {
        guard
            let destination = ArchiveByteStream.fileStream(
                path: FilePath(archive.path), mode: .writeOnly, options: [.create, .truncate],
                permissions: FilePermissions(rawValue: 0o600))
        else { return false }
        let stream: ArchiveByteStream?
        if encrypted {
            guard
                let context = try? BackupArchive.encryptionContext(
                    passphrase: passphrase, rounds: rounds)
            else { return false }
            stream = ArchiveByteStream.encryptionStream(
                writingTo: destination, encryptionContext: context)
        } else {
            stream = ArchiveByteStream.compressionStream(using: .lzfse, writingTo: destination)
        }
        guard let stream else { return false }
        do {
            try ArchiveStream.withEncodeStream(writingTo: stream, body)
            try stream.close()
            try destination.close()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Clipboard

    static func clipboardLines(in root: URL) {
        let bundle = BackupBundle(root: root.appendingPathComponent("clips"))
        try? bundle.prepare([.clipboard])
        let items = [
            BackupClipboardItem(
                kind: .text, text: "one\ntwo\nthree", imageName: nil,
                createdAt: Date(timeIntervalSince1970: 10), sourceBundleID: "com.apple.Safari",
                pinnedAt: nil),
            BackupClipboardItem(
                kind: .text, text: "carriage\r\nreturn", imageName: nil,
                createdAt: Date(timeIntervalSince1970: 20), sourceBundleID: nil,
                pinnedAt: Date(timeIntervalSince1970: 25)),
            BackupClipboardItem(
                kind: .image, text: nil, imageName: "b.png",
                createdAt: Date(timeIntervalSince1970: 30), sourceBundleID: nil, pinnedAt: nil)
        ]
        if let writer = try? bundle.clipboardWriter() {
            for item in items { try? writer.write(item) }
        }

        check("every clip round trips through JSONL", Array(bundle.clipboardItems()) == items)

        // The invariant the line splitting rests on: a newline in a clip is escaped, never raw.
        let raw = (try? Data(contentsOf: bundle.clipboardItemsURL)) ?? Data()
        check(
            "one line per clip, whatever the clip contains",
            raw.split(separator: 0x0A, omittingEmptySubsequences: true).count == items.count)
    }

    /// The analogue of settings-backup-test's `snippetsEnabled` check: this file leaves the Mac.
    static func noAbsolutePathsEscape(in root: URL) {
        let bundle = BackupBundle(root: root.appendingPathComponent("paths"))
        try? bundle.prepare([.clipboard])
        let item = BackupClipboardItem(
            kind: .image, text: nil, imageName: "c.png", createdAt: Date(), sourceBundleID: nil,
            pinnedAt: nil)
        if let writer = try? bundle.clipboardWriter() { try? writer.write(item) }
        let raw = (try? Data(contentsOf: bundle.clipboardItemsURL)) ?? Data()
        let text = String(bytes: raw, encoding: .utf8) ?? ""
        check("no home directory leaks into the file", !text.contains("/Users"))
        check("no image path leaks into the file", !text.contains("/Library"))
    }

    // MARK: - Guards

    static func formatGuard(in root: URL) {
        for offset in [-1, 1] {
            let bundle = BackupBundle(root: root.appendingPathComponent("format\(offset)"))
            try? bundle.prepare([])
            var manifest = BackupManifest(appVersion: "1", createdAt: Date(), counts: [:])
            manifest.format = BackupManifest.currentFormat + offset
            try? bundle.writeManifest(manifest)
            do {
                _ = try bundle.readManifest()
                check("a format of \(manifest.format) is refused", false)
            } catch {
                check(
                    "a format of \(manifest.format) is refused by the same error",
                    error == .unsupportedFormat(found: manifest.format))
                check(
                    "the refusal names the format it found",
                    error.errorDescription?.contains("\(manifest.format)") == true)
            }
        }
    }

    static func rejectsGarbage(in root: URL) {
        let file = root.appendingPathComponent("garbage.tinycast")
        try? Data("not an archive".utf8).write(to: file)
        let into = root.appendingPathComponent("garbage-out")
        do {
            try BackupArchive.open(file: file, into: into, passphrase: passphrase)
            check("a non-archive is refused", false)
        } catch {
            check("a non-archive is refused", true)
        }

        let empty = BackupBundle(root: root.appendingPathComponent("empty"))
        try? empty.prepare([])
        do {
            _ = try empty.readManifest()
            check("a bundle with no manifest is refused", false)
        } catch {
            check("a bundle with no manifest is refused", error == .unreadable)
        }
    }

    /// A hostile archive must not write outside the directory the caller chose.
    static func refusesTraversal(in root: URL) {
        let payload = Data("escaped".utf8)
        for encrypted in [true, false] {
            let label = encrypted ? "encrypted" : "legacy"
            // Header-by-header: `writeDirectoryContents` refuses to emit the `..` path we need here.
            let archive = root.appendingPathComponent("evil-\(label).tinycast")
            let built = writeFixture(archive, encrypted: encrypted) { encoder in
                let header = ArchiveHeader()
                header.append(
                    .uint(
                        key: ArchiveHeader.FieldKey("TYP"),
                        value: UInt64(ArchiveHeader.EntryType.regularFile.rawValue)))
                header.append(
                    .string(key: ArchiveHeader.FieldKey("PAT"), value: "../escape-\(label).txt"))
                header.append(.uint(key: ArchiveHeader.FieldKey("MOD"), value: 0o644))
                header.append(
                    .blob(key: ArchiveHeader.FieldKey("DAT"), size: UInt64(payload.count)))
                try encoder.writeHeader(header)
                try payload.withUnsafeBytes { buffer in
                    try encoder.writeBlob(key: ArchiveHeader.FieldKey("DAT"), from: buffer)
                }
            }
            check("the \(label) traversal fixture can be built", built)

            let into = root.appendingPathComponent("evil-out-\(label)", isDirectory: true)
            try? BackupArchive.open(file: archive, into: into, passphrase: passphrase)
            let escaped = root.appendingPathComponent("escape-\(label).txt")
            check(
                "\(label): an entry naming `..` never lands outside the destination",
                !FileManager.default.fileExists(atPath: escaped.path))
        }
    }

    /// A FIFO named like the manifest would block extraction forever; only files and folders pass.
    static func refusesSpecialFiles(in root: URL) {
        for encrypted in [true, false] {
            let label = encrypted ? "encrypted" : "legacy"
            let archive = root.appendingPathComponent("fifo-\(label).tinycast")
            let built = writeFixture(archive, encrypted: encrypted) { encoder in
                let header = ArchiveHeader()
                // 80 is `P`, a named pipe; the Swift overlay names no FIFO case to spell it with.
                header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: 80))
                header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: "manifest.json"))
                header.append(.uint(key: ArchiveHeader.FieldKey("MOD"), value: 0o644))
                try encoder.writeHeader(header)
            }
            check("the \(label) FIFO fixture can be built", built)
            let started = Date()
            let error = openError(archive, passphrase: passphrase, in: root)
            check("\(label): an archive carrying a FIFO is refused", error == .cannotRead)
            check("\(label): and refused at once, not after a hang", Date().timeIntervalSince(started) < 5)
        }
    }

    /// A link entry names no `..` at all, and reading through it would leave the extract.
    static func refusesSymbolicLinks(in root: URL) {
        for encrypted in [true, false] {
            let label = encrypted ? "encrypted" : "legacy"
            let archive = root.appendingPathComponent("linked-\(label).tinycast")
            let built = writeFixture(archive, encrypted: encrypted) { encoder in
                let header = ArchiveHeader()
                // 76 is `L`; the Swift overlay names no symbolic-link case to spell it with.
                header.append(.uint(key: ArchiveHeader.FieldKey("TYP"), value: 76))
                header.append(.string(key: ArchiveHeader.FieldKey("PAT"), value: "notes"))
                header.append(
                    .string(key: ArchiveHeader.FieldKey("LNK"), value: root.path))
                header.append(.uint(key: ArchiveHeader.FieldKey("MOD"), value: 0o777))
                try encoder.writeHeader(header)
            }
            check("the \(label) symlink fixture can be built", built)

            let into = root.appendingPathComponent("linked-out-\(label)", isDirectory: true)
            do {
                try BackupArchive.open(file: archive, into: into, passphrase: passphrase)
                check("\(label): an archive carrying a symlink is refused", false)
            } catch {
                check(
                    "\(label): an archive carrying a symlink is refused",
                    error as? BackupArchive.ArchiveError == .cannotRead)
            }
        }
    }

    // MARK: - Declarations

    /// The tripwire for adding a case and forgetting the layout or the picker.
    static func categoriesAreComplete() {
        var subpaths: Set<String> = []
        for category in BackupCategory.allCases {
            let descriptor = category.descriptor
            check("\(category.rawValue) has a label", !descriptor.label.isEmpty)
            check("\(category.rawValue) has a symbol", !descriptor.symbol.isEmpty)
            if !descriptor.subpath.isEmpty {
                check(
                    "\(category.rawValue)'s subpath is its own",
                    subpaths.insert(descriptor.subpath)
                        .inserted)
            }
        }
        check("every case is offered", BackupCategory.all.count == BackupCategory.allCases.count)
        check(
            "ordering follows declaration order",
            BackupCategory.ordered(BackupCategory.all) == BackupCategory.allCases)
    }

    static func staging() {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        guard let staging = try? BackupStaging(base: base) else {
            check("staging is created on init", false)
            return
        }
        check(
            "staging is created on init",
            FileManager.default.fileExists(atPath: staging.root.path))
        staging.discard()
        check(
            "discard removes the tree",
            !FileManager.default.fileExists(atPath: staging.root.path))
        staging.discard()
        check("discard is idempotent", true)
    }

    /// A crashed export leaves plaintext in Caches; launch reclaims it however recent.
    static func launchSweep() {
        let base = scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        guard let orphan = try? BackupStaging(base: base) else {
            check("an orphan staging tree can be made", false)
            return
        }
        let launched = Date().addingTimeInterval(1)
        Thread.sleep(forTimeInterval: 1.1)
        guard let live = try? BackupStaging(base: base) else {
            check("a live staging tree can be made", false)
            return
        }
        BackupStaging.sweepOrphans(before: launched, base: base)
        check(
            "the launch sweep removes a tree from before launch",
            !FileManager.default.fileExists(atPath: orphan.root.path))
        check(
            "the launch sweep keeps a tree made after launch",
            FileManager.default.fileExists(atPath: live.root.path))
    }
}
