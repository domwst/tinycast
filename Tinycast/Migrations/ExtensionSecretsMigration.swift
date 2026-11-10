import Foundation

/// Moves the passwords and OAuth tokens an older build kept in `extension-data/*.json`.
@MainActor
enum ExtensionSecretsMigration {
    static func run(storage: ExtensionStorage, installed: [InstalledExtension], directory: URL) {
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
            let file = directory.appendingPathComponent("\(ExtensionManifest.safeName(name)).json")
            let tokens = legacyTokens(in: file)
            guard !tokens.isEmpty else { continue }
            for (provider, value) in tokens
            where storage.oauthTokens(extension: name, provider: provider) == nil {
                storage.setOAuthTokens(extension: name, provider: provider, tokens: value)
            }
            // A token the Keychain refused stays in the file until a later launch moves it.
            let kept = tokens.keys.allSatisfy {
                storage.oauthTokens(extension: name, provider: $0) != nil
            }
            if kept { storage.rewrite(extension: name) }
        }
        storage.flush()
    }

    private static func legacyTokens(in file: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: file),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json["oauthTokens"] as? [String: String] ?? [:]
    }
}
