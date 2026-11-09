import CryptoKit
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Compiles the shipped migration against the real store: a plaintext history goes in, none comes out.
@main
@MainActor
struct ClipboardEncryptionMigrationTest {
    static var failures = 0
    static let cipher = ClipboardCipher(rootKey: SymmetricKey(size: .bits256))

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-migration-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url.appendingPathComponent("images"), withIntermediateDirectories: true)
        return url
    }

    static func main() async {
        await convertsAPlaintextHistory()
        await resumesAfterACrash()
        leavesASealedStoreAlone()
        await skippingTheReleaseLeaksNothing()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Fixture

    struct Legacy {
        let root: URL
        let database: URL
        let images: URL
        let marker: String
        let imageMarker: Data
        let external: URL
    }

    /// The v1 layout: plain text columns, trigram FTS, loose PNGs and plaintext thumbnails.
    static func legacy(in root: URL) -> Legacy {
        let database = root.appendingPathComponent("clipboard.sqlite3")
        let images = root.appendingPathComponent("images")
        let marker = "MARKER-\(UUID().uuidString)"
        let imageMarker = Data("PNG-MARKER-\(UUID().uuidString)".utf8)
        let owned = images.appendingPathComponent("\(UUID().uuidString).png")
        try? imageMarker.write(to: owned)
        let thumbnails = images.appendingPathComponent(".thumbnails")
        try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)
        try? imageMarker.write(to: thumbnails.appendingPathComponent(owned.lastPathComponent + "-256.png"))
        let external = root.appendingPathComponent("raycast/file-abc.png")
        try? FileManager.default.createDirectory(
            at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? imageMarker.write(to: external)

        var db: OpaquePointer?
        sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(
            db,
            """
            CREATE TABLE items(id TEXT NOT NULL UNIQUE, kind TEXT NOT NULL, text TEXT,
              image_path TEXT, created_at REAL NOT NULL, source_app TEXT, pinned_at REAL);
            CREATE VIRTUAL TABLE items_fts USING fts5(
              text, content='items', content_rowid='rowid', tokenize='trigram');
            CREATE TRIGGER items_ai AFTER INSERT ON items BEGIN
              INSERT INTO items_fts(rowid, text) VALUES(new.rowid, new.text);
            END;
            CREATE TABLE item_text(item_id TEXT NOT NULL UNIQUE, text TEXT NOT NULL);
            CREATE TABLE item_text_failures(
              item_id TEXT NOT NULL UNIQUE, attempts INTEGER NOT NULL, retry_at REAL NOT NULL);
            """, nil, nil, nil)
        let ownedID = UUID()
        let rows: [(UUID, String, String?, String?, Double, String?, Double?)] = [
            (UUID(), "text", "oldest \(marker)", nil, 100, "com.apple.Safari", nil),
            (ownedID, "image", nil, owned.path, 200, "com.apple.Preview", nil),
            (UUID(), "image", nil, external.path, 300, nil, 350),
            (UUID(), "image", nil, "/nonexistent/gone.png", 400, nil, nil),
            (UUID(), "file", "/Users/me/report.pdf", nil, 500, "com.apple.finder", nil),
            (UUID(), "text", "newest \(marker)", nil, 600, nil, 650)
        ]
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(
            db,
            """
            INSERT INTO items(id, kind, text, image_path, created_at, source_app, pinned_at)
            VALUES(?,?,?,?,?,?,?)
            """, -1, &stmt, nil)
        for row in rows {
            sqlite3_bind_text(stmt, 1, row.0.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.1, -1, SQLITE_TRANSIENT)
            bind(row.2, stmt, 3)
            bind(row.3, stmt, 4)
            // Recent, or the store's three-month retention prunes the fixture on load.
            let now = Date().timeIntervalSince1970
            sqlite3_bind_double(stmt, 5, now - 1_000 + row.4)
            bind(row.5, stmt, 6)
            if let pinned = row.6 {
                sqlite3_bind_double(stmt, 7, now - 1_000 + pinned)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        sqlite3_exec(
            db, "INSERT INTO item_text(item_id, text) VALUES('\(ownedID.uuidString)', 'ocr \(marker)')",
            nil, nil, nil)
        return Legacy(
            root: root, database: database, images: images, marker: marker, imageMarker: imageMarker,
            external: external)
    }

    static func bind(_ value: String?, _ stmt: OpaquePointer?, _ index: Int32) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Every byte the store keeps on disk, thumbnails and journals included.
    static func leaks(_ needle: Data, in root: URL, excluding excluded: URL? = nil) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        var found: [String] = []
        for case let url as URL in walker where url.path != excluded?.path {
            guard let data = try? Data(contentsOf: url), data.range(of: needle) != nil else { continue }
            found.append(url.lastPathComponent)
        }
        return found
    }

    // MARK: - Cases

    static func convertsAPlaintextHistory() async {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        ClipboardEncryptionMigration.run(database: fixture.database, images: fixture.images, cipher: cipher)

        check("the converted file is the sealed version", ClipboardEncryptionMigration.isSealedStore(fixture.database))
        let rayRoot = root.appendingPathComponent("raycast")
        check(
            "no clip text survives anywhere in the store",
            leaks(Data(fixture.marker.utf8), in: root, excluding: nil).isEmpty)
        check(
            "no image bytes survive outside the other app's own file",
            leaks(fixture.imageMarker, in: fixture.images).isEmpty)
        check(
            "the other app's original file is left alone",
            (try? Data(contentsOf: fixture.external)) == fixture.imageMarker
                && FileManager.default.fileExists(atPath: rayRoot.path))
        check(
            "the plaintext thumbnails are gone",
            !FileManager.default.fileExists(
                atPath: fixture.images.appendingPathComponent(".thumbnails").path))

        let store = ClipboardStore(directory: root, cipher: cipher)
        store.load()
        check("every row survives, in order", store.items.count == 6)
        check(
            "text survives",
            store.items.compactMap(\.text).contains("newest \(fixture.marker)")
                && store.items.compactMap(\.text).contains("oldest \(fixture.marker)"))
        check(
            "the oldest row stays last",
            store.items.last(where: { !$0.isPinned })?.text?.hasPrefix("oldest") == true)
        check("pins survive", store.items.filter(\.isPinned).count == 2)
        check(
            "sources survive",
            Set(store.items.compactMap(\.sourceBundleID))
                == ["com.apple.Safari", "com.apple.Preview", "com.apple.finder"])
        let images = store.items.filter { $0.kind == .image }
        let sealed = images.filter { store.ownsImage(of: $0) }
        check("an owned and an imported image both become sealed blobs", sealed.count == 2)
        check(
            "each sealed blob opens to the original bytes",
            sealed.allSatisfy { store.imageData(for: $0) == fixture.imageMarker })
        check(
            "a reference to a vanished file stays as it was",
            images.contains { $0.imagePath == "/nonexistent/gone.png" })

        check("recognized text survives, sealed", store.setTextSearchEnabled(true))
        _ = store.search("ocr \(fixture.marker)", filter: .all)
        await store.searchSettled()
        check(
            "and is still searchable",
            store.search("ocr \(fixture.marker)", filter: .all).contains { $0.kind == .image })
        store.close()

        ClipboardEncryptionMigration.run(database: fixture.database, images: fixture.images, cipher: cipher)
        let again = ClipboardStore(directory: root, cipher: cipher)
        again.load()
        check("running it again changes nothing", again.items.count == 6)
    }

    static func resumesAfterACrash() async {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        let converting = URL(fileURLWithPath: fixture.database.path + ".converting")
        try? Data("half a file".utf8).write(to: converting)
        ClipboardEncryptionMigration.run(database: fixture.database, images: fixture.images, cipher: cipher)
        let rebuilt = ClipboardStore(directory: root, cipher: cipher)
        rebuilt.load()
        check("a stale half-made conversion is rebuilt from the original", rebuilt.items.count == 6)
        rebuilt.close()

        // Stopped between removing the old file and the swap: the finished copy must be adopted.
        let second = scratch()
        defer { try? FileManager.default.removeItem(at: second) }
        let other = legacy(in: second)
        ClipboardEncryptionMigration.run(database: other.database, images: other.images, cipher: cipher)
        let finished = URL(fileURLWithPath: other.database.path + ".converting")
        try? FileManager.default.moveItem(at: other.database, to: finished)
        ClipboardEncryptionMigration.run(database: other.database, images: other.images, cipher: cipher)
        check(
            "a finished conversion left beside a missing original is swapped in",
            ClipboardEncryptionMigration.isSealedStore(other.database)
                && !FileManager.default.fileExists(atPath: finished.path))
        let resumed = ClipboardStore(directory: second, cipher: cipher)
        resumed.load()
        check("and keeps every row", resumed.items.count == 6)
    }

    static func leavesASealedStoreAlone() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardStore(directory: root, cipher: cipher)
        store.addText("already sealed", sourceBundleID: nil)
        store.close()
        let database = root.appendingPathComponent("clipboard.sqlite3")
        ClipboardEncryptionMigration.run(
            database: database, images: root.appendingPathComponent("images"), cipher: cipher)
        let reopened = ClipboardStore(directory: root, cipher: cipher)
        reopened.load()
        check("a sealed store is left as it is", reopened.items.map(\.text) == ["already sealed"])
        ClipboardEncryptionMigration.run(
            database: root.appendingPathComponent("absent.sqlite3"),
            images: root.appendingPathComponent("images"), cipher: cipher)
        check(
            "a missing store creates nothing",
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("absent.sqlite3").path))
    }

    /// A user who never ran the release opens the old file directly: history goes, plaintext too.
    static func skippingTheReleaseLeaksNothing() async {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        let store = ClipboardStore(directory: root, cipher: cipher)
        store.load()
        check("the old file is discarded rather than read", store.items.isEmpty)
        try? await Task.sleep(for: .milliseconds(500))
        check(
            "no clip text survives the discard",
            leaks(Data(fixture.marker.utf8), in: root).isEmpty)
        check(
            "no plaintext image or thumbnail survives the load",
            leaks(fixture.imageMarker, in: fixture.images).isEmpty)
    }
}
