import CryptoKit
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The shipped migration against the real store: plaintext history goes in, none comes out.
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
        aFailedSealKeepsTheOriginal()
        cleanupResumesAfterTheSwap()
        onlyTheRightKeyOpensTheStore()
        imagesStayBoundToTheirRows()
        importedPathsAreNeverOwned()
        foreignPathsAreDropped()
        anUnreadableStoreIsKept()

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
        let externalBytes: Data
        let home: URL
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
        let home = root.appendingPathComponent("home", isDirectory: true)
        let external = home.appendingPathComponent(
            "Library/Application Support/com.raycast.macos/file-abc.png")
        try? FileManager.default.createDirectory(
            at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Decodable, as the import policy demands, with the marker riding after the image's end.
        let externalBytes = onePixelPNG() + imageMarker
        try? externalBytes.write(to: external)

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
            external: external, externalBytes: externalBytes, home: home)
    }

    static func onePixelPNG() -> Data {
        let data = NSMutableData()
        guard
            let context = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func bind(_ value: String?, _ stmt: OpaquePointer?, _ index: Int32) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    /// Every byte the store keeps on disk, thumbnails and journals included.
    static func leaks(_ needle: Data, in root: URL, excluding excluded: URL? = nil) -> [String] {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
        else { return [] }
        var found: [String] = []
        for case let url as URL in walker where url.path != excluded?.path {
            // A link's bytes are its target's, which a store never wrote.
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                let data = try? Data(contentsOf: url), data.range(of: needle) != nil
            else { continue }
            found.append(url.lastPathComponent)
        }
        return found
    }

    // MARK: - Cases

    static func convertsAPlaintextHistory() async {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)

        check("the converted file is the sealed version", ClipboardEncryptionMigration.isSealedStore(fixture.database))
        check(
            "no clip text survives anywhere in the store",
            leaks(Data(fixture.marker.utf8), in: root, excluding: nil).isEmpty)
        check(
            "no image bytes survive outside the other app's own file",
            leaks(fixture.imageMarker, in: fixture.images).isEmpty)
        check(
            "the other app's original file is left alone",
            (try? Data(contentsOf: fixture.external)) == fixture.externalBytes)
        let thumbnails = fixture.images.appendingPathComponent(".thumbnails")
        check(
            "the plaintext thumbnails are gone",
            ((try? FileManager.default.contentsOfDirectory(atPath: thumbnails.path)) ?? []).isEmpty)

        let store = ClipboardStore(directory: root, cipher: cipher)
        store.load()
        check("every row survives but the vanished image's", store.items.count == 5)
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
            Set(sealed.compactMap { store.imageData(for: $0) })
                == [fixture.imageMarker, fixture.externalBytes])
        check(
            "a reference to a vanished image goes, since nothing is left to seal",
            !images.contains { $0.imagePath == "/nonexistent/gone.png" })

        check("recognized text survives, sealed", store.setTextSearchEnabled(true))
        _ = store.search("ocr \(fixture.marker)", filter: .all)
        await store.searchSettled()
        check(
            "and is still searchable",
            store.search("ocr \(fixture.marker)", filter: .all).contains { $0.kind == .image })
        store.close()

        ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        let again = ClipboardStore(directory: root, cipher: cipher)
        again.load()
        check("running it again changes nothing", again.items.count == 5)
    }

    static func resumesAfterACrash() async {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        let converting = URL(fileURLWithPath: fixture.database.path + ".converting")
        try? Data("half a file".utf8).write(to: converting)
        ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        let rebuilt = ClipboardStore(directory: root, cipher: cipher)
        rebuilt.load()
        check("a stale half-made conversion is rebuilt from the original", rebuilt.items.count == 5)
        rebuilt.close()

        // Stopped between removing the old file and the swap: the finished copy must be adopted.
        let second = scratch()
        defer { try? FileManager.default.removeItem(at: second) }
        let other = legacy(in: second)
        ClipboardEncryptionMigration.run(
            database: other.database, images: other.images, cipher: cipher, home: other.home)
        let finished = URL(fileURLWithPath: other.database.path + ".converting")
        try? FileManager.default.moveItem(at: other.database, to: finished)
        ClipboardEncryptionMigration.run(
            database: other.database, images: other.images, cipher: cipher, home: other.home)
        check(
            "a finished conversion left beside a missing original is swapped in",
            ClipboardEncryptionMigration.isSealedStore(other.database)
                && !FileManager.default.fileExists(atPath: finished.path))
        let resumed = ClipboardStore(directory: second, cipher: cipher)
        resumed.load()
        check("and keeps every row", resumed.items.count == 5)
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

    /// The only copy of an owned image must outlive a seal that fails, so nothing is converted.
    static func aFailedSealKeepsTheOriginal() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        let owned = (try? FileManager.default.contentsOfDirectory(atPath: fixture.images.path))?
            .first { $0.hasSuffix(".png") }
        guard let owned else { return check("the fixture has an owned image", false) }
        // A folder where the sealed copy would go makes its rename fail.
        let blocker = fixture.images.appendingPathComponent(ClipboardStore.sealedName(forOriginal: owned))
        try? FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        check(
            "a failed seal leaves the old file unconverted",
            !ClipboardEncryptionMigration.isSealedStore(fixture.database))
        check(
            "and the original image where it was",
            FileManager.default.fileExists(atPath: fixture.images.appendingPathComponent(owned).path))
        check(
            "so the conversion is still pending",
            ClipboardEncryptionMigration.isPending(database: fixture.database, images: fixture.images))
    }

    /// A crash after the swap leaves old images; the next run, capture on or off, removes them.
    static func cleanupResumesAfterTheSwap() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        let stray = fixture.images.appendingPathComponent("\(UUID().uuidString).png")
        try? fixture.imageMarker.write(to: stray)
        let thumbnail = fixture.images.appendingPathComponent(".thumbnails/stray.png-256.png")
        try? fixture.imageMarker.write(to: thumbnail)
        check(
            "leftover plaintext keeps the migration pending",
            ClipboardEncryptionMigration.isPending(database: fixture.database, images: fixture.images))
        ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        check(
            "and the next run removes it, blob and thumbnail",
            leaks(fixture.imageMarker, in: fixture.images).isEmpty)
        check(
            "after which nothing is pending",
            !ClipboardEncryptionMigration.isPending(database: fixture.database, images: fixture.images))
    }

    /// A Keychain key is only trusted when a sealed store's canary opens under it.
    static func onlyTheRightKeyOpensTheStore() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("clipboard.sqlite3")
        check("no store vouches for any key", !ClipboardStore.opensSealedStore(at: database, cipher: cipher))
        let store = ClipboardStore(directory: root, cipher: cipher)
        store.addText("vouched", sourceBundleID: nil)
        store.close()
        check("the store's own key opens it", ClipboardStore.opensSealedStore(at: database, cipher: cipher))
        let planted = ClipboardCipher(rootKey: SymmetricKey(size: .bits256))
        check("a planted key does not", !ClipboardStore.opensSealedStore(at: database, cipher: planted))
        let old = scratch()
        defer { try? FileManager.default.removeItem(at: old) }
        let fixture = legacy(in: old)
        check(
            "nor does a plaintext store, so a key found beside one is never adopted",
            !ClipboardStore.opensSealedStore(at: fixture.database, cipher: cipher))
    }

    /// The image path is sealed to its row: pointing one row at another's blob makes it unreadable.
    static func imagesStayBoundToTheirRows() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        var db: OpaquePointer?
        sqlite3_open_v2(fixture.database.path, &db, SQLITE_OPEN_READWRITE, nil)
        sqlite3_exec(
            db,
            """
            UPDATE items SET image_path = (SELECT image_path FROM items WHERE kind = 'image'
              ORDER BY rowid DESC LIMIT 1) WHERE rowid = (SELECT rowid FROM items
              WHERE kind = 'image' ORDER BY rowid LIMIT 1)
            """, nil, nil, nil)
        sqlite3_close_v2(db)
        let store = ClipboardStore(directory: root, cipher: cipher)
        store.load()
        check(
            "a row pointed at another row's image no longer opens",
            store.items.filter { $0.kind == .image }.count == 1)
    }

    /// `images/../victim` is not ours: an import copies it and no prune or delete ever touches it.
    static func importedPathsAreNeverOwned() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ClipboardStore(directory: root, cipher: cipher)
        let victim = root.appendingPathComponent("victim")
        try? FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try? Data("keep".utf8).write(to: victim.appendingPathComponent("precious.txt"))
        let crafted = store.imagesDir.path + "/../victim"
        check("a traversal path is not an owned blob", !ClipboardStore.isOwnedBlob(crafted, in: store.imagesDir))
        let old = Date().addingTimeInterval(-400 * 86_400)
        store.importEntries([
            ClipboardItem(imagePath: crafted, createdAt: old, sourceBundleID: nil),
            ClipboardItem(
                imagePath: store.imagesDir.path + "/../victim/precious.txt", createdAt: old,
                sourceBundleID: nil)
        ])
        store.maxAge = 86_400
        store.enforceLimits()
        for item in store.items { store.remove(item) }
        store.clearAll()
        check(
            "an imported path outside the store survives import, prune, delete and clear",
            FileManager.default.fileExists(atPath: victim.appendingPathComponent("precious.txt").path))
    }

    /// A row may name any file: only an image of ours, or one past the Raycast policy, is read.
    static func foreignPathsAreDropped() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        let secretMarker = Data("SECRET-\(UUID().uuidString)".utf8)
        let secret = root.appendingPathComponent("secret.txt")
        try? secretMarker.write(to: secret)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = fixture.images.appendingPathComponent("\(UUID().uuidString).png")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let paths = [secret.path, folder.path, fixture.images.path + "/../secret.txt", link.path]
        var db: OpaquePointer?
        sqlite3_open_v2(fixture.database.path, &db, SQLITE_OPEN_READWRITE, nil)
        let now = Date().timeIntervalSince1970
        for path in paths {
            sqlite3_exec(
                db,
                """
                INSERT INTO items(id, kind, image_path, created_at)
                VALUES('\(UUID().uuidString)', 'image', '\(path)', \(now))
                """, nil, nil, nil)
        }
        sqlite3_close_v2(db)
        let converted = ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        check("a row naming a foreign file never stops the conversion", converted)
        let store = ClipboardStore(directory: root, cipher: cipher)
        store.load()
        check("every such row is dropped", store.items.count == 5)
        check("no foreign file's bytes are sealed into the store", leaks(secretMarker, in: fixture.images).isEmpty)
        check("and the file itself is left alone", (try? Data(contentsOf: secret)) == secretMarker)
    }

    /// A store that won't open just now may be the only history: it is neither judged nor replaced.
    static func anUnreadableStoreIsKept() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = legacy(in: root)
        chmod(fixture.database.path, 0)
        check("an unopenable file reads as unreadable", ClipboardStore.inspect(fixture.database) == .unreadable)
        let converted = ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        check("the run reports it couldn't finish", !converted)
        chmod(fixture.database.path, 0o600)
        check("and the plaintext history is still there to convert", ClipboardStore.inspect(fixture.database) == .legacy)
        let retried = ClipboardEncryptionMigration.run(
            database: fixture.database, images: fixture.images, cipher: cipher, home: fixture.home)
        check("which the next run does", retried && ClipboardEncryptionMigration.isSealedStore(fixture.database))

        // The swap's copy alone holds the history: one that won't open blocks any re-key.
        let converting = URL(fileURLWithPath: fixture.database.path + ".converting")
        try? FileManager.default.moveItem(at: fixture.database, to: converting)
        chmod(converting.path, 0)
        check(
            "an unreadable finished copy beside no original is never resolved",
            !ClipboardEncryptionMigration.recoverInterruptedSwap(
                database: fixture.database, images: fixture.images)
                && FileManager.default.fileExists(atPath: converting.path))
        chmod(converting.path, 0o600)
        check(
            "and once it opens it is swapped in",
            ClipboardEncryptionMigration.recoverInterruptedSwap(
                database: fixture.database, images: fixture.images)
                && ClipboardEncryptionMigration.isSealedStore(fixture.database))
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
