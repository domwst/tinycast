import CryptoKit
import Foundation
import SQLite3

// Spelled as the C macro in sqlite3.h, which isn't imported into Swift.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct ClipboardItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case text, image, file }

    let id: UUID
    let kind: Kind
    /// The copied text, or for a `.file` entry the absolute path — which is what search reads.
    let text: String?
    /// Absolute path on disk; only files under `imagesDir` are ours to delete.
    let imagePath: String?
    let createdAt: Date
    /// Bundle ID of the app the copy is attributed to (see `ClipboardSource.recordedBundleID`).
    let sourceBundleID: String?
    /// When the entry was pinned; pins lead the list and are exempt from pruning.
    let pinnedAt: Date?

    var isPinned: Bool { pinnedAt != nil }

    /// The referenced path, so no call site re-derives a file entry's meaning from `text`.
    var filePath: String? { kind == .file ? text : nil }

    /// What Paste as Plain Text writes: the text, or a file's path in place of the file.
    var plainText: String? { kind == .image ? nil : text }

    /// Whether Copy Text (⇧⌘T) applies: a captured image, or an image file copied in Finder.
    var offersTextExtraction: Bool {
        switch kind {
        case .image: return imagePath != nil
        case .file: return filePath.map { ClipboardFileKind.of(path: $0) == .image } ?? false
        case .text: return false
        }
    }

    init(text: String, sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .text, text: text, imagePath: nil, createdAt: Date(),
            sourceBundleID: sourceBundleID)
    }

    init(imagePath: String, createdAt: Date = Date(), sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .image, text: nil, imagePath: imagePath, createdAt: createdAt,
            sourceBundleID: sourceBundleID)
    }

    /// Referenced where it lies: `imagePath` stays nil, keeping an unowned file from `deleteBlob`.
    init(filePath: String, createdAt: Date = Date(), sourceBundleID: String?) {
        self.init(
            id: UUID(), kind: .file, text: filePath, imagePath: nil, createdAt: createdAt,
            sourceBundleID: sourceBundleID)
    }

    init(
        id: UUID, kind: Kind, text: String?, imagePath: String?, createdAt: Date,
        sourceBundleID: String?, pinnedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imagePath = imagePath
        self.createdAt = createdAt
        self.sourceBundleID = sourceBundleID
        self.pinnedAt = pinnedAt
    }

    /// Copy with the two fields the store rewrites; the pin is always stated outright.
    func with(createdAt: Date? = nil, pinnedAt: Date?) -> ClipboardItem {
        ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            createdAt: createdAt ?? self.createdAt, sourceBundleID: sourceBundleID,
            pinnedAt: pinnedAt)
    }

    /// Every term of `query` as a case- and diacritic-insensitive substring, in any order.
    func matches(_ query: String) -> Bool {
        ClipboardQuery(query).matchesExactly(text)
    }
}

/// Retention in days; `forever` is -1, so an unset key (0) falls through to the default.
enum ClipboardRetention: Int, CaseIterable, Identifiable, Sendable {
    case day = 1
    case week = 7
    case month = 30
    case threeMonths = 90
    case sixMonths = 180
    case year = 365
    case forever = -1

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .day: return String(localized: "1 Day")
        case .week: return String(localized: "1 Week")
        case .month: return String(localized: "1 Month")
        case .threeMonths: return String(localized: "3 Months")
        case .sixMonths: return String(localized: "6 Months")
        case .year: return String(localized: "1 Year")
        case .forever: return String(localized: "Forever")
        }
    }

    var maxAge: TimeInterval {
        self == .forever ? .greatestFiniteMagnitude : TimeInterval(rawValue) * 86_400
    }
}

/// What ↵ does on a clipboard entry; Paste takes the chord the chosen action leaves free.
enum ClipboardDefaultAction: String, CaseIterable, Identifiable, Sendable {
    case paste
    case copy
    case pastePlainText

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return String(localized: "Paste")
        case .copy: return String(localized: "Copy to Clipboard")
        case .pastePlainText: return String(localized: "Paste as Plain Text")
        }
    }

    /// What `chord` runs on `item` with this as the default; nil when it has no text to paste.
    func action(for chord: ClipboardChord, on item: ClipboardItem) -> Self? {
        let hasPlainText = item.plainText != nil
        // An image has no text, so a plain-text default pastes it as it is.
        let resolved: Self = self == .pastePlainText && !hasPlainText ? .paste : self
        let action: Self =
            switch chord {
            case .return: resolved
            case resolved.ownChord: .paste
            case .command: .copy
            case .controlCommand: .pastePlainText
            }
        return action == .pastePlainText && !hasPlainText ? nil : action
    }

    /// The chord an action answers while Paste is the default.
    private var ownChord: ClipboardChord {
        switch self {
        case .paste: .return
        case .copy: .command
        case .pastePlainText: .controlCommand
        }
    }
}

/// The ↵ chords a default reorders; ⌥↵ always pastes, so it is not one of them.
enum ClipboardChord: CaseIterable, Sendable {
    case `return`
    case command
    case controlCommand

    var label: String {
        switch self {
        case .return: "↵"
        case .command: "⌘↵"
        case .controlCommand: "⌃⌘↵"
        }
    }
}

@MainActor
@Observable
final class ClipboardStore {
    enum UpdateError: Error { case tooLong, writeFailed }

    /// One row a scan found past what the main actor matched, with the rowid that orders it.
    struct DeepMatch: Sendable {
        let item: ClipboardItem
        let rowid: Int64
    }

    /// What one off-main scan answered for a query and filter. docs/features/clipboard.md#search
    struct DeepResult: Sendable {
        let query: String
        let filter: ClipboardFilter
        var pins: [ClipboardItem]
        var exact: [DeepMatch]
        var loose: [DeepMatch]

        mutating func removeAll(where shouldRemove: (ClipboardItem) -> Bool) {
            pins.removeAll(where: shouldRemove)
            exact.removeAll { shouldRemove($0.item) }
            loose.removeAll { shouldRemove($0.item) }
        }
    }

    /// Newest-first with pins in place, every pin resident. docs/features/clipboard.md
    private(set) var items: [ClipboardItem] = [] {
        didSet {
            invalidateSearch(preservingMatches: true)
            onItemsChanged?()
        }
    }
    @ObservationIgnored var onItemsChanged: (() -> Void)?
    @ObservationIgnored var onSearchResultsChanged: ((String, [ClipboardItem], [ClipboardItem]) -> Void)?
    /// Rotated whenever the history is replaced, so a helper's late answer lands on nothing.
    @ObservationIgnored private(set) var extractionGeneration = UUID()
    @ObservationIgnored private(set) var captureGeneration = UUID()
    /// The only thing a view observes for search freshness; `items` cannot speak for a scan.
    private var searchRevision = 0
    @ObservationIgnored private(set) var textSearchEnabled = false
    @ObservationIgnored private var searchActive = true
    @ObservationIgnored private var deepTask: Task<Void, Never>?
    @ObservationIgnored private var deepNeedsRefresh = false
    @ObservationIgnored private var deepQuery: String?
    @ObservationIgnored private var deepFilter: ClipboardFilter?
    @ObservationIgnored private var deepRequest: UUID?
    @ObservationIgnored private var deepResult: DeepResult?

    var maxAge: TimeInterval = ClipboardRetention.threeMonths.maxAge

    /// One-entry memo so repeated renders reuse one answer; cleared when `items` changes.
    @ObservationIgnored private var searchCache:
        (query: String, filter: ClipboardFilter, result: [ClipboardItem])?
    /// Same memo for the empty query, so the pinned split runs once per mutation.
    @ObservationIgnored private var orderedCache: [ClipboardItem]?
    /// Each resident row's text folded once, so a keystroke compares bytes instead of strings.
    @ObservationIgnored private var foldedCache: [UUID: [UInt8]] = [:]

    /// Longest text history holds; a longer copy is skipped, since truncation would lose the tail.
    nonisolated static let maxTextLength = 32_000
    nonisolated private static let memoryWindow = 1000
    nonisolated private static let importChunk = 250
    /// The most unpinned rows any one query answers with, exact and loose alike.
    nonisolated private static let searchLimit = 200
    /// Every value sealed, no full-text index; any other `user_version` is discarded on open.
    nonisolated static let schemaVersion: Int32 = 2

    nonisolated private static let insertSQL = """
        INSERT INTO items(id, kind, text, image_path, created_at, source_app, pinned_at)
        VALUES(?,?,?,?,?,?,?)
        """

    nonisolated private static let columns =
        "id, kind, text, image_path, created_at, source_app, pinned_at"

    nonisolated private static let schema = """
        CREATE TABLE IF NOT EXISTS items(
          id TEXT NOT NULL UNIQUE,
          kind TEXT NOT NULL,
          text BLOB,
          image_path BLOB,
          created_at REAL NOT NULL,
          source_app BLOB,
          pinned_at REAL
        );
        CREATE INDEX IF NOT EXISTS items_created_at ON items(created_at);
        CREATE INDEX IF NOT EXISTS items_pinned_at ON items(pinned_at) WHERE pinned_at IS NOT NULL;
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value BLOB NOT NULL);
        """

    nonisolated static let extractionSchema = """
        CREATE TABLE IF NOT EXISTS item_text(
          item_id TEXT NOT NULL UNIQUE, text BLOB
        );
        CREATE TRIGGER IF NOT EXISTS items_extract_ad AFTER DELETE ON items BEGIN
          DELETE FROM item_text WHERE item_id = old.id;
        END;
        CREATE TABLE IF NOT EXISTS item_text_failures(
          item_id TEXT NOT NULL UNIQUE, attempts INTEGER NOT NULL, retry_at REAL NOT NULL
        );
        CREATE TRIGGER IF NOT EXISTS items_extract_failure_ad AFTER DELETE ON items BEGIN
          DELETE FROM item_text_failures WHERE item_id = old.id;
        END;
        CREATE INDEX IF NOT EXISTS items_extract_candidates ON items(kind)
          WHERE kind IN ('image', 'file');
        """

    /// The canary's row id: all zeroes, which no captured clip's random UUID can be.
    nonisolated private static let canaryRow = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    nonisolated private static let canaryValue = "tinycast-clipboard"

    /// Internal, not private: a backup names both to stream the table and adopt its blobs.
    let imagesDir: URL
    let dbURL: URL
    /// Held from the first open, so switching the feature back on needs no Keychain read.
    @ObservationIgnored private(set) var cipher: ClipboardCipher?
    @ObservationIgnored private var db: OpaquePointer?
    @ObservationIgnored private var insertStmt: OpaquePointer?
    @ObservationIgnored private var loadStmt: OpaquePointer?
    @ObservationIgnored private var windowFloorStmt: OpaquePointer?
    @ObservationIgnored private var deleteByIDStmt: OpaquePointer?
    @ObservationIgnored private var pinStmt: OpaquePointer?
    @ObservationIgnored private var staleImagesStmt: OpaquePointer?
    @ObservationIgnored private var deleteStaleStmt: OpaquePointer?

    /// Closed until `open(cipher:)`: the key comes from the Keychain, which is never read on main.
    init(directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory
        imagesDir = base.appendingPathComponent("images", isDirectory: true)
        dbURL = base.appendingPathComponent("clipboard.sqlite3")
        try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
    }

    /// A harness's key, which is never the Keychain's; the app always opens through the coordinator.
    convenience init(directory: URL?, cipher: ClipboardCipher) {
        self.init(directory: directory)
        open(cipher: cipher)
    }

    var isOpen: Bool { db != nil }

    /// Idempotent, so the coordinator can re-open the file when the feature is switched back on.
    func open(cipher: ClipboardCipher) {
        guard db == nil else { return }
        self.cipher = cipher
        if openDatabase() { return }
        // Captured, not authored: discard a corrupt, outdated or foreign-keyed database.
        closeDatabase()
        Self.removeDatabase(at: dbURL)
        // Its blobs belong to rows that are gone, and under another key nothing could open them.
        if Self.isRealDirectory(imagesDir) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path)) ?? [] {
                try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name))
            }
        }
        if !openDatabase() { closeDatabase() }
    }

    /// Every accessor is statement-guarded, so a closed store answers as an empty history.
    func close() {
        setTextSearchEnabled(false)
        extractionGeneration = UUID()
        captureGeneration = UUID()
        closeDatabase()
        items = []
    }

    /// Application Support, not Caches: a history the OS may reclaim is not a history.
    nonisolated static var defaultDirectory: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.tinycast.app"
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID, isDirectory: true)
    }

    nonisolated static func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    // Isolated so teardown may touch the main-actor pointers; the release is already on main.
    isolated deinit {
        deepTask?.cancel()
        closeDatabase()
    }

    func load() {
        invalidateSearch()
        extractionGeneration = UUID()
        guard let stmt = loadStmt, let cipher else { return }
        sqlite3_bind_int64(stmt, 1, windowFloor())
        var loaded: [ClipboardItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = Self.row(stmt, cipher) { loaded.append(item) }
        }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        items = loaded
        ImageDerivative.removeOrphans(in: imagesDir)
        let images = imagesDir
        Task.detached(priority: .utility) { Self.removeUnsealedFiles(in: images) }
        // Age passes while the app isn't running; insert-time pruning alone can't catch that.
        enforceLimits()
    }

    func enforceLimits() {
        prune()
    }

    /// The floor rowid `loadStmt` reads from; 0 means no floor, so load everything.
    private func windowFloor() -> sqlite3_int64 {
        guard let stmt = windowFloorStmt else { return 0 }
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_bind_int(stmt, 1, Int32(Self.memoryWindow - 1))
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : 0
    }

    func addText(_ text: String, sourceBundleID: String?) {
        if items.first?.kind == .text, items.first?.text == text { return }
        insert(ClipboardItem(text: text, sourceBundleID: sourceBundleID))
    }

    /// One row per file. Batched, so a multi-file copy prunes once rather than once per file.
    func addFiles(_ paths: [String], sourceBundleID: String?) {
        // Only a single file can be a ⌘C repeat, which is the case `addText` also guards.
        if paths.count == 1, items.first?.kind == .file, items.first?.text == paths[0] { return }
        guard let cipher else { return }
        for path in paths {
            let item = ClipboardItem(filePath: path, sourceBundleID: sourceBundleID)
            if let stmt = insertStmt { Self.bindAndInsert(stmt, item, cipher) }
            items.insert(item, at: 0)
            trimWindow()
        }
        prune()
    }

    func addImage(_ data: Data, sourceBundleID: String?, capture: UUID) {
        guard capture == captureGeneration, let key = cipher?.blobKey else { return }
        let url = imagesDir.appendingPathComponent("\(UUID().uuidString).png.\(SealedFile.fileExtension)")
        let item = ClipboardItem(imagePath: url.path, sourceBundleID: sourceBundleID)
        // The seal and write are multi-MB work; only the row insert returns to the main actor.
        Task.detached(priority: .utility) { [weak self] in
            guard (try? SealedFile.write(data, to: url, key: key)) != nil else { return }
            await self?.insertCapture(item, from: capture)
        }
    }

    private func insertCapture(_ item: ClipboardItem, from capture: UUID) {
        guard capture == captureGeneration else {
            deleteBlob(item)
            return
        }
        insert(item)
    }

    /// Bulk-insert from an import: original timestamps, each image sealed into the store, deduped.
    @discardableResult
    func importEntries(_ entries: [ClipboardItem]) -> Int {
        guard let cipher else { return 0 }
        // Oldest first so newest ends up with the highest rowid (load orders by rowid DESC).
        let inserted = Self.importStoredItems(
            inDatabaseAt: dbURL, adoptingImagesInto: imagesDir, cipher: cipher,
            entries.sorted { $0.createdAt < $1.createdAt })
        load()
        return inserted
    }

    func promote(_ item: ClipboardItem) {
        // A pinned row holds its place, so re-recencying it would rewrite for no change.
        guard !item.isPinned, items.first?.id != item.id else { return }
        reinsert(item.with(createdAt: Date(), pinnedAt: nil))
    }

    func togglePinned(_ item: ClipboardItem) {
        if item.isPinned { unpin(item) } else { pin(item) }
    }

    func updateText(_ text: String, of item: ClipboardItem) throws(UpdateError) -> ClipboardItem? {
        guard item.kind == .text else { return nil }
        guard text.count <= Self.maxTextLength else { throw .tooLong }
        guard let cipher, let sealed = cipher.seal(text, field: .text, row: item.id),
            let stmt = prepare("UPDATE items SET text = ?1 WHERE id = ?2")
        else { throw .writeFailed }
        defer { sqlite3_finalize(stmt) }
        Self.bind(sealed, to: stmt, at: 1)
        sqlite3_bind_text(stmt, 2, item.id.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw .writeFailed }
        guard sqlite3_changes(db) > 0 else { return nil }
        foldedCache[item.id] = nil
        let index = items.firstIndex { $0.id == item.id }
        let current = index.map { items[$0] } ?? item
        let edited = ClipboardItem(
            id: current.id, kind: .text, text: text, imagePath: nil, createdAt: current.createdAt,
            sourceBundleID: current.sourceBundleID, pinnedAt: current.pinnedAt)
        if let index {
            items[index] = edited
        } else {
            // A scan hit past the memory window: only the memo still holds the old text.
            invalidateSearch()
            searchRevision += 1
        }
        return edited
    }

    func remove(_ item: ClipboardItem) {
        deepResult?.removeAll { $0.id == item.id }
        if let stmt = deleteByIDStmt {
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        items.removeAll { $0.id == item.id }
        deleteBlob(item)
    }

    /// A pin is a deliberate keep, so it outlives the bulk clear; `remove` is the way to drop one.
    func clearAll() {
        invalidateSearch()
        extractionGeneration = UUID()
        captureGeneration = UUID()
        // RETURNING hands back the deleted blobs in the same pass, so no separate SELECT is needed.
        if db != nil,
            let stmt = prepare("DELETE FROM items WHERE pinned_at IS NULL RETURNING id, image_path")
        {
            var orphaned: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let path = sealedPath(stmt), owns(path) { orphaned.append(path) }
            }
            sqlite3_finalize(stmt)
            if !orphaned.isEmpty {
                Task.detached(priority: .utility) {
                    for path in orphaned { Self.removeBlob(atPath: path) }
                }
            }
        }
        // Every pinned row is resident however old, so the window stays whole without a reload.
        items = items.filter(\.isPinned)
    }

    @discardableResult
    func setTextSearchEnabled(_ enabled: Bool) -> Bool {
        guard enabled != textSearchEnabled else { return true }
        if enabled {
            guard let db, sqlite3_exec(db, Self.extractionSchema, nil, nil, nil) == SQLITE_OK else {
                return false
            }
            sqlite3_exec(db, "DELETE FROM item_text_failures", nil, nil, nil)
            // An image that held no text is stored as NULL, and switching on retries it.
            sqlite3_exec(db, "DELETE FROM item_text WHERE text IS NULL", nil, nil, nil)
        }
        textSearchEnabled = enabled
        extractionGeneration = UUID()
        invalidateSearch()
        searchRevision += 1
        return true
    }

    func nextExtractionItem(now: Date = Date()) -> ClipboardItem? {
        guard textSearchEnabled, let cipher else { return nil }
        guard
            let stmt = prepare(
                """
                SELECT \(Self.columns)
                FROM items WHERE kind IN ('image', 'file')
                  AND id NOT IN (SELECT item_id FROM item_text)
                  AND id NOT IN (SELECT item_id FROM item_text_failures
                    WHERE attempts >= 3 OR retry_at > ?1)
                ORDER BY rowid DESC LIMIT 1
                """)
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_ROW ? Self.row(stmt, cipher) : nil
    }

    var nextExtractionRetry: Date? {
        guard textSearchEnabled,
            let stmt = prepare(
                "SELECT MIN(retry_at) FROM item_text_failures WHERE attempts < 3")
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else {
            return nil
        }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
    }

    func recordExtractionFailure(for item: ClipboardItem, generation: UUID, retryAt: Date) {
        guard textSearchEnabled, generation == extractionGeneration,
            let stmt = prepare(
                """
                INSERT INTO item_text_failures(item_id, attempts, retry_at)
                SELECT id, 1, ?2 FROM items WHERE id = ?1
                ON CONFLICT(item_id) DO UPDATE SET attempts = attempts + 1, retry_at = excluded.retry_at
                """)
        else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, retryAt.timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    /// Selects the row rather than naming it, so an item deleted mid-recognition stays deleted.
    @discardableResult
    func setExtractedText(_ text: String, for item: ClipboardItem, generation: UUID) -> Bool {
        guard textSearchEnabled, generation == extractionGeneration, let cipher,
            let stmt = prepare(
                """
                INSERT OR IGNORE INTO item_text(item_id, text)
                SELECT id, ?2 FROM items WHERE id = ?1 AND kind IN ('image', 'file')
                """)
        else { return false }
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        if text.isEmpty {
            sqlite3_bind_null(stmt, 2)
        } else if let sealed = cipher.seal(text, field: .recognizedText, row: item.id) {
            Self.bind(sealed, to: stmt, at: 2)
        } else {
            sqlite3_finalize(stmt)
            return false
        }
        let stored = sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(db) > 0
        sqlite3_finalize(stmt)
        guard stored else { return false }
        if let stmt = prepare("DELETE FROM item_text_failures WHERE item_id = ?1") {
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        invalidateSearch(preservingMatches: true)
        searchRevision += 1
        return true
    }

    /// Only an owned blob is sealed and ours, so only it may grow downscaled copies.
    func ownsImage(of item: ClipboardItem) -> Bool {
        item.imagePath.map(owns) ?? false
    }

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let path = item.imagePath else { return nil }
        return URL(filePath: path, directoryHint: .inferFromPath)
    }

    func fileURL(for item: ClipboardItem) -> URL? {
        guard let path = item.filePath else { return nil }
        return URL(filePath: path, directoryHint: .inferFromPath)
    }

    /// The image's bytes, unsealed when it is ours; nil once the blob is gone or won't open.
    func imageData(for item: ClipboardItem) -> Data? {
        guard let url = imageURL(for: item) else { return nil }
        guard ownsImage(of: item) else { return try? Data(contentsOf: url, options: .mappedIfSafe) }
        guard let key = cipher?.blobKey else { return nil }
        return try? SealedFile.read(url, key: key)
    }

    /// The thumbnail pipeline's key for `item`'s blob, or nil for an image the store doesn't own.
    func imageKey(for item: ClipboardItem) -> SymmetricKey? {
        ownsImage(of: item) ? cipher?.blobKey : nil
    }

    // MARK: - Search

    /// Display order for `query` under `filter`: pinned entries first, each block newest-first.
    func search(_ query: String, filter: ClipboardFilter) -> [ClipboardItem] {
        // Load-bearing: a settled scan changes the answer without `items` changing.
        _ = searchRevision
        let q = query.trimmingCharacters(in: .whitespaces)
        updateDeepSearch(q, filter: filter)
        // The filter joins the key: `rows` rebuilds per render, so a query-only memo goes stale.
        if let searchCache, searchCache.query == q, searchCache.filter == filter {
            return searchCache.result
        }
        let result = q.isEmpty ? filter.apply(to: orderedItems) : matches(q, filter: filter)
        searchCache = (q, filter, result)
        return result
    }

    /// Whether a scan past the memory window is still running, so empty doesn't yet mean none.
    var isSearching: Bool { deepTask != nil }

    /// Returns once the scan in flight has published, so a caller can read the settled answer.
    func searchSettled() async {
        await deepTask?.value
    }

    /// Row index of `item` as currently listed, so the palette can follow a row that moved.
    func rowIndex(of item: ClipboardItem, in query: String, filter: ClipboardFilter) -> Int? {
        search(query, filter: filter).firstIndex { $0.id == item.id }
    }

    /// The Nth visible pinned entry under `query` and `filter`, where 0 is the first pinned row.
    func pinnedItem(at index: Int, in query: String, filter: ClipboardFilter) -> ClipboardItem? {
        guard index >= 0 else { return nil }
        return search(query, filter: filter).prefix(while: \.isPinned).dropFirst(index).first
    }

    /// Where a reset lands: past the pins to the newest clip, or on the first match once typed.
    func landingIndex(in query: String, filter: ClipboardFilter) -> Int {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty else { return 0 }
        return search(query, filter: filter).firstIndex { !$0.isPinned } ?? 0
    }

    /// Exact matches fill the budget before loose ones, then everything returns to recency order.
    private func matches(_ q: String, filter: ClipboardFilter) -> [ClipboardItem] {
        let query = ClipboardQuery(q)
        let deep = deepResult.flatMap { $0.query == q && $0.filter == filter ? $0 : nil }
        var pins = pinnedItems.filter { filter.matches($0) && matchesExactly(query, $0) }
        var pinIDs = Set(pins.map(\.id))

        let windowRank = Dictionary(
            items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<UUID> = []
        var chosen: [(item: ClipboardItem, rank: Int64)] = []
        for (index, item) in items.enumerated()
        where !item.isPinned && filter.matches(item) && matchesExactly(query, item) {
            seen.insert(item.id)
            chosen.append((item, Int64(index)))
            if chosen.count == Self.searchLimit { break }
        }
        // Sorted by the row's pin state now, not at scan time: a pin made since must still show.
        let scanned =
            (deep?.pins ?? []).map { DeepMatch(item: $0, rowid: 0) } + (deep?.exact ?? [])
            + (deep?.loose ?? [])
        for match in scanned {
            let index = windowRank[match.item.id]
            let item = index.map { items[$0] } ?? match.item
            if item.isPinned {
                if pinIDs.insert(item.id).inserted { pins.append(item) }
                continue
            }
            guard chosen.count < Self.searchLimit, seen.insert(item.id).inserted else { continue }
            // A window row ranks by its place in `items`, a deeper one after all of them by rowid.
            let rank = index.map(Int64.init) ?? Int64(items.count) + (Int64.max / 2 - match.rowid)
            chosen.append((item, rank))
        }
        pins.sort { ($0.pinnedAt ?? .distantFuture) < ($1.pinnedAt ?? .distantFuture) }
        return pins + chosen.sorted { $0.rank < $1.rank }.map(\.item)
    }

    private func matchesExactly(_ query: ClipboardQuery, _ item: ClipboardItem) -> Bool {
        guard let text = item.text else { return false }
        if let folded = foldedCache[item.id] { return query.matchesExactly(folded: folded) }
        // Rebuilt rather than evicted piecemeal: rows leave the window in bulk, by prune or clear.
        if foldedCache.count > items.count * 2 + 64 { foldedCache = [:] }
        let folded = ClipboardQuery.fold(text)
        foldedCache[item.id] = folded
        return query.matchesExactly(folded: folded)
    }

    private func invalidateSearch(preservingMatches: Bool = false) {
        searchCache = nil
        orderedCache = nil
        deepTask?.cancel()
        deepTask = nil
        deepRequest = nil
        deepNeedsRefresh = preservingMatches && deepQuery != nil
        if !preservingMatches {
            deepQuery = nil
            deepFilter = nil
            deepResult = nil
        }
    }

    /// Scans run only while the palette shows, so a hidden history never decrypts in the background.
    func setSearchActive(_ active: Bool) {
        guard searchActive != active else { return }
        searchActive = active
        invalidateSearch()
        searchRevision += 1
    }

    private func updateDeepSearch(_ query: String, filter: ClipboardFilter) {
        let residentOnly = query.count < 3
        guard searchActive, db != nil, let cipher, !query.isEmpty,
            !residentOnly || (textSearchEnabled && filter.includesRecognizedText)
        else {
            if deepQuery != nil { invalidateSearch() }
            return
        }
        guard deepQuery != query || deepFilter != filter || deepNeedsRefresh else { return }
        invalidateSearch(preservingMatches: deepQuery == query && deepFilter == filter)
        deepNeedsRefresh = false
        deepQuery = query
        deepFilter = filter
        let request = UUID()
        deepRequest = request
        let parsed = ClipboardQuery(query)
        let residentExact = items.lazy
            .filter { !$0.isPinned && filter.matches($0) && self.matchesExactly(parsed, $0) }
            .prefix(Self.searchLimit).count
        let scan = DeepScan(
            url: dbURL, query: query, filter: filter,
            resident: Set(items.lazy.filter { !$0.isPinned }.map(\.id)), floor: windowFloor(),
            residentOnly: residentOnly,
            recognizedText: textSearchEnabled && filter.includesRecognizedText,
            budget: Self.searchLimit - residentExact, cipher: cipher)
        deepTask = Task(priority: .userInitiated) { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { Self.deepMatches(scan) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, let self, self.deepRequest == request else { return }
            let previous = self.searchCache
            self.deepResult = result
            self.deepTask = nil
            self.searchCache = nil
            self.searchRevision += 1
            if let previous, previous.query == query {
                let current = self.search(query, filter: previous.filter)
                self.onSearchResultsChanged?(query, previous.result, current)
            }
        }
    }

    /// Everything one scan needs, captured on main: the scan itself never touches the store.
    private struct DeepScan: Sendable {
        let url: URL
        let query: String
        let filter: ClipboardFilter
        /// Unpinned rows main holds, whose own text it already matched; never inferred from a rowid.
        let resident: Set<UUID>
        /// A lower bound on every resident rowid, so a short query reads no further down.
        let floor: Int64
        /// A short query only reads recognized text, and only of resident rows and pins.
        let residentOnly: Bool
        let recognizedText: Bool
        /// What is left of `searchLimit` once main's own exact matches are counted.
        let budget: Int
        let cipher: ClipboardCipher
    }

    /// One row as the scan judges it: what its text and recognized text answer for the query.
    private struct ScannedRow {
        let item: ClipboardItem
        let rowid: Int64
        let textExact: Bool
        let recognizedExact: Bool
        let loose: () -> Bool
    }

    /// Pins first and whole, since no budget applies to them; then unpinned rows, newest first.
    nonisolated private static func deepMatches(_ scan: DeepScan) -> DeepResult {
        var result = DeepResult(query: scan.query, filter: scan.filter, pins: [], exact: [], loose: [])
        var db: OpaquePointer?
        guard sqlite3_open_v2(scan.url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return result
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_exec(db, "PRAGMA cache_size=-2048", nil, nil, nil)
        sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil)
        let query = ClipboardQuery(scan.query)
        let loose =
            !scan.residentOnly
            && query.terms.contains { $0.count >= ClipboardQuery.minimumLooseTermLength }
        forEachScanned(db, scan, query, loose: loose, where: "i.pinned_at IS NOT NULL") { row in
            if !row.textExact, row.recognizedExact || row.loose() { result.pins.append(row.item) }
            return true
        }
        let unpinned =
            scan.residentOnly ? "i.pinned_at IS NULL AND i.rowid >= \(scan.floor)" : "i.pinned_at IS NULL"
        forEachScanned(db, scan, query, loose: loose, where: unpinned) { row in
            let resident = scan.resident.contains(row.item.id)
            // Main matched a resident row's own text, and a short query looks at no other row.
            if row.textExact, resident { return true }
            if scan.residentOnly, !resident { return true }
            if row.textExact || row.recognizedExact {
                result.exact.append(DeepMatch(item: row.item, rowid: row.rowid))
            } else if result.loose.count < scan.budget, row.loose() {
                result.loose.append(DeepMatch(item: row.item, rowid: row.rowid))
            }
            // Exact matches alone fill the budget, so nothing further down can still be shown.
            return result.exact.count < scan.budget
        }
        guard !Task.isCancelled else {
            return DeepResult(query: scan.query, filter: scan.filter, pins: [], exact: [], loose: [])
        }
        return result
    }

    /// Unseals and folds each row once; `body` answers whether the walk should go on.
    nonisolated private static func forEachScanned(
        _ db: OpaquePointer?, _ scan: DeepScan, _ query: ClipboardQuery, loose: Bool,
        where condition: String, _ body: (ScannedRow) -> Bool
    ) {
        let prefixed = "i.id, i.kind, i.text, i.image_path, i.created_at, i.source_app, i.pinned_at"
        let recognized =
            scan.recognizedText
            ? "t.text FROM items i LEFT JOIN item_text t ON t.item_id = i.id" : "NULL FROM items i"
        let sql = "SELECT i.rowid, \(prefixed), \(recognized) WHERE \(condition) ORDER BY i.rowid DESC"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while !Task.isCancelled, sqlite3_step(stmt) == SQLITE_ROW {
            guard let item = row(stmt, scan.cipher, from: 1), scan.filter.matches(item) else {
                continue
            }
            let recognized =
                scan.recognizedText
                ? sealedString(stmt, 8, .recognizedText, item.id, scan.cipher).map(ClipboardQuery.fold)
                : nil
            let folded = item.text.map(ClipboardQuery.fold)
            let scanned = ScannedRow(
                item: item, rowid: sqlite3_column_int64(stmt, 0),
                textExact: folded.map(query.matchesExactly(folded:)) == true,
                recognizedExact: recognized.map(query.matchesExactly(folded:)) == true,
                loose: {
                    loose
                        && (folded.map(query.matchesLoosely(folded:)) == true
                            || recognized.map(query.matchesLoosely(folded:)) == true)
                })
            guard body(scanned) else { return }
        }
    }

    // MARK: - Private

    private var orderedItems: [ClipboardItem] {
        if let orderedCache { return orderedCache }
        let pinned = pinnedItems
        // An unpinned history renders `items` as-is, so it never pays for the split.
        let result = pinned.isEmpty ? items : pinned + items.filter { !$0.isPinned }
        orderedCache = result
        return result
    }

    /// The Pinned section in pin order, so a new pin joins the end rather than the head.
    private var pinnedItems: [ClipboardItem] {
        items.filter(\.isPinned)
            .sorted { ($0.pinnedAt ?? .distantFuture) < ($1.pinnedAt ?? .distantFuture) }
    }

    /// The row keeps its place and gains a stamp, which heads the Pinned section.
    private func pin(_ item: ClipboardItem) {
        let stamp = Date()
        let current = items.first { $0.id == item.id } ?? item
        let pinned = current.with(pinnedAt: stamp)
        if let stmt = pinStmt {
            sqlite3_bind_double(stmt, 1, stamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, item.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = pinned
        } else {
            // Pinned from a scan hit outside the window, so splice it in by recency.
            let index = items.firstIndex { $0.createdAt < pinned.createdAt } ?? items.count
            items.insert(pinned, at: index)
        }
    }

    /// Unpinning rejoins as the newest entry. See docs/features/clipboard.md#pinned-entries.
    private func unpin(_ item: ClipboardItem) {
        reinsert(item.with(createdAt: Date(), pinnedAt: nil))
    }

    /// Rewrites the row under the same id so it leads; a delete would take its derived text too.
    private func reinsert(_ updated: ClipboardItem) {
        if let stmt = prepare(
            """
            UPDATE items SET rowid = (SELECT COALESCE(MAX(rowid), 0) + 1 FROM items),
              created_at = ?1, pinned_at = ?2 WHERE id = ?3
            """)
        {
            sqlite3_bind_double(stmt, 1, updated.createdAt.timeIntervalSince1970)
            if let stamp = updated.pinnedAt {
                sqlite3_bind_double(stmt, 2, stamp.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            sqlite3_bind_text(stmt, 3, updated.id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        // Array ops also cover items a scan surfaced from beyond the in-memory window.
        items.removeAll { $0.id == updated.id }
        items.insert(updated, at: 0)
        trimWindow()
    }

    /// Cap the in-memory window, but never drop a pinned row: those render however old they are.
    private func trimWindow() {
        guard items.count > Self.memoryWindow, let index = items.lastIndex(where: { !$0.isPinned })
        else { return }
        items.remove(at: index)
    }

    private func insert(_ item: ClipboardItem) {
        guard let cipher else { return }
        if let stmt = insertStmt { Self.bindAndInsert(stmt, item, cipher) }
        items.insert(item, at: 0)
        trimWindow()
        prune()
    }

    /// Text and source sealed to their row; nothing a reader of the file could search survives.
    @discardableResult
    nonisolated static func bindAndInsert(
        _ stmt: OpaquePointer, _ item: ClipboardItem, _ cipher: ClipboardCipher
    ) -> Bool {
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, item.kind.rawValue, -1, SQLITE_TRANSIENT)
        if let text = item.text {
            guard let sealed = cipher.seal(text, field: .text, row: item.id) else { return false }
            bind(sealed, to: stmt, at: 3)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let path = item.imagePath {
            // Sealed to its row, so pointing one row at another's blob fails rather than shows it.
            guard let sealed = cipher.seal(path, field: .imagePath, row: item.id) else { return false }
            bind(sealed, to: stmt, at: 4)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_double(stmt, 5, item.createdAt.timeIntervalSince1970)
        if let source = item.sourceBundleID {
            guard let sealed = cipher.seal(source, field: .source, row: item.id) else { return false }
            bind(sealed, to: stmt, at: 6)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        if let pinnedAt = item.pinnedAt {
            sqlite3_bind_double(stmt, 7, pinnedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 7)
        }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    nonisolated private static func bind(_ data: Data, to stmt: OpaquePointer?, at index: Int32) {
        data.withUnsafeBytes { buffer in
            _ = sqlite3_bind_blob(stmt, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
        }
    }

    /// The blob path of an `id, image_path` row, unsealed with the row's own id.
    private func sealedPath(_ stmt: OpaquePointer?) -> String? {
        guard let cipher, let id = Self.columnString(stmt, 0).flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        return Self.sealedString(stmt, 1, .imagePath, id, cipher)
    }

    /// Only a blob of ours may ever be deleted, so ownership is never read off an imported path.
    private func owns(_ path: String) -> Bool {
        Self.isOwnedBlob(path, in: imagesDir)
    }

    /// A direct `.sealed` child of `directory`, standardized first: `images/../x` names `x`.
    nonisolated static func isOwnedBlob(_ path: String, in directory: URL) -> Bool {
        guard !path.split(separator: "/").contains("..") else { return false }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.pathExtension == SealedFile.fileExtension
            && url.deletingLastPathComponent().path == directory.standardizedFileURL.path
    }

    /// `lstat`, not `stat`: a sweep must never follow a link someone swapped in for a folder.
    nonisolated static func isRealDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
            == .typeDirectory
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-maxAge)
        deepResult?.removeAll { $0.createdAt < cutoff && !$0.isPinned }
        if let imagesStmt = staleImagesStmt, let deleteStmt = deleteStaleStmt {
            sqlite3_bind_double(imagesStmt, 1, cutoff.timeIntervalSince1970)
            var staleOwnedPaths: [String] = []
            while sqlite3_step(imagesStmt) == SQLITE_ROW {
                // Only delete files we own; an external reference just loses its row.
                if let path = sealedPath(imagesStmt), owns(path) {
                    staleOwnedPaths.append(path)
                }
            }
            sqlite3_reset(imagesStmt)
            sqlite3_clear_bindings(imagesStmt)
            sqlite3_bind_double(deleteStmt, 1, cutoff.timeIntervalSince1970)
            sqlite3_step(deleteStmt)
            if sqlite3_changes(db) > 0 {
                invalidateSearch(preservingMatches: true)
                searchRevision += 1
            }
            sqlite3_reset(deleteStmt)
            sqlite3_clear_bindings(deleteStmt)
            // A retention cut can strand hundreds of files, so delete them off the main actor.
            if !staleOwnedPaths.isEmpty {
                Task.detached(priority: .utility) {
                    for path in staleOwnedPaths { Self.removeBlob(atPath: path) }
                }
            }
        }
        // Against the oldest unpinned row: an exempt pin would make this permanently true.
        if items.last(where: { !$0.isPinned }).map({ $0.createdAt < cutoff }) == true {
            items.removeAll { $0.createdAt < cutoff && !$0.isPinned }
        }
    }

    private func deleteBlob(_ item: ClipboardItem) {
        guard let path = item.imagePath, owns(path) else { return }
        Self.removeBlob(atPath: path)
    }

    nonisolated private static func removeBlob(atPath path: String) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        ImageDerivative.removeCopies(of: url)
    }

    /// Anything in `images/` or its copies that isn't sealed is plaintext an older build left.
    nonisolated private static func removeUnsealedFiles(in directory: URL) {
        guard isRealDirectory(directory) else { return }
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        let stale = Date().addingTimeInterval(-60)
        let thumbnails = directory.appending(path: ".thumbnails", directoryHint: .isDirectory)
        let entries = [directory, thumbnails].filter(isRealDirectory).flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys))
                ?? []
        }
        for url in entries {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            // A `.partial` is a seal still being written, unless it is older than any write takes.
            if name.hasSuffix(".partial") {
                if (values?.contentModificationDate ?? .distantPast) < stale {
                    try? FileManager.default.removeItem(at: url)
                }
            } else if url.pathExtension != SealedFile.fileExtension {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func openDatabase() -> Bool {
        guard let cipher,
            sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
                == SQLITE_OK,
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
                == SQLITE_OK,
            Self.prepareSchema(db, cipher: cipher)
        else { return false }
        // An import holds the write lock a chunk at a time; a delete must wait it out, not drop.
        sqlite3_busy_timeout(db, 2_000)
        insertStmt = prepare(Self.insertSQL)
        // Two indexed branches, deliberately not one OR. See docs/features/clipboard.md#store.
        loadStmt = prepare(
            """
            SELECT \(Self.columns) FROM (
              SELECT rowid AS rid, * FROM items WHERE rowid >= ?1
              UNION ALL
              SELECT rowid AS rid, * FROM items WHERE pinned_at IS NOT NULL AND rowid < ?1
            ) ORDER BY rid DESC
            """)
        windowFloorStmt = prepare(
            "SELECT rowid FROM items WHERE pinned_at IS NULL ORDER BY rowid DESC LIMIT 1 OFFSET ?")
        deleteByIDStmt = prepare("DELETE FROM items WHERE id = ?")
        // Only ever sets a stamp: unpinning rewrites the whole row so it leads the history again.
        pinStmt = prepare("UPDATE items SET pinned_at = ? WHERE id = ?")
        staleImagesStmt = prepare(
            """
            SELECT id, image_path FROM items
            WHERE created_at < ? AND pinned_at IS NULL AND image_path IS NOT NULL
            """)
        deleteStaleStmt = prepare("DELETE FROM items WHERE created_at < ? AND pinned_at IS NULL")
        return insertStmt != nil && loadStmt != nil && windowFloorStmt != nil
            && deleteByIDStmt != nil && pinStmt != nil && staleImagesStmt != nil
            && deleteStaleStmt != nil
    }

    /// Whether `database` is a sealed store this cipher opens, judged by its canary alone.
    nonisolated static func opensSealedStore(at database: URL, cipher: ClipboardCipher) -> Bool {
        guard FileManager.default.fileExists(atPath: database.path) else { return false }
        var db: OpaquePointer?
        defer { sqlite3_close_v2(db) }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            intValue(db, "PRAGMA user_version") == Int64(schemaVersion),
            let canary = meta(db, key: "canary")
        else { return false }
        return cipher.open(canary, field: .canary, row: canaryRow) == canaryValue
    }

    /// A new file gets the schema and a canary; an existing one must be this version and this key.
    nonisolated static func prepareSchema(_ db: OpaquePointer?, cipher: ClipboardCipher) -> Bool {
        let version = intValue(db, "PRAGMA user_version")
        let tables = intValue(db, "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table'")
        if version == 0, tables == 0 {
            guard let canary = cipher.seal(canaryValue, field: .canary, row: canaryRow),
                sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
            else { return false }
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK,
                setMeta(db, key: "canary", value: canary),
                sqlite3_exec(db, "PRAGMA user_version = \(schemaVersion)", nil, nil, nil) == SQLITE_OK,
                sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
            else {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return false
            }
            return true
        }
        guard version == Int64(schemaVersion),
            sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK,
            let canary = meta(db, key: "canary"),
            cipher.open(canary, field: .canary, row: canaryRow) == canaryValue
        else { return false }
        return true
    }

    nonisolated private static func intValue(_ db: OpaquePointer?, _ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : -1
    }

    nonisolated private static func setMeta(_ db: OpaquePointer?, key: String, value: Data) -> Bool {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                db, "INSERT OR REPLACE INTO meta(key, value) VALUES(?1, ?2)", -1, &stmt, nil)
                == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        bind(value, to: stmt, at: 2)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    nonisolated private static func meta(_ db: OpaquePointer?, key: String) -> Data? {
        var stmt: OpaquePointer?
        guard
            sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?1", -1, &stmt, nil)
                == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? columnData(stmt, 0) : nil
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    private func closeDatabase() {
        [
            insertStmt, loadStmt, windowFloorStmt, deleteByIDStmt, pinStmt, staleImagesStmt,
            deleteStaleStmt
        ].forEach { sqlite3_finalize($0) }
        insertStmt = nil
        loadStmt = nil
        windowFloorStmt = nil
        deleteByIDStmt = nil
        pinStmt = nil
        staleImagesStmt = nil
        deleteStaleStmt = nil
        sqlite3_close_v2(db)
        db = nil
    }

    /// Each staged image is sealed into `imagesDirectory`, so retention later reclaims it.
    nonisolated static func importStoredItems(
        inDatabaseAt url: URL, adoptingImagesInto imagesDirectory: URL,
        cipher: ClipboardCipher, _ items: some Sequence<ClipboardItem>
    ) -> Int {
        var keys: Set<Int> = []
        forEachStoredItem(inDatabaseAt: url, cipher: cipher) { keys.insert(importKey($0)) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return 0
        }
        defer { sqlite3_close_v2(db) }
        // A capture from the poller can hold the write lock; without this the import truncates.
        sqlite3_busy_timeout(db, 5_000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        var inserted = 0
        // Committed in chunks, so a delete on the main connection waits briefly, never fails.
        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var pending = 0
        for staged in items {
            if pending == Self.importChunk {
                sqlite3_exec(db, "COMMIT; BEGIN", nil, nil, nil)
                pending = 0
            }
            pending += 1
            let item = adoptionTarget(staged, in: imagesDirectory)
            guard keys.insert(importKey(item)).inserted else { continue }
            if item.imagePath != staged.imagePath,
                !sealBlob(from: staged.imagePath, to: item.imagePath, key: cipher.blobKey)
            {
                continue
            }
            if bindAndInsert(stmt, item, cipher) { inserted += 1 }
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        return inserted
    }

    /// Hashed, never held: a whole history's text must not sit in memory to dedupe an import.
    nonisolated private static func importKey(_ item: ClipboardItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.kind)
        // Keyed off `text` for everything but an image, or every file entry hashes alike.
        hasher.combine(item.kind == .image ? item.imagePath : item.text)
        return hasher.finalize()
    }

    /// The staged name plus `.sealed`, so `a.jpg` and `a.png` stay apart and a re-import dedupes.
    nonisolated private static func adoptionTarget(
        _ item: ClipboardItem, in directory: URL
    ) -> ClipboardItem {
        guard item.kind == .image, let path = item.imagePath, !isOwnedBlob(path, in: directory)
        else { return item }
        return ClipboardItem(
            id: item.id, kind: .image, text: nil,
            imagePath: directory.appendingPathComponent(sealedName(forOriginal: path)).path,
            createdAt: item.createdAt, sourceBundleID: item.sourceBundleID, pinnedAt: item.pinnedAt)
    }

    /// `shot.png` seals as `shot.png.sealed`; a backup exports it back as `shot.png`.
    nonisolated static func sealedName(forOriginal path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent + "." + SealedFile.fileExtension
    }

    /// Copies rather than moves: the source may be another app's file, such as Raycast's.
    nonisolated static func sealBlob(from source: String?, to destination: String?, key: SymmetricKey)
        -> Bool
    {
        // A regular file only, by `lstat`: a link or a device must not be read into history.
        guard let source, let destination,
            (try? FileManager.default.attributesOfItem(atPath: source))?[.type] as? FileAttributeType
                == .typeRegular,
            let data = try? Data(contentsOf: URL(fileURLWithPath: source), options: .mappedIfSafe)
        else { return false }
        return (try? SealedFile.write(data, to: URL(fileURLWithPath: destination), key: key)) != nil
    }

    /// Past the memory window, off-main; answers how many rows wouldn't open, for a backup to report.
    @discardableResult
    nonisolated static func forEachStoredItem(
        inDatabaseAt url: URL, cipher: ClipboardCipher, _ body: (ClipboardItem) -> Void
    ) -> Int {
        var db: OpaquePointer?
        // `READWRITE` because a WAL reader still writes `-shm`.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close_v2(db)
            return 0
        }
        defer { sqlite3_close_v2(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT \(columns) FROM items ORDER BY rowid"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        var unreadable = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let item = row(stmt, cipher) { body(item) } else { unreadable += 1 }
        }
        return unreadable
    }

    /// nil when a sealed field fails to open: a row under another key is unreadable, not empty.
    nonisolated private static func row(
        _ stmt: OpaquePointer?, _ cipher: ClipboardCipher, from base: Int32 = 0
    ) -> ClipboardItem? {
        guard let idString = columnString(stmt, base), let id = UUID(uuidString: idString),
            let kindString = columnString(stmt, base + 1),
            let kind = ClipboardItem.Kind(rawValue: kindString)
        else { return nil }
        var text: String?
        if sqlite3_column_type(stmt, base + 2) != SQLITE_NULL {
            guard let opened = sealedString(stmt, base + 2, .text, id, cipher) else { return nil }
            text = opened
        }
        var imagePath: String?
        if sqlite3_column_type(stmt, base + 3) != SQLITE_NULL {
            guard let opened = sealedString(stmt, base + 3, .imagePath, id, cipher) else { return nil }
            imagePath = opened
        }
        return ClipboardItem(
            id: id, kind: kind, text: text, imagePath: imagePath,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, base + 4)),
            sourceBundleID: sealedString(stmt, base + 5, .source, id, cipher),
            pinnedAt: columnDate(stmt, base + 6))
    }

    nonisolated private static func sealedString(
        _ stmt: OpaquePointer?, _ index: Int32, _ field: ClipboardCipher.Field, _ row: UUID,
        _ cipher: ClipboardCipher
    ) -> String? {
        columnData(stmt, index).flatMap { cipher.open($0, field: field, row: row) }
    }

    nonisolated private static func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }

    nonisolated private static func columnData(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard let bytes = sqlite3_column_blob(stmt, index) else { return count == 0 ? Data() : nil }
        return Data(bytes: bytes, count: count)
    }

    nonisolated static func columnString(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: UnsafeBufferPointer(start: ptr, count: count), as: UTF8.self)
    }
}

extension ClipboardFilter {
    /// Recognized text belongs to images and files, so only these filters search it.
    var includesRecognizedText: Bool {
        self == .all || self == .image || self == .file
    }
}
