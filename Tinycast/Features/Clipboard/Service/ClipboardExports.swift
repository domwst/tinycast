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

    /// Set by a write, so a poll with nothing exported never touches the disk.
    private static let exported = Mutex(false)

    /// One folder per copy, so each keeps a readable name and goes with its folder.
    static func write(_ data: Data, named name: String = imageName, in root: URL = directory) throws
        -> URL
    {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(name)
        guard FileManager.default.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        exported.withLock { $0 = true }
        return url
    }

    /// Once the clipboard holds something else, no paste can still need a copy made for it.
    static func discardPasteboardCopies(in root: URL = directory) {
        guard exported.withLock({ flag in defer { flag = false }; return flag }) else { return }
        try? FileManager.default.removeItem(at: root)
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
