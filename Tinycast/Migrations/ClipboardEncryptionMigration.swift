import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Seals a plaintext history from before encryption; skipping it costs that history, never a leak.
nonisolated enum ClipboardEncryptionMigration {
    /// Idempotent: a sealed store, a missing one, or a half-finished conversion all resolve here.
    static func run(database: URL, images: URL, cipher: ClipboardCipher) {
        let converting = URL(fileURLWithPath: database.path + ".converting")
        guard FileManager.default.fileExists(atPath: database.path) else {
            // Stopped between removing the old file and the swap: the new one is already complete.
            if isSealedStore(converting) {
                _ = rename(converting.path, database.path)
            } else {
                ClipboardStore.removeDatabase(at: converting)
            }
            return
        }
        guard userVersion(database) == 0, hasItems(database) else {
            ClipboardStore.removeDatabase(at: converting)
            return
        }
        ClipboardStore.removeDatabase(at: converting)
        guard convert(database, into: converting, images: images, cipher: cipher) else {
            ClipboardStore.removeDatabase(at: converting)
            return
        }
        ClipboardStore.removeDatabase(at: database)
        guard rename(converting.path, database.path) == 0 else { return }
        removePlaintext(in: images)
    }

    /// A plaintext history, or a conversion a crash interrupted, is still waiting on `run`.
    static func isPending(database: URL) -> Bool {
        let converting = URL(fileURLWithPath: database.path + ".converting")
        return FileManager.default.fileExists(atPath: converting.path)
            || (FileManager.default.fileExists(atPath: database.path) && userVersion(database) == 0
                && hasItems(database))
    }

    static func isSealedStore(_ database: URL) -> Bool {
        FileManager.default.fileExists(atPath: database.path)
            && userVersion(database) == Int64(ClipboardStore.schemaVersion)
    }

    private static func convert(
        _ legacy: URL, into target: URL, images: URL, cipher: ClipboardCipher
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
            ClipboardStore.prepareSchema(destination, cipher: cipher),
            sqlite3_exec(destination, ClipboardStore.extractionSchema, nil, nil, nil) == SQLITE_OK,
            sqlite3_exec(destination, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
        else { return false }
        guard copyItems(from: source, to: destination, images: images, cipher: cipher),
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
        cipher: ClipboardCipher
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
            let item = ClipboardItem(
                id: id, kind: kind, text: ClipboardStore.columnString(read, 2),
                imagePath: sealedImage(ClipboardStore.columnString(read, 3), in: images, cipher),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(read, 4)),
                sourceBundleID: ClipboardStore.columnString(read, 5),
                pinnedAt: sqlite3_column_type(read, 6) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(read, 6)))
            guard ClipboardStore.bindAndInsert(write, item, cipher) else { return false }
        }
        return true
    }

    /// The sealed copy's path; a reference to a file that is gone stays as it was, shown missing.
    private static func sealedImage(_ path: String?, in images: URL, _ cipher: ClipboardCipher) -> String? {
        guard let path else { return nil }
        let original = URL(fileURLWithPath: path)
        let sealed = images.appendingPathComponent(ClipboardStore.sealedName(forOriginal: path))
        // A rerun after a crash finds the copy already made, and only trusts it if it opens.
        if (try? SealedFile.read(sealed, key: cipher.blobKey)) != nil { return sealed.path }
        guard FileManager.default.fileExists(atPath: original.path) else { return path }
        return ClipboardStore.sealBlob(from: path, to: sealed.path, key: cipher.blobKey)
            ? sealed.path : path
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

    /// Every unsealed blob and every old thumbnail, all of them plaintext copies of history.
    private static func removePlaintext(in images: URL) {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []
        for name in entries where !name.hasPrefix(".") && !name.hasSuffix("." + SealedFile.fileExtension) {
            try? FileManager.default.removeItem(at: images.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(
            at: images.appending(path: ".thumbnails", directoryHint: .isDirectory))
    }

    private static func userVersion(_ database: URL) -> Int64 {
        scalar(database, "PRAGMA user_version") ?? -1
    }

    private static func hasItems(_ database: URL) -> Bool {
        (scalar(database, "SELECT COUNT(*) FROM sqlite_master WHERE name = 'items'") ?? 0) > 0
    }

    private static func scalar(_ database: URL, _ sql: String) -> Int64? {
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return nil
        }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
            sqlite3_step(stmt) == SQLITE_ROW
        else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }
}
