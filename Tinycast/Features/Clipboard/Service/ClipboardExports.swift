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

    /// Whether a copy exists, and the pasteboard generation it was made for.
    private static let state = Mutex<(exported: Bool, generation: Int?)>((false, nil))

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
            guard state.exported, current == nil || current != state.generation else { return false }
            state = (false, nil)
            return true
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
    private let exported = Mutex<URL?>(nil)
    /// The pasteboard holds providers weakly, so each stays here until it reports itself finished.
    private static let live = Mutex<[ObjectIdentifier: ClipboardImageFileProvider]>([:])

    private init(data: Data, root: URL) {
        self.data = data
        self.root = root
    }

    static func attach(_ data: Data, to item: NSPasteboardItem, root: URL = ClipboardExports.directory) {
        let provider = ClipboardImageFileProvider(data: data, root: root)
        live.withLock { $0[ObjectIdentifier(provider)] = provider }
        item.setDataProvider(provider, forTypes: [.fileURL])
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .fileURL else { return }
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
