import AppleArchive
import CryptoKit
import Foundation
import System

enum BackupArchive {
    static let fileExtension = "tinycast"

    /// Typed by a person and guessable offline, so anything shorter is refused before sealing.
    static let minimumPassphraseLength = 8

    enum ArchiveError: LocalizedError, Equatable {
        case cannotWrite
        case cannotRead
        case passphraseRequired
        case passphraseTooShort
        case incorrectPassphrase

        var errorDescription: String? {
            switch self {
            case .cannotWrite: return String(localized: "Couldn't write the backup file.")
            case .cannotRead:
                return String(localized: "This file isn't a Tinycast backup, or it's damaged.")
            case .passphraseRequired:
                return String(localized: "This backup is encrypted. Enter its passphrase.")
            case .passphraseTooShort:
                return String(
                    localized: "Use a passphrase of at least \(minimumPassphraseLength) characters.")
            case .incorrectPassphrase:
                return String(localized: "Incorrect passphrase, or the backup is damaged.")
            }
        }
    }

    /// No `UID`/`GID` to restore a foreign owner, no `IDX` to dangle; `MTM` feeds the note sort.
    private static var keySet: ArchiveHeader.FieldKeySet? {
        ArchiveHeader.FieldKeySet("TYP,PAT,DAT,MOD,MTM")
    }

    /// Apple Encrypted Archive: scrypt-derived key, AES-CTR + HMAC, LZFSE inside the encryption.
    static func seal(directory: URL, into file: URL, passphrase: String) throws {
        let context = try encryptionContext(passphrase: passphrase)
        guard let keySet,
            let destination = ArchiveByteStream.fileStream(
                path: FilePath(file.path), mode: .writeOnly, options: [.create, .truncate],
                permissions: FilePermissions(rawValue: 0o600)),
            let encryptor = ArchiveByteStream.encryptionStream(
                writingTo: destination, encryptionContext: context)
        else { throw ArchiveError.cannotWrite }
        var sealed = false
        defer {
            if !sealed {
                try? encryptor.close()
                try? destination.close()
            }
        }
        try ArchiveStream.withEncodeStream(writingTo: encryptor) { encoder in
            try encoder.writeDirectoryContents(
                archiveFrom: FilePath(directory.path), keySet: keySet)
        }
        // Explicit, not `try?`: the last block flushes in `close`, so a truncated write must throw.
        try encryptor.close()
        try destination.close()
        sealed = true
    }

    /// Reads only the container header, so the pane can ask for a passphrase before opening.
    static func isEncrypted(file: URL) -> Bool {
        guard
            let source = ArchiveByteStream.fileStream(
                path: FilePath(file.path), mode: .readOnly, options: [], permissions: [])
        else { return false }
        defer { try? source.close() }
        return ArchiveEncryptionContext(from: source) != nil
    }

    /// An encrypted file needs `passphrase`; one written before encryption opens without it.
    static func open(file: URL, into directory: URL, passphrase: String?) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let source = fileStream(file) else { throw ArchiveError.cannotRead }
        defer { try? source.close() }
        if let context = ArchiveEncryptionContext(from: source) {
            guard let passphrase, !passphrase.isEmpty else { throw ArchiveError.passphraseRequired }
            try context.setPassword(archivePassword(for: passphrase))
            guard
                let decryptor = ArchiveByteStream.decryptionStream(
                    readingFrom: source, encryptionContext: context)
            else { throw ArchiveError.incorrectPassphrase }
            defer { try? decryptor.close() }
            try extract(from: decryptor, into: directory)
        } else {
            // The header probe consumed bytes, so the unencrypted path reads from a fresh stream.
            guard let plain = fileStream(file),
                let decompressor = ArchiveByteStream.decompressionStream(readingFrom: plain)
            else { throw ArchiveError.cannotRead }
            defer {
                try? decompressor.close()
                try? plain.close()
            }
            try extract(from: decompressor, into: directory)
        }
        guard !containsSymbolicLink(directory) else { throw ArchiveError.cannotRead }
    }

    /// AEA accepts 20–256 bytes; a digest fits any typed passphrase while scrypt still sets the cost.
    static func archivePassword(for passphrase: String) -> String {
        let normalized = Data(passphrase.precomposedStringWithCanonicalMapping.utf8)
        let digest = SHA256.hash(data: Data("tinycast-backup-passphrase-v1:".utf8) + normalized)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func encryptionContext(passphrase: String) throws -> ArchiveEncryptionContext {
        guard passphrase.count >= minimumPassphraseLength else {
            throw ArchiveError.passphraseTooShort
        }
        let context = ArchiveEncryptionContext(
            profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
        do {
            try context.setPassword(archivePassword(for: passphrase))
        } catch {
            throw ArchiveError.cannotWrite
        }
        return context
    }

    private static func fileStream(_ file: URL) -> ArchiveByteStream? {
        ArchiveByteStream.fileStream(
            path: FilePath(file.path), mode: .readOnly, options: [], permissions: [])
    }

    private static func extract(from stream: ArchiveByteStream, into directory: URL) throws {
        guard let decoder = ArchiveStream.decodeStream(readingFrom: stream) else {
            throw ArchiveError.cannotRead
        }
        defer { try? decoder.close() }
        do {
            try ArchiveStream.withExtractStream(
                extractingTo: FilePath(directory.path), selectUsing: containedEntry
            ) { extractor in
                _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor)
            }
        } catch {
            throw ArchiveError.cannotRead
        }
    }

    /// A link entry passes the path filter, and reading through one would leave the extract.
    private static func containsSymbolicLink(_ directory: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey]
        guard
            let entries = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: Array(keys))
        else { return true }
        for case let url as URL in entries
        where (try? url.resourceValues(forKeys: keys))?.isSymbolicLink == true {
            return true
        }
        return false
    }

    /// Skips any entry naming an absolute path or `..`, so a hostile archive cannot escape.
    private static func containedEntry(
        _ message: ArchiveHeader.EntryMessage, _ path: FilePath,
        _ data: ArchiveHeader.EntryFilterData?
    ) -> ArchiveHeader.EntryMessageStatus {
        guard !path.isAbsolute, !path.components.contains(where: { $0.string == ".." }) else {
            return .skip
        }
        return .ok
    }
}
