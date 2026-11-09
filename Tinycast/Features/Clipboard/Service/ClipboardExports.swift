import AppKit
import CryptoKit
import Synchronization
import UniformTypeIdentifiers

/// Unsealed copies another app is handed by path, in Caches; the history itself never holds one.
nonisolated enum ClipboardExports {
    static let imageName = "Clipboard Image.png"

    static var directory: URL {
        AppPaths.caches().appendingPathComponent("clipboard-exports", isDirectory: true)
    }

    private struct State {
        var exported = false
        /// The general pasteboard's generation the copies were made for.
        var generation: Int?
        /// Bumped by every discard, so a provider attached before it never writes again.
        var epoch = 0
        /// AppKit fulfils every outstanding promise as the app quits; none may leave a copy behind.
        var declining = false
    }

    private static let state = Mutex(State())

    static var epoch: Int { state.withLock { $0.epoch } }

    static func admits(epoch: Int) -> Bool {
        state.withLock { !$0.declining && $0.epoch == epoch }
    }

    /// Called once the quit is committed, so no reader is left to have asked for a file.
    static func declineCopiesForTermination() {
        state.withLock { $0.declining = true }
        discardPasteboardCopies()
    }

    /// One folder per copy, so each keeps a readable name and goes with its folder.
    static func write(_ data: Data, named name: String = imageName, in root: URL = directory) throws
        -> URL
    {
        // A link planted in place of the root would carry the plaintext to wherever it points.
        if (try? FileManager.default.attributesOfItem(atPath: root.path))?[.type] as? FileAttributeType
            == .typeSymbolicLink
        {
            try FileManager.default.removeItem(at: root)
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        state.withLock { $0.exported = true }
        return url
    }

    /// The general pasteboard's generation once an image is written, which its copies belong to.
    static func belong(toGeneration generation: Int) {
        state.withLock { $0.generation = generation }
    }

    /// Once the clipboard holds anything else, by anyone's write, no paste can need a copy.
    static func discardPasteboardCopies(in root: URL = directory, unlessGeneration current: Int? = nil) {
        let discard = state.withLock { state -> Bool in
            guard current == nil || current != state.generation else { return false }
            let exported = state.exported
            state.exported = false
            state.generation = nil
            state.epoch &+= 1
            return exported
        }
        if discard { try? FileManager.default.removeItem(at: root) }
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// At launch nothing still needs a copy, so every one a dead session left goes.
    static func sweep(in root: URL = directory) {
        try? FileManager.default.removeItem(at: root)
    }
}

/// Supplies a paste's file URL only when an app asks, so most pastes never unseal to disk.
final class ClipboardImageFileProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    private let data: Data
    private let root: URL
    private let generation: Int
    private let epoch: Int
    private let exported = Mutex<URL?>(nil)
    /// The pasteboard holds providers weakly, so each stays here until it reports itself finished.
    private static let live = Mutex<[ObjectIdentifier: ClipboardImageFileProvider]>([:])

    private init(data: Data, root: URL, generation: Int) {
        self.data = data
        self.root = root
        self.generation = generation
        epoch = ClipboardExports.epoch
    }

    /// `generation` is what `clearContents()` returned for the write this item belongs to.
    static func attach(
        _ data: Data, to item: NSPasteboardItem, generation: Int, root: URL = ClipboardExports.directory
    ) {
        let provider = ClipboardImageFileProvider(data: data, root: root, generation: generation)
        live.withLock { $0[ObjectIdentifier(provider)] = provider }
        item.setDataProvider(provider, forTypes: [.fileURL])
    }

    /// Only while its own write is still on the pasteboard and no discard has retired it since.
    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .fileURL, pasteboard?.changeCount == generation,
            ClipboardExports.admits(epoch: epoch)
        else { return }
        let url = exported.withLock { url -> URL? in
            if url.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
                url = try? ClipboardExports.write(data, in: root)
            }
            return url
        }
        if let url { item.setData(url.dataRepresentation, forType: .fileURL) }
    }

    /// Called as the URL is handed over, before the reader opens it, so the copy has to stay.
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        _ = Self.live.withLock { $0.removeValue(forKey: ObjectIdentifier(self)) }
    }
}

/// A drag's file, written straight to wherever it lands; no copy waits in Caches for a drop.
final class ClipboardImageFilePromise: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private let blob: URL
    private let key: SymmetricKey

    private init(blob: URL, key: SymmetricKey) {
        self.blob = blob
        self.key = key
    }

    /// `userInfo` keeps the delegate alive, since the provider only holds it weakly.
    static func provider(for blob: URL, key: SymmetricKey) -> NSFilePromiseProvider {
        let promise = ClipboardImageFilePromise(blob: blob, key: key)
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: promise)
        provider.userInfo = promise
        return provider
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        ClipboardExports.imageName
    }

    func filePromiseProvider(
        _ provider: NSFilePromiseProvider, writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        do {
            try SealedFile.read(blob, key: key).write(to: url, options: .atomic)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    /// Off main: unsealing a large screenshot would stall the drop's animation.
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return queue
    }
}
