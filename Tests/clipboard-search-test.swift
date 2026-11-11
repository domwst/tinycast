import CryptoKit
import Foundation

@main
@MainActor
struct ClipboardSearchTests {
    static var checks = 0
    static var failures = 0
    static var metadata: [UUID: String] = [:]
    static var scratch: [URL] = []
    /// Spreads each batch of `texts(_:)` apart in time, so batches never interleave.
    static var clock = 0
    static let queries = [
        "", " ", "a", "al", "common", "invoice", "rare", "absent-value",
        "COMMON", "café", "日本語", "say \"yes\"", "  common  ", "pdf"
    ]

    static func main() async {
        let store = makeStore()
        let now = Date()
        let entries = (0..<2500).map { index in
            let kind: ClipboardItem.Kind = index % 3 == 0 ? .text : index % 3 == 1 ? .file : .image
            let suffix = " \(index) café 日本語 say \"yes\"" + (index % 401 == 0 ? " rare" : "")
            // Already under imagesDir, so the import keeps each path rather than sealing a copy.
            let image = store.imagesDir.appendingPathComponent("\(index).\(SealedFile.fileExtension)")
            let item = ClipboardItem(
                id: UUID(), kind: kind,
                text: kind == .text
                    ? "Common alphabet" + suffix : kind == .file ? "/fixture/common\(index).pdf" : nil,
                imagePath: kind == .image ? image.path : nil,
                createdAt: now.addingTimeInterval(Double(-index)), sourceBundleID: nil,
                pinnedAt: index < 220 ? now.addingTimeInterval(Double(-index)) : nil)
            if kind != .text, index % 7 != 0 { metadata[item.id] = "Common invoice" + suffix }
            return item
        }
        let imported = ClipboardStore.importStoredItems(
            inDatabaseAt: store.dbURL, adoptingImagesInto: store.imagesDir, cipher: .harness, entries)
        precondition(imported == entries.count, "the fixture history imports whole")
        store.load()
        await compare(store, phase: "disabled by default")
        precondition(store.setTextSearchEnabled(true))
        for entry in entries {
            if let text = metadata[entry.id] {
                precondition(store.setExtractedText(text, for: entry, generation: store.extractionGeneration))
            }
        }
        await compare(store, phase: "enabled mixed history")
        let old = entries[224]
        metadata[old.id] = "common invoice rare"
        precondition(
            store.setExtractedText(metadata[old.id]!, for: old, generation: store.extractionGeneration))
        await compare(store, phase: "late OCR outside window")
        store.promote(entries[400])
        store.togglePinned(entries[401])
        await compare(store, phase: "promotion and pinning")
        store.setTextSearchEnabled(false)
        store.promote(entries[401])
        store.togglePinned(store.items.first { $0.id == entries[401].id }!)
        store.promote(entries[400])
        await compare(store, phase: "disabled with populated OCR database")
        store.setTextSearchEnabled(true)
        await compare(store, phase: "reenabled preserves historical text")
        store.remove(entries[400])
        metadata.removeValue(forKey: entries[400].id)
        await compare(store, phase: "deleted indexed row")
        store.close()
        store.open(cipher: .harness)
        store.load()
        await compare(store, phase: "reopened defaults off")
        store.setTextSearchEnabled(true)
        await compare(store, phase: "reopened and enabled")

        // Each filter switch supersedes the scan before it; only the last one may publish.
        _ = store.search("common", filter: .all)
        _ = store.search("common", filter: .image)
        _ = store.search("common", filter: .file)
        await store.searchSettled()
        let files = store.search("common", filter: .file)
        expect(!files.isEmpty && files.allSatisfy { $0.kind == .file }, "a superseded filter never publishes")
        expect(
            same(files, Reference(store, active: true).answer("common", .file, settled: true)),
            "and the last filter's scan settles to its own answer")

        _ = store.search("", filter: .all)
        var publications: [String] = []
        store.onSearchResultsChanged = { query, _, _ in publications.append(query) }
        _ = store.search("invoice", filter: .all)
        _ = store.search("raretoken-never-present", filter: .all)
        store.setSearchActive(false)
        expect(!store.isSearching, "hiding the palette cancels the scan in flight")
        try? await Task.sleep(for: .milliseconds(40))
        expect(publications.isEmpty, "hidden palette accepts no superseded publications")
        expect(store.search("invoice", filter: .all).isEmpty, "hidden palette cannot restart OCR search")
        expect(!store.isSearching, "and starts no scan of its own")
        store.onSearchResultsChanged = nil
        await compare(store, phase: "hidden palette", active: false)
        store.setSearchActive(true)
        store.clearAll()
        // Pins outlive Clear History, and so does the OCR text recorded against them.
        let survivors = Set(store.items.map(\.id))
        metadata = metadata.filter { survivors.contains($0.key) }
        await compare(store, phase: "cleared")
        store.close()
        for query in queries {
            expect(store.search(query, filter: .all).isEmpty, "a closed store answers \(query) with nothing")
        }
        expect(!store.isSearching, "and scans nothing")

        await looseMatching()
        await exactMatchesFillTheBudgetFirst()
        await pinsAreFoundPastAFullBudget()
        await shortQueriesSpendTheBudgetOnNewRows()

        // Not a `defer`: `exit` skips those, and a failing run must not strand its fixtures.
        for directory in scratch { try? FileManager.default.removeItem(at: directory) }
        print("\(checks) search comparisons, \(failures) failure(s)")
        if failures > 0 { exit(1) }
    }

    // MARK: - Phases

    static func compare(_ store: ClipboardStore, phase: String, active: Bool = true) async {
        let reference = Reference(store, active: active)
        expect(reference.unreadable == 0, "\(phase): every stored row opens under the store's key")
        for query in queries {
            for filter in ClipboardFilter.allCases {
                _ = store.search("", filter: .all)
                let immediate = store.search(query, filter: filter)
                let expectedImmediate = reference.answer(query, filter, settled: false)
                let immediateDiff = diff(immediate, expectedImmediate, pins: reference.pinIDs)
                expect(
                    same(immediate, expectedImmediate),
                    "\(phase): immediate \(query) / \(filter)\(immediateDiff)")
                expect(
                    store.isSearching == reference.scans(query, filter),
                    "\(phase): \(query) / \(filter) scans only when a scan can add rows")
                await store.searchSettled()
                let actual = store.search(query, filter: filter)
                let expected = reference.answer(query, filter, settled: true)
                if active, store.textSearchEnabled, !metadata.isEmpty, query == "common",
                    filter == .image
                {
                    expect(!actual.isEmpty, "\(phase): text and OCR files cannot starve image matches")
                }
                let settledDiff = diff(actual, expected, pins: reference.pinIDs)
                expect(same(actual, expected), "\(phase): settled \(query) / \(filter)\(settledDiff)")
                expect(same(store.search(query, filter: filter), actual), "\(phase): memo differs")
                expect(Set(actual.map(\.id)).count == actual.count, "\(phase): duplicate result")
                checks += 1
            }
        }
    }

    /// Brute force over every stored row, sharing none of the store's matching code.
    struct Reference {
        static let budget = 200
        let pins: [ClipboardItem]
        var pinIDs: Set<UUID> { Set(pins.map(\.id)) }
        let window: [ClipboardItem]
        /// Unpinned rows outside the window, newest rowid first.
        let older: [ClipboardItem]
        let folded: [UUID: String]
        let recognized: [UUID: String]
        let textSearch: Bool
        let active: Bool
        let isOpen: Bool
        let unreadable: Int

        @MainActor
        init(_ store: ClipboardStore, active: Bool) {
            var stored: [ClipboardItem] = []
            unreadable =
                (try? ClipboardStore.forEachStoredItem(inDatabaseAt: store.dbURL, cipher: .harness) {
                    stored.append($0)
                }) ?? -1
            pins = store.items.filter(\.isPinned).sorted { $0.pinnedAt! < $1.pinnedAt! }
            window = store.items.filter { !$0.isPinned }
            let resident = Set(window.map(\.id))
            older = stored.reversed().filter { !$0.isPinned && !resident.contains($0.id) }
            folded = Dictionary(
                stored.compactMap { item in item.text.map { (item.id, Self.fold($0)) } },
                uniquingKeysWith: { first, _ in first })
            recognized = metadata.mapValues(Self.fold)
            textSearch = store.textSearchEnabled
            self.active = active
            isOpen = store.isOpen
        }

        /// Lowercased with combining marks dropped: an independent spelling of the folding rule.
        static func fold(_ text: String) -> String {
            var scalars = String.UnicodeScalarView()
            for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars
            where scalar.properties.generalCategory != .nonspacingMark {
                scalars.append(scalar)
            }
            return String(scalars).lowercased()
        }

        static func readsRecognizedText(_ filter: ClipboardFilter) -> Bool {
            filter == .all || filter == .image || filter == .file
        }

        func scans(_ query: String, _ filter: ClipboardFilter) -> Bool {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            let short = trimmed.count < 3
            return active && isOpen && !trimmed.isEmpty
                && (!short || (textSearch && Self.readsRecognizedText(filter)))
        }

        func answer(_ query: String, _ filter: ClipboardFilter, settled: Bool) -> [UUID] {
            guard isOpen else { return [] }
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return filter.apply(to: pins + window).map(\.id) }
            let terms = trimmed.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
            let short = trimmed.count < 3
            let scanned = settled && scans(query, filter)
            let ocr = scanned && textSearch && Self.readsRecognizedText(filter)
            func holds(_ text: String?) -> Bool {
                guard let text else { return false }
                return terms.allSatisfy { text.contains($0) }
            }
            let byText = { (item: ClipboardItem) in holds(folded[item.id]) }
            let byOCR = { (item: ClipboardItem) in ocr && holds(recognized[item.id]) }

            let matchedPins = pins.filter { filter.matches($0) && (byText($0) || byOCR($0)) }
            // The window's own text matches are answered at once and never displaced by a scan.
            let immediate = Array(window.filter { filter.matches($0) && byText($0) }.prefix(Self.budget))
            guard scanned else { return (matchedPins + immediate).map(\.id) }
            let taken = Set(immediate.map(\.id))
            let windowRest = window.filter { !taken.contains($0.id) && filter.matches($0) && byOCR($0) }
            let olderRest =
                short ? [] : older.filter { filter.matches($0) && (byText($0) || byOCR($0)) }
            let rest = (windowRest + olderRest).prefix(Self.budget - immediate.count)
            let rank = Dictionary(
                (window + older).enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
            let chosen = (immediate + rest).sorted { rank[$0.id]! < rank[$1.id]! }
            return (matchedPins + chosen).map(\.id)
        }
    }

    // MARK: - Explicit cases

    /// Typo tolerance is a scan-only fallback for longer alphabetic terms.
    static func looseMatching() async {
        let store = makeStore()
        let password = "my password is hunter2"
        let token = "the token expired"
        let tokyo = "東京大学に行く"
        let resume = "Résumé draft"
        for text in [password, token, tokyo, resume] { store.addText(text, sourceBundleID: nil) }
        let cases: [(String, [String], String)] = [
            ("pasword", [password], "a dropped letter is one edit"),
            ("passwrod", [password], "and so is a transposition"),
            ("paswordd", [password], "eight letters tolerate two edits"),
            ("pasvord", [], "seven letters tolerate only one"),
            ("tken", [token], "four letters is where typos start to count"),
            ("tkn", [], "a three-letter term stays literal"),
            ("hunter pasw", [password], "the last term may be a mistyped prefix"),
            ("pasw hunter", [], "an earlier term must be near a whole word"),
            ("pasword hunter", [password], "a typo and an exact term combine"),
            ("pasword token", [], "every term is still required"),
            ("resumee", [resume], "typos are measured on the folded word"),
            ("東京大学", [tokyo], "an ideographic term matches exactly"),
            ("東京大字", [], "but tolerates no typo")
        ]
        for (query, expected, label) in cases {
            expect(await settledTexts(store, query) == expected, "\(query): \(label)")
        }
        expect(store.search("pasword", filter: .all).isEmpty, "the immediate answer is exact only")
        expect(store.isSearching, "while the scan that finds typos runs")
    }

    static func exactMatchesFillTheBudgetFirst() async {
        let full = makeStore()
        // 210 exact matches below the window, and 10 newer loose ones inside it.
        full.importEntries(
            texts((0..<210).map { "password exact \($0)" }) + texts((0..<990).map { "filler \($0)" })
                + texts((0..<10).map { "pasword loose \($0)" }))
        expect(full.search("password", filter: .all).isEmpty, "no resident row matches exactly")
        expect(
            await settledTexts(full, "password") == (10..<210).reversed().map { "password exact \($0)" },
            "exact matches fill the budget before any newer loose one, newest first")

        let roomy = makeStore()
        // Every match lies below a window of 1000 newer rows.
        roomy.importEntries(
            texts((0..<50).map { "password exact \($0)" }) + texts((0..<10).map { "pasword loose \($0)" })
                + texts((0..<1000).map { "filler \($0)" }))
        expect(
            await settledTexts(roomy, "password")
                == (0..<10).reversed().map { "pasword loose \($0)" }
                + (0..<50).reversed().map { "password exact \($0)" },
            "loose matches fill what is left, and the answer returns to recency order")
    }

    /// Pins sit outside the budget, so a full one must not stop the scan short of an old pin.
    static func pinsAreFoundPastAFullBudget() async {
        let store = makeStore()
        precondition(store.setTextSearchEnabled(true))
        let base = Date().addingTimeInterval(-100_000)
        let loosePin = ClipboardItem(
            id: UUID(), kind: .text, text: "pasword pinned", imagePath: nil, createdAt: base,
            sourceBundleID: nil, pinnedAt: base)
        let imagePin = ClipboardItem(
            id: UUID(), kind: .image, text: nil,
            imagePath: store.imagesDir.appendingPathComponent("pin.\(SealedFile.fileExtension)").path,
            createdAt: base.addingTimeInterval(1), sourceBundleID: nil,
            pinnedAt: base.addingTimeInterval(1))
        let rows = (0..<1300).map {
            ClipboardItem(
                id: UUID(), kind: .text, text: "password \($0)", imagePath: nil,
                createdAt: base.addingTimeInterval(Double(10 + $0)), sourceBundleID: nil)
        }
        _ = ClipboardStore.importStoredItems(
            inDatabaseAt: store.dbURL, adoptingImagesInto: store.imagesDir, cipher: .harness,
            [loosePin, imagePin] + rows)
        store.load()
        precondition(
            store.setExtractedText(
                "password on a screenshot", for: imagePin, generation: store.extractionGeneration))
        let settled = await settledSearch(store, "password")
        expect(settled.count == 202, "both pins lead a full budget of 200 (got \(settled.count))")
        expect(settled.first?.id == loosePin.id, "a loosely matching old pin is found")
        expect(settled.dropFirst().first?.id == imagePin.id, "and so is one matched by its image's text")
        expect(
            settled.first { !$0.isPinned }?.text == "password 1299", "the budget keeps the newest matches")
    }

    /// A row the window already matched by text must not spend the budget a second time.
    static func shortQueriesSpendTheBudgetOnNewRows() async {
        let store = makeStore()
        precondition(store.setTextSearchEnabled(true))
        let base = Date().addingTimeInterval(-100_000)
        let rows = (0..<300).map {
            ClipboardItem(
                id: UUID(), kind: .file, text: $0 % 2 == 0 ? "/x/ab\($0).pdf" : "/x/f\($0).pdf",
                imagePath: nil, createdAt: base.addingTimeInterval(Double($0)), sourceBundleID: nil)
        }
        store.importEntries(rows)
        for row in rows {
            precondition(store.setExtractedText("ab", for: row, generation: store.extractionGeneration))
        }
        let byText = rows.filter { $0.text!.contains("ab") }.reversed().map(\.id)
        let byOCR = rows.filter { !$0.text!.contains("ab") }.reversed().prefix(50).map(\.id)
        let settled = await settledSearch(store, "ab", filter: .file)
        expect(
            settled.count == 200,
            "a short query fills its budget from recognized text (got \(settled.count))")
        expect(
            Set(settled.map(\.id)) == Set(byText + byOCR),
            "with every text match and then the newest recognized-only ones")
    }

    // MARK: - Harness

    static func makeStore() -> ClipboardStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-search-\(UUID().uuidString)")
        scratch.append(directory)
        let store = ClipboardStore(directory: directory, cipher: .harness)
        store.maxAge = ClipboardRetention.forever.maxAge
        return store
    }

    /// Oldest first, a second apart, so the import's order is the recency order.
    static func texts(_ values: [String]) -> [ClipboardItem] {
        let base = Date().addingTimeInterval(-1_000_000 + Double(clock))
        clock += values.count
        return values.enumerated().map {
            ClipboardItem(
                id: UUID(), kind: .text, text: $1, imagePath: nil,
                createdAt: base.addingTimeInterval(Double($0)), sourceBundleID: nil)
        }
    }

    static func settledSearch(
        _ store: ClipboardStore, _ query: String, filter: ClipboardFilter = .all
    ) async -> [ClipboardItem] {
        _ = store.search(query, filter: filter)
        await store.searchSettled()
        return store.search(query, filter: filter)
    }

    static func settledTexts(_ store: ClipboardStore, _ query: String) async -> [String] {
        await settledSearch(store, query).compactMap(\.text)
    }

    static func same(_ actual: [ClipboardItem], _ expected: [UUID]) -> Bool {
        actual.map(\.id) == expected
    }

    static func same(_ actual: [ClipboardItem], _ expected: [ClipboardItem]) -> Bool {
        actual.map(\.id) == expected.map(\.id) && actual.map(\.isPinned) == expected.map(\.isPinned)
    }

    static func diff(_ actual: [ClipboardItem], _ expected: [UUID], pins: Set<UUID>) -> String {
        let got = actual.map(\.id)
        guard got != expected else { return "" }
        let missing = Set(expected).subtracting(got)
        let extra = Set(got).subtracting(expected).count
        let shared = min(got.count, expected.count)
        let first = (0..<shared).first { got[$0] != expected[$0] } ?? shared
        return " — got \(got.count), expected \(expected.count), "
            + "\(missing.intersection(pins).count) pins and \(missing.subtracting(pins).count) others "
            + "missing, \(extra) extra, first difference at \(first)"
    }

    static func expect(_ condition: Bool, _ label: String) {
        guard !condition else { return }
        failures += 1
        if failures <= 400 { print("FAIL: \(label)") }
    }
}

extension ClipboardCipher {
    static let harness = ClipboardCipher(rootKey: SymmetricKey(size: .bits256))
}
