import CryptoKit
import Foundation

extension ExtensionSecretVault {
    /// One Keychain item per extension, holding every password and token set it owns.
    static let keychain = ExtensionSecretVault(
        values: { try KeychainSecretStore.extensionSecrets.values(for: account(for: $0)) },
        save: { try KeychainSecretStore.extensionSecrets.setValues($0, for: account(for: $1)) })

    /// The Keychain store names an item by UUID, so each extension's comes from its file name.
    private static func account(for name: String) -> UUID {
        let digest = SHA256.hash(data: Data(ExtensionManifest.safeName(name).utf8))
        return digest.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
