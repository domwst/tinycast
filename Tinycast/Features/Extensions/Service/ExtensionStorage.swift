import Foundation

/// Where an extension's passwords and OAuth tokens live, so its JSON file never holds one.
struct ExtensionSecretVault: Sendable {
    let values: @Sendable (_ extensionName: String) throws -> [String: String]
    let save: @Sendable (_ values: [String: String], _ extensionName: String) throws -> Void
}

/// One JSON file per extension: small, read whole at launch and written rarely.
@MainActor
final class ExtensionStorage {
    private struct Store: Codable {
        var localStorage: [String: StoredValue] = [:]
        var caches: [String: [String: String]] = [:]
        var preferences: [String: StoredValue] = [:]
        /// A search-bar dropdown's `storeValue` pick — host UI state, so not `LocalStorage`.
        var accessoryValues: [String: String] = [:]
        /// Each command's `storeValue` form fields, as the JSON the runtime wrote.
        var formValues: [String: [String: String]] = [:]
        /// Token sets an older build wrote here, kept through rewrites until the migration runs.
        var legacyOAuthTokens: [String: String] = [:]

        enum CodingKeys: String, CodingKey {
            case localStorage, caches, preferences, accessoryValues, formValues
            case legacyOAuthTokens = "oauthTokens"
        }

        init() {}

        /// Each section decodes on its own: one absent key must not take an extension's whole
        /// store — API keys included — down with it, since a failed decode resets the file.
        init(from decoder: Decoder) throws {
            let store = try decoder.container(keyedBy: CodingKeys.self)
            localStorage =
                try store.decodeIfPresent([String: StoredValue].self, forKey: .localStorage) ?? [:]
            caches =
                try store.decodeIfPresent([String: [String: String]].self, forKey: .caches) ?? [:]
            preferences =
                try store.decodeIfPresent([String: StoredValue].self, forKey: .preferences) ?? [:]
            accessoryValues =
                try store.decodeIfPresent([String: String].self, forKey: .accessoryValues) ?? [:]
            formValues =
                try store.decodeIfPresent([String: [String: String]].self, forKey: .formValues) ?? [:]
            legacyOAuthTokens =
                try store.decodeIfPresent([String: String].self, forKey: .legacyOAuthTokens) ?? [:]
        }
    }

    /// `LocalStorage` accepts strings, numbers and booleans and must return them with their type.
    enum StoredValue: Codable, Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)

        var jsonValue: Any {
            switch self {
            case .string(let value): return value
            case .number(let value): return value
            case .bool(let value): return value
            }
        }

        init?(renderValue: RenderValue) {
            switch renderValue {
            case .string(let value): self = .string(value)
            case .number(let value): self = .number(value)
            case .bool(let value): self = .bool(value)
            default: return nil
            }
        }

        init(preference: ExtensionPreferenceValue) {
            switch preference {
            case .string(let value): self = .string(value)
            case .number(let value): self = .number(value)
            case .bool(let value): self = .bool(value)
            case .application(let path): self = .string(path)
            }
        }

        var preferenceValue: ExtensionPreferenceValue {
            switch self {
            case .string(let value): return .string(value)
            case .number(let value): return .number(value)
            case .bool(let value): return .bool(value)
            }
        }
    }

    private let directory: URL
    private let vault: ExtensionSecretVault
    private var stores: [String: Store] = [:]
    /// A failed read caches nothing, so a locked Keychain is asked again, not taken as empty.
    private var secrets: [String: [String: String]] = [:]
    /// Writes are coalesced, so a busy `Cache` doesn't hit the disk per key.
    private var dirty: Set<String> = []
    private var flushTask: Task<Void, Never>?

    init(directory: URL, vault: ExtensionSecretVault) {
        self.directory = directory
        self.vault = vault
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // MARK: - LocalStorage

    func localStorageValue(extension name: String, key: String) -> StoredValue? {
        store(for: name).localStorage[key]
    }

    func allLocalStorage(extension name: String) -> [String: StoredValue] {
        store(for: name).localStorage
    }

    func setLocalStorage(extension name: String, key: String, value: StoredValue) {
        mutate(name) { $0.localStorage[key] = value }
    }

    func removeLocalStorage(extension name: String, key: String) {
        mutate(name) { $0.localStorage.removeValue(forKey: key) }
    }

    func clearLocalStorage(extension name: String) {
        mutate(name) { $0.localStorage.removeAll() }
    }

    // MARK: - Search-bar dropdowns

    func accessoryValue(extension name: String, key: String) -> String? {
        store(for: name).accessoryValues[key]
    }

    func setAccessoryValue(extension name: String, key: String, value: String) {
        mutate(name) { $0.accessoryValues[key] = value }
    }

    // MARK: - Form fields

    func formValues(extension name: String, command: String) -> [String: String] {
        var values = store(for: name).formValues[command] ?? [:]
        let prefix = Self.formKey(command: command, field: "")
        for (key, value) in secretValues(name) ?? [:] where key.hasPrefix(prefix) {
            values[String(key.dropFirst(prefix.count))] = value
        }
        return values
    }

    /// A `secure` field's value goes to the vault; one the vault refuses is not remembered at all.
    func setFormValues(
        extension name: String, command: String, values: [String: String], secure: Set<String> = []
    ) {
        let plain = values.filter { !secure.contains($0.key) }
        mutate(name) { store in
            store.formValues[command, default: [:]].merge(plain) { $1 }
            for field in secure { store.formValues[command]?.removeValue(forKey: field) }
        }
        let secrets = values.filter { secure.contains($0.key) }
        guard !secrets.isEmpty else { return }
        setSecrets(
            Dictionary(uniqueKeysWithValues: secrets.map {
                (Self.formKey(command: command, field: $0.key), $0.value)
            }),
            extension: name)
    }

    /// Values these fields have in the file move to the vault; the file keeps any it refuses.
    func moveFormValuesToVault(extension name: String, command: String, fields: Set<String>) {
        let plain = (store(for: name).formValues[command] ?? [:]).filter { fields.contains($0.key) }
        guard !plain.isEmpty,
            setSecrets(
                Dictionary(uniqueKeysWithValues: plain.map {
                    (Self.formKey(command: command, field: $0.key), $0.value)
                }),
                extension: name)
        else { return }
        mutate(name) { store in plain.keys.forEach { store.formValues[command]?.removeValue(forKey: $0) } }
    }

    private static func formKey(command: String, field: String) -> String {
        "form:\(command):\(field)"
    }

    // MARK: - Cache

    func caches(extension name: String) -> [String: [String: String]] {
        store(for: name).caches
    }

    /// `nil` removes the key; a `nil` key clears the namespace.
    func setCache(extension name: String, namespace: String, key: String?, value: String?) {
        mutate(name) { store in
            guard let key else {
                store.caches[namespace] = [:]
                return
            }
            var bucket = store.caches[namespace] ?? [:]
            if let value { bucket[key] = value } else { bucket.removeValue(forKey: key) }
            store.caches[namespace] = bucket
        }
    }

    func clearCache(extension name: String, namespace: String) {
        mutate(name) { $0.caches[namespace] = [:] }
    }

    // MARK: - OAuth tokens

    func oauthTokens(extension name: String, provider: String) -> String? {
        secretValues(name)?["oauth:" + provider]
    }

    /// `nil` signs the provider out; false when the Keychain refused the write.
    @discardableResult
    func setOAuthTokens(extension name: String, provider: String, tokens: String?) -> Bool {
        setSecret(tokens, for: "oauth:" + provider, extension: name)
    }

    // MARK: - Preferences

    func preference(extension name: String, key: String) -> ExtensionPreferenceValue? {
        store(for: name).preferences[key]?.preferenceValue
    }

    /// A password reads from the Keychain only; one left in the file by an older build is ignored.
    func preference(
        extension name: String, schema: ExtensionPreferenceSchema
    ) -> ExtensionPreferenceValue? {
        guard schema.kind == .password else { return preference(extension: name, key: schema.name) }
        return secretValues(name)?["preference:" + schema.name].map(ExtensionPreferenceValue.string)
    }

    /// False when the Keychain refused a password, which then stays as it was.
    @discardableResult
    func setPreference(
        extension name: String, schema: ExtensionPreferenceSchema, value: ExtensionPreferenceValue?
    ) -> Bool {
        guard schema.kind == .password else {
            setPreference(extension: name, key: schema.name, value: value)
            return true
        }
        guard setSecret(value?.stringValue, for: "preference:" + schema.name, extension: name) else {
            return false
        }
        if store(for: name).preferences[schema.name] != nil {
            setPreference(extension: name, key: schema.name, value: nil)
        }
        return true
    }

    func setPreference(extension name: String, key: String, value: ExtensionPreferenceValue?) {
        mutate(name) { store in
            if let value {
                store.preferences[key] = StoredValue(preference: value)
            } else {
                store.preferences.removeValue(forKey: key)
            }
        }
    }

    /// Manifest defaults overlaid with the user's — what `getPreferenceValues()` sees.
    func resolvedPreferences(
        extension name: String, schemas: [ExtensionPreferenceSchema]
    ) -> [String: ExtensionPreferenceValue] {
        var resolved: [String: ExtensionPreferenceValue] = [:]
        for schema in schemas {
            resolved[schema.name] = schema.runtimeValue(preference(extension: name, schema: schema))
        }
        return resolved
    }

    /// A command with an unset required preference must not run.
    func missingRequiredPreferences(
        extension name: String, schemas: [ExtensionPreferenceSchema]
    ) -> [ExtensionPreferenceSchema] {
        schemas.filter { schema in
            guard schema.required else { return false }
            let value = preference(extension: name, schema: schema) ?? schema.effectiveDefault
            if case .string(let text) = value { return text.isEmpty }
            return false
        }
    }

    func removeAll(extension name: String) {
        stores.removeValue(forKey: name)
        secrets.removeValue(forKey: name)
        try? vault.save([:], name)
        try? FileManager.default.removeItem(at: fileURL(for: name))
    }

    /// What `ExtensionSecretsMigration` still has to move; nothing else reads this section.
    func legacyOAuthTokens(extension name: String) -> [String: String] {
        store(for: name).legacyOAuthTokens
    }

    func dropLegacyOAuthTokens(extension name: String, providers: [String]) {
        guard !providers.isEmpty else { return }
        mutate(name) { store in providers.forEach { store.legacyOAuthTokens.removeValue(forKey: $0) } }
    }

    // MARK: - Secrets

    private func secretValues(_ name: String) -> [String: String]? {
        if let cached = secrets[name] { return cached }
        guard let loaded = try? vault.values(name) else { return nil }
        secrets[name] = loaded
        return loaded
    }

    private func setSecret(_ value: String?, for key: String, extension name: String) -> Bool {
        setSecrets([key: value], extension: name)
    }

    /// One Keychain write for every change, so a form's fields cannot half-land.
    @discardableResult
    private func setSecrets(_ changes: [String: String?], extension name: String) -> Bool {
        guard var current = secretValues(name) else { return false }
        for (key, value) in changes { current[key] = value }
        guard (try? vault.save(current, name)) != nil else { return false }
        secrets[name] = current
        return true
    }

    // MARK: - Persistence

    private func store(for name: String) -> Store {
        if let existing = stores[name] { return existing }
        let loaded =
            (try? Data(contentsOf: fileURL(for: name)))
            .flatMap { try? JSONDecoder().decode(Store.self, from: $0) } ?? Store()
        stores[name] = loaded
        return loaded
    }

    private func mutate(_ name: String, _ body: (inout Store) -> Void) {
        var current = store(for: name)
        body(&current)
        stores[name] = current
        dirty.insert(name)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.flush()
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        let pending = dirty
        dirty.removeAll()
        for name in pending {
            guard let store = stores[name], let data = try? JSONEncoder().encode(store) else { continue }
            try? data.write(to: fileURL(for: name), options: .atomic)
        }
    }

    private func fileURL(for name: String) -> URL {
        directory.appendingPathComponent("\(ExtensionManifest.safeName(name)).json")
    }
}
