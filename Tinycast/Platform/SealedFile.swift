import CryptoKit
import Foundation

/// AES-GCM segments under a caller's key, name authenticated. Layout: docs/features/clipboard.md.
enum SealedFile {
    static let segmentSize = 64 * 1024
    static let fileExtension = "sealed"

    enum Failure: Error, Equatable {
        case unreadable
        case damaged
    }

    private static let magic: [UInt8] = Array("TCSF".utf8)
    private static let version: UInt8 = 1
    /// Random per file, so every file is sealed under a key of its own and nonces never repeat.
    private static let saltSize = 16
    static let headerSize = 5 + 16
    private static let tagSize = 16

    /// Whether `url` starts like a sealed file; says nothing about whether the key opens it.
    static func isSealed(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: magic.count + 1)) ?? Data()
        return Array(head) == magic + [version]
    }

    /// Plaintext length implied by a sealed file's size, without reading or decrypting it.
    static func plaintextSize(ofSealedSize size: Int) -> Int? {
        let body = size - headerSize
        guard body >= tagSize else { return nil }
        let segments = (body + segmentSize + tagSize - 1) / (segmentSize + tagSize)
        let plaintext = body - segments * tagSize
        guard plaintext >= 0, plaintext > (segments - 1) * segmentSize || segments == 1 else {
            return nil
        }
        return plaintext
    }

    static func plaintextSize(of url: URL) -> Int? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return plaintextSize(ofSealedSize: size)
    }

    /// Writes beside `url` and renames over it, so a reader never sees half a file.
    static func write(_ data: Data, to url: URL, key: SymmetricKey) throws {
        var salt = [UInt8](repeating: 0, count: saltSize)
        guard SecRandomCopyBytes(kSecRandomDefault, saltSize, &salt) == errSecSuccess else {
            throw Failure.unreadable
        }
        let header = Data(magic + [version] + salt)
        let fileKey = fileKey(key, salt: salt)
        let staging = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard FileManager.default.createFile(
            atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw Failure.unreadable }
        do {
            let handle = try FileHandle(forWritingTo: staging)
            defer { try? handle.close() }
            try handle.write(contentsOf: header)
            let name = Data(url.lastPathComponent.utf8)
            let count = max(1, (data.count + segmentSize - 1) / segmentSize)
            for index in 0..<count {
                let start = data.startIndex + index * segmentSize
                let end = min(start + segmentSize, data.endIndex)
                let sealed = try AES.GCM.seal(
                    data[start..<end], using: fileKey,
                    nonce: nonce(index: index, final: index == count - 1),
                    authenticating: header + name)
                try handle.write(contentsOf: sealed.ciphertext + sealed.tag)
            }
            try handle.synchronize()
            guard rename(staging.path, url.path) == 0 else { throw Failure.unreadable }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Reads a segment at a time, so only the plaintext, never a second whole copy, is in memory.
    static func read(_ url: URL, key: SymmetricKey) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.unreadable }
        defer { try? handle.close() }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            let plaintextSize = plaintextSize(ofSealedSize: size),
            let header = try handle.read(upToCount: headerSize), header.count == headerSize,
            Array(header.prefix(magic.count + 1)) == magic + [version]
        else { throw Failure.damaged }
        let fileKey = fileKey(key, salt: Array(header.suffix(saltSize)))
        let name = Data(url.lastPathComponent.utf8)
        var plaintext = Data(capacity: plaintextSize)
        var remaining = size - headerSize
        var index = 0
        while remaining > 0 {
            let length = min(remaining, segmentSize + tagSize)
            guard let segment = try handle.read(upToCount: length), segment.count == length else {
                throw Failure.damaged
            }
            remaining -= length
            do {
                let box = try AES.GCM.SealedBox(
                    nonce: nonce(index: index, final: remaining == 0),
                    ciphertext: segment.prefix(length - tagSize), tag: segment.suffix(tagSize))
                plaintext.append(try AES.GCM.open(box, using: fileKey, authenticating: header + name))
            } catch {
                throw Failure.damaged
            }
            index += 1
        }
        return plaintext
    }

    private static func fileKey(_ key: SymmetricKey, salt: [UInt8]) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, salt: Data(salt), info: Data("tinycast.sealed-file.v1".utf8),
            outputByteCount: 32)
    }

    /// Under a key used for this one file, the segment's index and final flag are unique enough.
    private static func nonce(index: Int, final: Bool) throws -> AES.GCM.Nonce {
        let counter = UInt64(index).bigEndian
        let counterBytes = withUnsafeBytes(of: counter, Array.init)
        return try AES.GCM.Nonce(data: [0, 0, 0] + counterBytes + [final ? 1 : 0])
    }
}
