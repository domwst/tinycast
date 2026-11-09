import CryptoKit
import Foundation

/// Seals every clipboard field and blob under keys derived from one root key in the Keychain.
struct ClipboardCipher: Sendable {
    /// Which column a value lives in; bound into the seal, so values can't be moved between them.
    enum Field: String, Sendable {
        case text
        case source
        case imagePath
        case recognizedText
        case canary
    }

    private let textKey: SymmetricKey
    /// Sealed images and their thumbnails, through `SealedFile`.
    let blobKey: SymmetricKey

    init(rootKey: SymmetricKey) {
        textKey = Self.derive(rootKey, purpose: "text")
        blobKey = Self.derive(rootKey, purpose: "blob")
    }

    static func makeRootKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// A random 96-bit nonce per value: far below the 2^32 seals per key GCM can take.
    func seal(_ value: String, field: Field, row: UUID) -> Data? {
        try? AES.GCM.seal(
            Data(value.utf8), using: textKey, authenticating: Self.context(field, row)
        ).combined
    }

    func open(_ sealed: Data, field: Field, row: UUID) -> String? {
        guard let box = try? AES.GCM.SealedBox(combined: sealed),
            let plain = try? AES.GCM.open(box, using: textKey, authenticating: Self.context(field, row))
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    private static func context(_ field: Field, _ row: UUID) -> Data {
        Data("tinycast.clipboard.v2|\(field.rawValue)|\(row.uuidString)".utf8)
    }

    private static func derive(_ root: SymmetricKey, purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: root, info: Data("tinycast.clipboard.\(purpose).v1".utf8),
            outputByteCount: 32)
    }
}
