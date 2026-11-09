import AppKit

@MainActor
final class ClipboardCoordinator {
    private let clipboardStore: ClipboardStore
    private let clipboardManager: ClipboardManager
    private let settings: AppSettings
    private let appIndex: AppIndex
    private let palette: PaletteState
    private let windowController: PaletteWindowController
    private let paletteCoordinator: PaletteCoordinator
    /// Dialogs, for the one action here that can't be undone.
    private unowned let core: AppCore
    /// One Copy Text at a time: a newer trigger cancels the helper an older one is waiting on.
    private var textTask: Task<Void, Never>?
    private var pasteSequence: PasteSequence?
    /// One Keychain read at a time; every opener waits on the same answer.
    private var unlocking: Task<ClipboardCipher?, Never>?

    init(
        clipboardStore: ClipboardStore,
        clipboardManager: ClipboardManager,
        settings: AppSettings,
        appIndex: AppIndex,
        palette: PaletteState,
        windowController: PaletteWindowController,
        paletteCoordinator: PaletteCoordinator,
        core: AppCore
    ) {
        self.clipboardStore = clipboardStore
        self.clipboardManager = clipboardManager
        self.settings = settings
        self.appIndex = appIndex
        self.palette = palette
        self.windowController = windowController
        self.paletteCoordinator = paletteCoordinator
        self.core = core
    }

    /// Off means the poller stops, the database closes and nothing new is ever recorded.
    func applyEnabled() {
        appIndex.setCommandsVisible([.clipboardHistory, .pasteSequentially], settings.clipboardEnabled)
        guard settings.clipboardEnabled else {
            core.applyClipboardTextSearch()
            clipboardManager.stop()
            if palette.mode == .clipboard { palette.prepare(mode: .launcher) }
            clipboardStore.close()
            Task { await sealLegacyHistory() }
            return
        }
        Task { await openHistory() }
    }

    /// The key lives in the Keychain, read off-main, so the history opens a moment after launch.
    private func openHistory() async {
        guard let cipher = await historyCipher() else { return reportLocked() }
        guard settings.clipboardEnabled, !clipboardStore.isOpen else { return }
        clipboardStore.open(cipher: cipher)
        clipboardStore.maxAge = settings.clipboardRetention.maxAge
        clipboardStore.onSearchResultsChanged = { [weak self] query, previous, current in
            self?.followSearchResults(query: query, previous: previous, current: current)
        }
        clipboardStore.load()
        // Capture starts last: a copy recorded into a store not yet open would be lost.
        clipboardManager.start()
        core.applyClipboardTextSearch()
    }

    /// A plaintext history from before encryption is sealed even while capture stays off.
    private func sealLegacyHistory() async {
        let database = clipboardStore.dbURL
        let pending = await Task.detached(priority: .utility) {
            ClipboardEncryptionMigration.isPending(database: database)
        }.value
        if pending { _ = await historyCipher() }
    }

    /// The store's own key once opened, otherwise one Keychain read (and conversion) off-main.
    func historyCipher() async -> ClipboardCipher? {
        if let cipher = clipboardStore.cipher { return cipher }
        if let unlocking { return await unlocking.value }
        let database = clipboardStore.dbURL
        let images = clipboardStore.imagesDir
        let task = Task.detached(priority: .userInitiated) { () -> ClipboardCipher? in
            guard case .ready(let cipher) = ClipboardKeyStore.unlock(database: database, images: images)
            else { return nil }
            return cipher
        }
        unlocking = task
        let cipher = await task.value
        unlocking = nil
        return cipher
    }

    /// For a one-off write with the feature off, as Clear History and an import make.
    func openForWrite() async -> Bool {
        guard let cipher = await historyCipher() else {
            reportLocked()
            return false
        }
        clipboardStore.open(cipher: cipher)
        return clipboardStore.isOpen
    }

    func closeIfDisabled() {
        if !settings.clipboardEnabled { clipboardStore.close() }
    }

    private func reportLocked() {
        core.showMessage(ClipboardKeyStore.Failure.locked.localizedDescription, tone: .danger)
    }

    func followSearchResults(query: String, previous: [ClipboardItem], current: [ClipboardItem]) {
        guard palette.isVisible, palette.mode == .clipboard,
            palette.query.trimmingCharacters(in: .whitespaces) == query,
            previous.indices.contains(palette.selection)
        else { return }
        let selectedID = previous[palette.selection].id
        if let index = current.firstIndex(where: { $0.id == selectedID }) {
            palette.selection = index
        }
    }

    func applyRetention(_ retention: ClipboardRetention) {
        clipboardStore.maxAge = retention.maxAge
        clipboardStore.enforceLimits()
    }

    /// ↵ runs the configured default and the other chords follow it; false when `chord` has none.
    @discardableResult
    func activate(_ item: ClipboardItem, chord: ClipboardChord = .return) -> Bool {
        guard let action = settings.clipboardDefaultAction.action(for: chord, on: item) else {
            return false
        }
        perform(action, on: item)
        return true
    }

    func perform(_ action: ClipboardDefaultAction, on item: ClipboardItem) {
        switch action {
        case .paste: paste(item)
        case .copy: copyToClipboard(item)
        case .pastePlainText: pasteAsPlainText(item)
        }
    }

    func paste(_ item: ClipboardItem) {
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        // A paste promotes the item, so follow it and keep the moved row highlighted.
        if Paster.paste(item, store: clipboardStore, previousApp: previous) {
            selectClip(item)
        } else {
            reportUnavailable(item)
        }
    }

    /// A file's path stays valid text after the file goes, so this never reports it missing.
    func pasteAsPlainText(_ item: ClipboardItem) {
        let previous = windowController.previousApp
        paletteCoordinator.hidePalette(restoreFocus: false)
        if Paster.pastePlainText(item, store: clipboardStore, previousApp: previous) {
            selectClip(item)
        }
    }

    func pasteKeepingWindowOpen(_ item: ClipboardItem) {
        if !windowController.pasteKeepingWindowOpen(item, store: clipboardStore) {
            reportUnavailable(item)
        }
    }

    /// Each press pastes the next older entry into the app in front, never promoting it.
    func pasteNextInSequence() {
        let now = Date()
        // Dropped rather than queued, so a held shortcut cannot paste a burst of entries.
        if let pasteSequence, pasteSequence.isSettling(at: now) { return }
        guard let target = paletteCoordinator.targetApp else { return }
        // A copy made just before the press must reach history, or the walk starts one entry late.
        clipboardManager.prepareForTinycastPasteboardMutation()
        var sequence = continuingPasteSequence(at: now)
        while let item = sequence.next(in: clipboardStore.items) {
            if paletteCoordinator.isVisible { paletteCoordinator.hidePalette() }
            // An image or file gone from disk writes nothing, so the press moves on to the next.
            guard Paster.pasteInPlace(item, store: clipboardStore, into: target) else { continue }
            sequence.recordPaste(changeCount: NSPasteboard.general.changeCount, at: now)
            pasteSequence = sequence
            return
        }
        core.showMessage(String(localized: "Nothing left to paste"), tone: .neutral)
    }

    /// A copy since the last press, or a long pause, starts the walk over from the newest entry.
    private func continuingPasteSequence(at now: Date) -> PasteSequence {
        let changeCount = NSPasteboard.general.changeCount
        if let pasteSequence, pasteSequence.continues(changeCount: changeCount, at: now) {
            return pasteSequence
        }
        return PasteSequence(history: clipboardStore.items, changeCount: changeCount, now: now)
    }

    /// A write only fails on a vanished file, and a palette that just closes explains nothing.
    private func reportUnavailable(_ item: ClipboardItem) {
        guard item.kind == .file else { return }
        core.showMessage(String(localized: "That file has moved or been deleted."), tone: .danger)
    }

    /// Both the ⌃⇧X chord and the menu row land here, so neither can skip the confirmation.
    func deleteAllClips() async {
        guard
            await core.confirm(
                title: String(localized: "Delete All Entries"),
                message: String(
                    localized: """
                        Are you sure you want to proceed with deleting all clipboard history entries?
                        """),
                symbol: PaletteMode.clipboard.systemImage, confirmTitle: String(localized: "Delete All"))
        else { return }
        clearHistory()
    }

    /// Reachable with the feature off, so what was kept before can still be erased afterwards.
    func clearHistory() {
        Task {
            guard await openForWrite() else { return }
            clipboardStore.clearAll()
            closeIfDisabled()
        }
    }

    func copyToClipboard(_ item: ClipboardItem) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        if Paster.copy(item, store: clipboardStore) {
            selectClip(item)
        } else {
            reportUnavailable(item)
        }
    }

    /// Unmarked, so a converted colour enters history itself — it is one you meant to keep.
    func copyColor(_ color: ColorValue, as format: ColorFormat) {
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(format.string(for: color))
    }

    /// A sealed image has no file worth revealing, so ⌘F saves a copy of it instead.
    func revealClip(_ item: ClipboardItem) {
        guard let url = clipURL(for: item) else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        guard clipboardStore.ownsImage(of: item) else { return AppLauncher.showInFinder(url) }
        saveImage(item)
    }

    private func saveImage(_ item: ClipboardItem) {
        guard let data = clipboardStore.imageData(for: item) else { return reportUnavailable(item) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = ClipboardExports.imageName
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            core.showMessage(String(localized: "Couldn’t save the image"), tone: .danger)
        }
    }

    /// Nil only for a vanished file, which the HUD reports rather than hand over a dead path.
    func dragPayload(for item: ClipboardItem) -> ClipDragPayload? {
        let payload = item.dragPayload
        guard case .file = payload else { return payload }
        guard let url = clipURL(for: item) else { return nil }
        return clipboardStore.ownsImage(of: item) ? .sealedImage(url) : .file(url)
    }

    func openClip(_ item: ClipboardItem) {
        guard let url = clipURL(for: item) else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        AppLauncher.open(url)
    }

    /// Unmarked, so the path enters history like any other copy the reader meant to make.
    func copyClipPath(_ item: ClipboardItem) {
        guard let path = item.filePath else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        Paster.copyPlainText(path)
        core.showMessage(String(localized: "Copied path"))
    }

    func copyImageText(_ item: ClipboardItem) {
        guard let path = item.imagePath ?? item.filePath else { return }
        paletteCoordinator.hidePalette(restoreFocus: false)
        core.showProgress(String(localized: "Reading text…"))
        let changeCount = NSPasteboard.general.changeCount
        textTask?.cancel()
        textTask = Task {
            do {
                // A stat on an unmounted or network volume can stall, so it stays off-main.
                let exists = await Task.detached { FileManager.default.fileExists(atPath: path) }.value
                try Task.checkCancellation()
                guard exists else {
                    return item.kind == .file
                        ? reportUnavailable(item)
                        : core.showMessage(
                            String(localized: "That image is no longer available."), tone: .danger)
                }
                let text = try await ClipboardTextWorker.extract(
                    item, imageKey: clipboardStore.imageKey(for: item))
                guard !text.isEmpty else {
                    return core.showMessage(String(localized: "No text found"), tone: .neutral)
                }
                guard NSPasteboard.general.changeCount == changeCount else {
                    return core.showMessage(
                        String(localized: "Clipboard changed, text not copied"), tone: .neutral)
                }
                Paster.copyPlainText(text)
                core.showMessage(String(localized: "Copied text"))
            } catch is CancellationError {
            } catch {
                core.showMessage(String(localized: "Couldn’t read the text"), tone: .danger)
            }
        }
    }

    /// Nil once the file is gone, so every action reports rather than silently no-opping.
    private func clipURL(for item: ClipboardItem) -> URL? {
        let url = clipboardStore.imageURL(for: item) ?? clipboardStore.fileURL(for: item)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            reportUnavailable(item)
            return nil
        }
        return url
    }

    func editClip(_ item: ClipboardItem) async {
        guard item.kind == .text else { return }
        guard let text = await core.editClipboardText(item.text ?? ""), !text.isEmpty else { return }
        do {
            guard let edited = try clipboardStore.updateText(text, of: item) else {
                Paster.copyPlainText(text)
                return
            }
            Paster.copy(edited, store: clipboardStore)
            guard palette.mode == .clipboard else { return }
            if !palette.clipboardFilter.matches(edited) { palette.clipboardFilter = .all }
            if clipboardStore.rowIndex(of: edited, in: palette.query, filter: palette.clipboardFilter) == nil
            {
                palette.query = ""
            }
            selectClip(edited)
            palette.preserveSelection()
            palette.followToken = UUID()
        } catch .tooLong {
            let limit = ClipboardStore.maxTextLength.formatted()
            core.showMessage(
                String(localized: "Too long to save. Keep it under \(limit) characters."), tone: .danger)
        } catch {
            core.showMessage(String(localized: "Couldn’t save the clipboard entry"), tone: .danger)
        }
    }

    /// Pin or unpin an entry; the selection and scroll follow the row as it moves.
    func togglePinnedClip(_ item: ClipboardItem) {
        clipboardStore.togglePinned(item)
        selectClip(item)
        palette.followToken = UUID()
    }

    /// Select `item`'s row as currently filtered; a moved row isn't always index 0.
    private func selectClip(_ item: ClipboardItem) {
        palette.selection =
            clipboardStore.rowIndex(
                of: item, in: palette.query, filter: palette.clipboardFilter) ?? 0
    }
}
