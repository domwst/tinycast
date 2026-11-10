import Foundation

/// Only `RenderNode.arguments(from:)` reaches for the runtime, and this harness never runs JS.
enum ExtensionRuntime {
    static func jsonArray(from json: String) -> [Any] { [] }
}

@main
@MainActor
struct ExtensionSecretsMigrationTests {
    static var failures = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failures += 1
            print("FAIL: \(message)")
        } else {
            print("PASS  \(message)")
        }
    }

    /// Keychain-shaped but in memory: no harness touches the real Keychain.
    final class MemoryVault: @unchecked Sendable {
        var items: [String: [String: String]] = [:]
        var refuses = false

        var vault: ExtensionSecretVault {
            ExtensionSecretVault(
                values: { [unowned self] name in
                    if refuses { throw CocoaError(.fileReadNoPermission) }
                    return items[name] ?? [:]
                },
                save: { [unowned self] values, name in
                    if refuses { throw CocoaError(.fileWriteNoPermission) }
                    items[name] = values.isEmpty ? nil : values
                })
        }
    }

    static func installed(_ name: String, in base: URL) -> InstalledExtension? {
        let manifest: [String: Any] = [
            "name": name,
            "preferences": [["name": "apiKey", "type": "password", "title": "Key"]],
            "commands": [
                [
                    "name": "main", "title": "Main",
                    "preferences": [["name": "pin", "type": "password", "title": "PIN"]]
                ]
            ]
        ]
        guard let parsed = ExtensionManifest(json: manifest) else { return nil }
        return InstalledExtension(manifest: parsed, directory: base.appendingPathComponent(name))
    }

    /// The file an older build wrote: both passwords and a token set in plain JSON.
    static func writeLegacy(_ name: String, in data: URL, key: String, pin: String, token: String) {
        let older = ExtensionStorage(directory: data, vault: MemoryVault().vault)
        older.setPreference(extension: name, key: "apiKey", value: .string(key))
        older.setPreference(extension: name, key: "pin", value: .string(pin))
        older.setPreference(extension: name, key: "theme", value: .string("dark"))
        older.flush()
        let file = data.appendingPathComponent("\(name).json")
        guard let raw = try? Data(contentsOf: file),
            var json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return }
        json["oauthTokens"] = ["github": token]
        try? JSONSerialization.data(withJSONObject: json).write(to: file)
    }

    static func fileText(_ name: String, in data: URL) -> String {
        (try? String(contentsOf: data.appendingPathComponent("\(name).json"), encoding: .utf8)) ?? ""
    }

    static func main() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ext-secrets-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let data = base.appendingPathComponent("data", isDirectory: true)
        guard let owner = installed("sample", in: base) else {
            expect(false, "the fixture manifest parses")
            exit(1)
        }
        let marker = UUID().uuidString
        writeLegacy("sample", in: data, key: "key-\(marker)", pin: "pin-\(marker)", token: "tok-\(marker)")

        let memory = MemoryVault()
        let storage = ExtensionStorage(directory: data, vault: memory.vault)
        ExtensionSecretsMigration.run(storage: storage, installed: [owner], directory: data)
        expect(memory.items["sample"]?["preference:apiKey"] == "key-\(marker)", "an extension password moves")
        expect(memory.items["sample"]?["preference:pin"] == "pin-\(marker)", "a command password moves")
        expect(memory.items["sample"]?["oauth:github"] == "tok-\(marker)", "a token set moves")
        let text = fileText("sample", in: data)
        expect(!text.isEmpty && !text.contains(marker), "nothing secret is left in the file")
        expect(
            storage.preference(extension: "sample", key: "theme") == .string("dark"),
            "an ordinary preference stays where it was")

        let again = ExtensionStorage(directory: data, vault: memory.vault)
        let before = memory.items
        ExtensionSecretsMigration.run(storage: again, installed: [owner], directory: data)
        expect(memory.items == before, "a second run changes nothing")

        guard let locked = installed("locked", in: base) else { exit(1) }
        writeLegacy("locked", in: data, key: "key-\(marker)", pin: "pin-\(marker)", token: "tok-\(marker)")
        let refusing = MemoryVault()
        refusing.refuses = true
        let blocked = ExtensionStorage(directory: data, vault: refusing.vault)
        ExtensionSecretsMigration.run(storage: blocked, installed: [locked], directory: data)
        let kept = fileText("locked", in: data)
        expect(
            kept.contains("key-\(marker)") && kept.contains("tok-\(marker)"),
            "a refused Keychain loses nothing: the file keeps it for a later launch")
        refusing.refuses = false
        let retried = ExtensionStorage(directory: data, vault: refusing.vault)
        ExtensionSecretsMigration.run(storage: retried, installed: [locked], directory: data)
        expect(
            refusing.items["locked"]?["oauth:github"] == "tok-\(marker)"
                && !fileText("locked", in: data).contains(marker),
            "and the next launch finishes the move")

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
