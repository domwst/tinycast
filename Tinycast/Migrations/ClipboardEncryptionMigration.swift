import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Seals a plaintext history from before encryption; skipping it costs that history, never a leak.
nonisolated enum ClipboardEncryptionMigration {
    /// Idempotent; false only when a plaintext history is still there because converting it failed.
    @discardableResult
    static func run(
        database: URL, images: URL, cipher: ClipboardCipher,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let converting = URL(fileURLWithPath: database.path + ".converting")
        guard recoverInterruptedSwap(database: database, images: images) else { return false }
        switch ClipboardStore.inspect(database) {
        case .unreadable:
            // A file that won't open right now may still be the history: try again next launch.
            return false
        case .absent, .discardable:
            ClipboardStore.removeDatabase(at: converting)
            return true
        case .sealed:
            ClipboardStore.removeDatabase(at: converting)
            // Stopped after the swap but before the old images went: finish that now.
            removePlaintext(in: images)
            return true
        case .legacy:
            break
        }
        ClipboardStore.removeDatabase(at: converting)
        guard convert(database, into: converting, images: images, cipher: cipher, home: home) else {
            ClipboardStore.removeDatabase(at: converting)
            return false
        }
        ClipboardStore.removeDatabase(at: database)
        // The finished copy stays beside the missing original, which the next run completes.
        guard rename(converting.path, database.path) == 0 else { return false }
        removePlaintext(in: images)
        return true
    }

    /// Finishes a swap a crash interrupted; false while its copy still waits, so nothing re-keys.
    @discardableResult
    static func recoverInterruptedSwap(database: URL, images: URL) -> Bool {
        let converting = URL(fileURLWithPath: database.path + ".converting")
        guard !FileManager.default.fileExists(atPath: database.path),
            FileManager.default.fileExists(atPath: converting.path)
        else { return true }
        switch ClipboardStore.inspect(converting) {
        // Plaintext goes only once `run` finds the store sealed, after its key has vouched for it.
        case .sealed: return rename(converting.path, database.path) == 0
        case .unreadable: return false
        case .absent, .legacy, .discardable:
            ClipboardStore.removeDatabase(at: converting)
            return true
        }
    }

    /// A plaintext history, a conversion a crash interrupted, or its leftover images await `run`.
    static func isPending(database: URL, images: URL) -> Bool {
        let converting = URL(fileURLWithPath: database.path + ".converting")
        return FileManager.default.fileExists(atPath: converting.path)
            || ClipboardStore.inspect(database) == .legacy
            || !plaintextFiles(in: images).isEmpty
    }

    static func isSealedStore(_ database: URL) -> Bool {
        ClipboardStore.inspect(database) == .sealed
    }

    private static func convert(
        _ legacy: URL, into target: URL, images: URL, cipher: ClipboardCipher, home: URL
    ) -> Bool {
        var source: OpaquePointer?
        var destination: OpaquePointer?
        defer {
            sqlite3_close_v2(source)
            sqlite3_close_v2(destination)
        }
        guard sqlite3_open_v2(legacy.path, &source, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            sqlite3_open_v2(
                target.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK,
            // A rollback journal, so a closed file is the whole of it with no WAL beside it.
            sqlite3_exec(
                destination, "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;", nil, nil, nil)
                == SQLITE_OK,
            ClipboardStore.prepareSchema(destination, cipher: cipher) == true,
            sqlite3_exec(destination, ClipboardStore.extractionSchema, nil, nil, nil) == SQLITE_OK,
            sqlite3_exec(destination, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { return false }
        guard copyItems(from: source, to: destination, images: images, cipher: cipher, home: home),
            copyRecognizedText(from: source, to: destination, cipher: cipher),
            sqlite3_exec(destination, "COMMIT", nil, nil, nil) == SQLITE_OK
        else {
            sqlite3_exec(destination, "ROLLBACK", nil, nil, nil)
            return false
        }
        return true
    }

    private static func copyItems(
        from source: OpaquePointer?, to destination: OpaquePointer?, images: URL,
        cipher: ClipboardCipher, home: URL
    ) -> Bool {
        var read: OpaquePointer?
        var write: OpaquePointer?
        defer {
            sqlite3_finalize(read)
            sqlite3_finalize(write)
        }
        let select = """
            SELECT id, kind, text, image_path, created_at, source_app, pinned_at
            FROM items ORDER BY rowid
            """
        let insert = """
            INSERT INTO items(id, kind, text, image_path, created_at, source_app, pinned_at)
            VALUES(?,?,?,?,?,?,?)
            """
        guard sqlite3_prepare_v2(source, select, -1, &read, nil) == SQLITE_OK,
            sqlite3_prepare_v2(destination, insert, -1, &write, nil) == SQLITE_OK, let write
        else { return false }
        while sqlite3_step(read) == SQLITE_ROW {
            guard let id = ClipboardStore.columnString(read, 0).flatMap(UUID.init(uuidString:)),
                let kind = ClipboardStore.columnString(read, 1).flatMap(ClipboardItem.Kind.init)
            else { continue }
            var imagePath = ClipboardStore.columnString(read, 3)
            if let original = imagePath {
                switch sealedImage(original, in: images, cipher, home: home) {
                case .sealed(let sealed): imagePath = sealed
                case .dropped: continue
                // An owned image that won't seal stops the conversion before its only copy goes.
                case .failed: return false
                }
            }
            let item = ClipboardItem(
                id: id, kind: kind, text: ClipboardStore.columnString(read, 2),
                imagePath: imagePath,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(read, 4)),
                sourceBundleID: ClipboardStore.columnString(read, 5),
                pinnedAt: sqlite3_column_type(read, 6) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(read, 6)))
            guard ClipboardStore.bindAndInsert(write, item, cipher) else { return false }
        }
        return true
    }

    private enum ImageOutcome {
        case sealed(String)
        /// Not an image this history can vouch for: the row goes, nothing is read.
        case dropped
        case failed
    }

    /// An image of ours is sealed or stops the run; another app's is adopted only past the policy.
    private static func sealedImage(
        _ path: String, in images: URL, _ cipher: ClipboardCipher, home: URL
    ) -> ImageOutcome {
        let sealed = images.appendingPathComponent(ClipboardStore.sealedName(forOriginal: path))
        // A rerun after a crash finds the copy already made, and only trusts it if it opens.
        if (try? SealedFile.read(sealed, key: cipher.blobKey)) != nil { return .sealed(sealed.path) }
        let original = URL(fileURLWithPath: path).standardizedFileURL
        let owned =
            !path.split(separator: "/").contains("..")
            && original.deletingLastPathComponent().path == images.standardizedFileURL.path
        let isRegularFile =
            (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
            == .typeRegular
        // An older release kept any path a `.rayconfig` named; only what the policy admits is read.
        guard isRegularFile, owned || RaycastImagePolicy.accepts(path, home: home) else { return .dropped }
        if ClipboardStore.sealBlob(from: path, to: sealed.path, key: cipher.blobKey) {
            return .sealed(sealed.path)
        }
        // Another app's file is never deleted here, so failing to copy it loses nothing.
        return owned ? .failed : .dropped
    }

    /// Recognized text, if the old file ever had text search on; an empty answer becomes NULL.
    private static func copyRecognizedText(
        from source: OpaquePointer?, to destination: OpaquePointer?, cipher: ClipboardCipher
    ) -> Bool {
        var read: OpaquePointer?
        var write: OpaquePointer?
        defer {
            sqlite3_finalize(read)
            sqlite3_finalize(write)
        }
        guard sqlite3_prepare_v2(source, "SELECT item_id, text FROM item_text", -1, &read, nil)
            == SQLITE_OK
        else { return true }
        guard
            sqlite3_prepare_v2(
                destination, "INSERT OR IGNORE INTO item_text(item_id, text) VALUES(?1, ?2)", -1,
                &write, nil) == SQLITE_OK
        else { return false }
        while sqlite3_step(read) == SQLITE_ROW {
            guard let idString = ClipboardStore.columnString(read, 0),
                let id = UUID(uuidString: idString)
            else { continue }
            sqlite3_bind_text(write, 1, idString, -1, SQLITE_TRANSIENT)
            let text = ClipboardStore.columnString(read, 1) ?? ""
            if !text.isEmpty, let sealed = cipher.seal(text, field: .recognizedText, row: id) {
                _ = sealed.withUnsafeBytes {
                    sqlite3_bind_blob(write, 2, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT)
                }
            } else {
                sqlite3_bind_null(write, 2)
            }
            let done = sqlite3_step(write) == SQLITE_DONE
            sqlite3_reset(write)
            sqlite3_clear_bindings(write)
            guard done else { return false }
        }
        return true
    }

    /// Every unsealed blob and thumbnail, all of them plaintext copies of history.
    private static func removePlaintext(in images: URL) {
        for url in plaintextFiles(in: images) { try? FileManager.default.removeItem(at: url) }
    }

    /// Regular files only, in real folders only: a planted link must not aim this at other files.
    private static func plaintextFiles(in images: URL) -> [URL] {
        let thumbnails = images.appending(path: ".thumbnails", directoryHint: .isDirectory)
        // The parent first: a real `.thumbnails` reached through a linked `images` is not ours.
        guard ClipboardStore.isRealDirectory(images) else { return [] }
        return [images, thumbnails].filter(ClipboardStore.isRealDirectory).flatMap { folder -> [URL] in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            return names
                .filter { !$0.hasPrefix(".") && !$0.hasSuffix("." + SealedFile.fileExtension) }
                .map { folder.appendingPathComponent($0) }
                .filter {
                    (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.type]
                        as? FileAttributeType == .typeRegular
                }
        }
    }
}
