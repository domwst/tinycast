import CryptoKit
import Foundation

/// The clipboard's root key, in the login Keychain under this channel's bundle ID.
nonisolated enum ClipboardKeyStore {
    enum Failure: LocalizedError {
        case locked

        var errorDescription: String? {
            String(localized: "Clipboard history is locked: its key couldn't be read from the Keychain.")
        }
    }

    enum Unlock: Sendable {
        case ready(ClipboardCipher)
        /// The Keychain answered with an error, not "no such item": the store stays shut.
        case unavailable
    }

    private enum Lookup {
        case found(SymmetricKey)
        case missing
        case unavailable
    }

    private static let keychain = KeychainSecretStore(scope: "clipboard-key")
    /// One key per channel, so the account never varies.
    private static let account = UUID(uuidString: "6C1B7D52-0D5E-4F2A-9C61-2F1D4C3B8A90")!

    /// Blocking: a Keychain read can wait on a system prompt, so this never runs on main.
    static func unlock(database: URL, images: URL) -> Unlock {
        let key: SymmetricKey
        switch lookup() {
        case .found(let found):
            key = found
        case .unavailable:
            return .unavailable
        case .missing:
            key = ClipboardCipher.makeRootKey()
            // Saved before anything is sealed with it, so no clip can outlive its key.
            guard save(key) else { return .unavailable }
            discardSealedHistory(database: database, images: images)
        }
        let cipher = ClipboardCipher(rootKey: key)
        ClipboardEncryptionMigration.run(database: database, images: images, cipher: cipher)
        return .ready(cipher)
    }

    private static func lookup() -> Lookup {
        do {
            guard let encoded = try keychain.secret(for: account) else { return .missing }
            // A garbled item can't open anything sealed under the real key, so it counts as lost.
            guard let data = Data(base64Encoded: encoded), data.count == 32 else { return .missing }
            return .found(SymmetricKey(data: data))
        } catch KeychainSecretStore.StoreError.invalidEncoding {
            return .missing
        } catch {
            return .unavailable
        }
    }

    private static func save(_ key: SymmetricKey) -> Bool {
        let encoded = key.withUnsafeBytes { Data($0).base64EncodedString() }
        return (try? keychain.setSecret(encoded, for: account)) != nil
    }

    /// A history sealed under a key that is gone can never open again, so it goes with the key.
    private static func discardSealedHistory(database: URL, images: URL) {
        guard ClipboardEncryptionMigration.isSealedStore(database) else { return }
        ClipboardStore.removeDatabase(at: database)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []
        for name in entries where name.hasSuffix("." + SealedFile.fileExtension) {
            try? FileManager.default.removeItem(at: images.appendingPathComponent(name))
        }
        try? FileManager.default.removeItem(
            at: images.appending(path: ".thumbnails", directoryHint: .isDirectory))
    }
}
