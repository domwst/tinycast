import AppleArchive
import CommonCrypto
import CryptoKit
import Foundation
import System

enum BackupArchive {
    static let fileExtension = "tinycast"

    /// Typed by a person and guessable offline, so anything shorter is refused before sealing.
    static let minimumPassphraseLength = 10
    /// PBKDF2 rounds ahead of AEA's own scrypt, which on its own costs a guess about 35 ms.
    static let stretchRounds: UInt32 = 600_000
    /// A file's own claim, bounded, so a hostile one can neither weaken nor stall the derivation.
    private static let acceptedRounds: ClosedRange<UInt32> = 100_000...10_000_000
    private static let stretchMagic = Array("TCBK".utf8) + [1]
    private static let maximumEntries = 2_000_000
    private static let maximumBytes: Int64 = 64 << 30
    /// A manifest is a few kilobytes; previewing one never needs more.
    private static let maximumPreviewBytes: Int64 = 4 << 20
    /// Blobs a backup never writes, which extraction would restore outside the byte budget.
    private static let refusedBlobKeys = ["XAT", "ACL"]

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
    /// Written beside the destination and renamed over it, so a failed export keeps the old file.
    static func seal(directory: URL, into file: URL, passphrase: String) throws {
        let partial = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try sealArchive(directory: directory, into: partial, passphrase: passphrase)
            guard Darwin.rename(partial.path, file.path) == 0 else { throw ArchiveError.cannotWrite }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    private static func sealArchive(directory: URL, into file: URL, passphrase: String) throws {
        let context = try encryptionContext(passphrase: passphrase, rounds: stretchRounds)
        guard let keySet,
            let destination = ArchiveByteStream.fileStream(
                path: FilePath(file.path), mode: .writeOnly, options: [.create, .exclusiveCreate],
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
    /// `only` names the entries to extract, so a preview never unpacks the history it describes.
    static func open(
        file: URL, into directory: URL, passphrase: String?, only: Set<String>? = nil
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let source = fileStream(file) else { throw ArchiveError.cannotRead }
        defer { try? source.close() }
        if let context = ArchiveEncryptionContext(from: source) {
            guard let passphrase, !passphrase.isEmpty else { throw ArchiveError.passphraseRequired }
            guard let stretch = context.authData.flatMap(parseStretch) else {
                throw ArchiveError.cannotRead
            }
            try context.setPassword(
                archivePassword(for: passphrase, salt: stretch.salt, rounds: stretch.rounds))
            guard
                let decryptor = ArchiveByteStream.decryptionStream(
                    readingFrom: source, encryptionContext: context)
            else { throw ArchiveError.incorrectPassphrase }
            defer { try? decryptor.close() }
            try extract(from: decryptor, into: directory, only: only)
        } else {
            // The header probe consumed bytes, so the unencrypted path reads from a fresh stream.
            guard let plain = fileStream(file),
                let decompressor = ArchiveByteStream.decompressionStream(readingFrom: plain)
            else { throw ArchiveError.cannotRead }
            defer {
                try? decompressor.close()
                try? plain.close()
            }
            try extract(from: decompressor, into: directory, only: only)
        }
        guard !containsSymbolicLink(directory) else { throw ArchiveError.cannotRead }
    }

    /// Hex PBKDF2 of the NFC passphrase: any length fits AEA's 20–256 bytes; guesses cost more.
    static func archivePassword(for passphrase: String, salt: [UInt8], rounds: UInt32) -> String {
        let normalized = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        let saltBytes = Array("tinycast-backup-passphrase-v1:".utf8) + salt
        var derived = [UInt8](repeating: 0, count: 32)
        let status = normalized.withUnsafeBufferPointer { password in
            password.withMemoryRebound(to: CChar.self) { password in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password.baseAddress, password.count, saltBytes,
                    saltBytes.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived,
                    derived.count)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 refused its own fixed parameters")
        return derived.map { String(format: "%02x", $0) }.joined()
    }

    /// The salt and rounds ride in AEA's authenticated header, readable before the passphrase is.
    static func encryptionContext(
        passphrase: String, rounds: UInt32
    ) throws -> ArchiveEncryptionContext {
        guard passphrase.count >= minimumPassphraseLength else {
            throw ArchiveError.passphraseTooShort
        }
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw ArchiveError.cannotWrite
        }
        let context = ArchiveEncryptionContext(
            profile: .hkdf_sha256_aesctr_hmac__scrypt__none, compressionAlgorithm: .lzfse)
        do {
            context.authData = Data(stretchMagic + withUnsafeBytes(of: rounds.bigEndian, Array.init) + salt)
            try context.setPassword(archivePassword(for: passphrase, salt: salt, rounds: rounds))
        } catch {
            throw ArchiveError.cannotWrite
        }
        return context
    }

    private static func parseStretch(_ data: Data) -> (salt: [UInt8], rounds: UInt32)? {
        let bytes = Array(data)
        guard bytes.count == stretchMagic.count + 4 + 16, Array(bytes.prefix(stretchMagic.count)) == stretchMagic
        else { return nil }
        let rounds = bytes[stretchMagic.count..<stretchMagic.count + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard acceptedRounds.contains(rounds) else { return nil }
        return (Array(bytes.suffix(16)), rounds)
    }

    private static func fileStream(_ file: URL) -> ArchiveByteStream? {
        ArchiveByteStream.fileStream(
            path: FilePath(file.path), mode: .readOnly, options: [], permissions: [])
    }

    private static func extract(
        from stream: ArchiveByteStream, into directory: URL, only: Set<String>?
    ) throws {
        guard let decoder = ArchiveStream.decodeStream(readingFrom: stream) else {
            throw ArchiveError.cannotRead
        }
        defer { try? decoder.close() }
        let free =
            (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let cap = only == nil ? maximumBytes : maximumPreviewBytes
        let budget = ExtractionBudget(bytes: max(0, min(cap, free - (1 << 30))))
        do {
            try ArchiveStream.withExtractStream(
                extractingTo: FilePath(directory.path),
                selectUsing: { budget.admit($0, $1, $2, only: only) }
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

    /// Counts as entries are extracted, so a hostile archive can neither fill the disk nor hang it.
    private final class ExtractionBudget {
        private var entries = 0
        private var bytes: Int64

        init(bytes: Int64) {
            self.bytes = bytes
        }

        /// Only files and folders, inside the destination: a FIFO would block extraction forever.
        func admit(
            _ message: ArchiveHeader.EntryMessage, _ path: FilePath,
            _ data: ArchiveHeader.EntryFilterData?, only: Set<String>?
        ) -> ArchiveHeader.EntryMessageStatus {
            guard !path.isAbsolute, !path.components.contains(where: { $0.string == ".." }) else {
                return .skip
            }
            guard message == .extractBegin else { return .ok }
            guard case .header(let header) = data,
                case .uint(_, let type) = header.field(forKey: ArchiveHeader.FieldKey("TYP")),
                type == UInt64(ArchiveHeader.EntryType.regularFile.rawValue)
                    || type == UInt64(ArchiveHeader.EntryType.directory.rawValue)
            else { return .cancel }
            // A resource fork or ACL rides in its own blob, uncounted, so the entry is refused.
            guard
                BackupArchive.refusedBlobKeys.allSatisfy({
                    header.field(forKey: ArchiveHeader.FieldKey($0)) == nil
                })
            else { return .cancel }
            if let only, !path.isEmpty, !only.contains(path.string) { return .skip }
            entries += 1
            if case .blob(_, let size, _) = header.field(forKey: ArchiveHeader.FieldKey("DAT")) {
                bytes -= Int64(clamping: size)
            }
            return entries <= BackupArchive.maximumEntries && bytes >= 0 ? .ok : .cancel
        }
    }
}
