import Foundation

/// Moves the passwords and OAuth tokens an older build kept in `extension-data/*.json`.
@MainActor
enum ExtensionSecretsMigration {
    static func run(storage: ExtensionStorage, installed: [InstalledExtension]) {
        for owner in installed {
            let name = owner.manifest.name
            let schemas = owner.manifest.preferences + owner.manifest.commands.flatMap(\.preferences)
            for schema in schemas where schema.kind == .password {
                guard let legacy = storage.preference(extension: name, key: schema.name) else { continue }
                if storage.preference(extension: name, schema: schema) == nil {
                    storage.setPreference(extension: name, schema: schema, value: legacy)
                } else {
                    storage.setPreference(extension: name, key: schema.name, value: nil)
                }
            }
            // A token the Keychain refused stays in the file until a later launch moves it.
            let moved = storage.legacyOAuthTokens(extension: name).compactMap { provider, value in
                storage.oauthTokens(extension: name, provider: provider) != nil
                    || storage.setOAuthTokens(extension: name, provider: provider, tokens: value)
                    ? provider : nil
            }
            storage.dropLegacyOAuthTokens(extension: name, providers: moved)
        }
        storage.flush()
    }

    /// A form's password fields are known only once it renders, so its old values move then.
    static func sealRememberedPasswords(
        storage: ExtensionStorage, command: ExtensionCommandRef, fields: Set<String>
    ) {
        guard !fields.isEmpty else { return }
        storage.moveFormValuesToVault(
            extension: command.extensionName, command: command.commandName, fields: fields)
    }
}
