import Foundation

/// Only `RenderNode.arguments(from:)` reaches for the runtime, and this harness never runs JS.
enum ExtensionRuntime {
    static func jsonArray(from json: String) -> [Any] { [] }
}

enum ExtensionManifest {
    static func safeName(_ name: String) -> String { name }
}

enum ExtensionPreferenceValue: Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case application(String)

    var stringValue: String {
        switch self {
        case .string(let value), .application(let value): value
        case .number(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        }
    }
}

struct ExtensionPreferenceSchema {
    enum Kind { case textfield, password }

    let name: String
    var kind = Kind.textfield
    let required: Bool
    let effectiveDefault: ExtensionPreferenceValue

    var displayTitle: String { name }

    func runtimeValue(_ stored: ExtensionPreferenceValue?) -> ExtensionPreferenceValue? {
        stored ?? effectiveDefault
    }
}

@main
@MainActor
struct ExtensionSearchAccessoryTests {
    static var failures = 0
    static var passes = 0

    static func main() {
        parsing()
        seeding()
        storageIsolation()
        formValueStorage()
        secretStorage()
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    static func node(_ json: String) -> RenderNode {
        let wrapped = """
            {"children":[{"id":1,"type":"__screen","props":{"active":true},"children":[\(json)]}]}
            """
        guard let tree = RenderTree(json: wrapped), let root = tree.activeRoot else {
            fatalError("test tree did not decode")
        }
        return root
    }

    /// The shape the Visual Studio Code extension ships: items inside an untitled section.
    static let listJSON = """
        {"id":2,"type":"List","props":{
            "searchBarAccessory":{"id":9,"type":"List.Dropdown","props":{
                "tooltip":"Filter project types","defaultValue":"All Types","storeValue":true,
                "onChange":{"$fn":"9:onChange"}},"children":[
                {"id":10,"type":"List.Dropdown.Item","props":{
                    "title":"All Types","value":"All Types"},"children":[]},
                {"id":11,"type":"List.Dropdown.Section","props":{},"children":[
                    {"id":12,"type":"List.Dropdown.Item","props":{
                        "title":"Folders","value":"Folders",
                        "icon":{"source":"folder-16"}},"children":[]},
                    {"id":13,"type":"List.Dropdown.Item","props":{
                        "title":"Workspaces","value":"Workspaces"},"children":[]}]}]}},
            "children":[]}
        """

    /// Same dropdown with no props at all: nothing to seed it from but its own first choice.
    static let bareJSON = """
        {"id":2,"type":"List","props":{
            "searchBarAccessory":{"id":9,"type":"List.Dropdown","props":{},"children":[
                {"id":10,"type":"List.Dropdown.Item","props":{
                    "title":"One","value":"one"},"children":[]},
                {"id":11,"type":"List.Dropdown.Item","props":{
                    "title":"Two","value":"two"},"children":[]}]}},
            "children":[]}
        """

    static func parse(_ json: String) -> ExtensionSearchAccessory? {
        ExtensionSearchAccessory(node: node(json).node("searchBarAccessory"))
    }

    static func parsing() {
        guard let accessory = parse(listJSON) else {
            check("a dropdown parses", false)
            return
        }
        check("a dropdown parses", true)
        check("node id kept", accessory.nodeID == 9)
        check("onChange handle kept", accessory.onChange == "9:onChange")
        check("defaultValue kept", accessory.defaultValue == "All Types")
        check(
            "storeValue names a storage key", accessory.storageKey == "searchBarAccessory",
            accessory.storageKey ?? "nil")
        check(
            "items flatten in order, section carried",
            accessory.items.map { "\($0.value)|\($0.section ?? "-")" }
                == ["All Types|-", "Folders|-", "Workspaces|-"],
            accessory.items.map(\.value).joined(separator: ","))
        check("an item's icon survives", accessory.item(for: "Folders")?.iconValue != nil)
        check("a title resolves from a value", accessory.title(for: "Folders") == "Folders")
        check("a value no item claims still reads as itself", accessory.title(for: "x") == "x")
        check("the held choice is the row the list opens on", accessory.index(of: "Workspaces") == 2)
        check("an unheld choice opens on the first row", accessory.index(of: "Gone") == 0)

        check("a List root is not a dropdown", ExtensionSearchAccessory(node: node(listJSON)) == nil)
        let grid = listJSON.replacingOccurrences(of: "List.Dropdown", with: "Grid.Dropdown")
            .replacingOccurrences(of: "\"type\":\"List\"", with: "\"type\":\"Grid\"")
        check("a Grid dropdown parses too", parse(grid)?.items.count == 3)

        guard let bare = parse(bareJSON) else {
            check("a bare dropdown parses", false)
            return
        }
        check("a bare dropdown parses", true)
        check("without storeValue nothing is persisted", bare.storageKey == nil)
        check("without a value the extension controls nothing", bare.controlledValue == nil)

        let controlled = bareJSON.replacingOccurrences(
            of: "\"props\":{}", with: "\"props\":{\"value\":\"two\"}")
        check("a value prop is the extension's own", parse(controlled)?.controlledValue == "two")
    }

    /// Which choice a dropdown lands on before anyone has touched it.
    static func seeding() {
        guard let accessory = parse(listJSON), let bare = parse(bareJSON) else {
            check("the seeding fixtures parse", false)
            return
        }
        check("defaultValue seeds it", accessory.initialValue(stored: nil) == "All Types")
        check(
            "a stored pick wins while it still names an item",
            accessory.initialValue(stored: "Folders") == "Folders")
        check(
            "a stale stored pick falls back to defaultValue",
            accessory.initialValue(stored: "Gone") == "All Types")
        check(
            "with nothing to go on it starts on the first choice",
            bare.initialValue(stored: nil) == "one", bare.initialValue(stored: nil) ?? "nil")
        check(
            "an empty dropdown seeds nothing",
            ExtensionSearchAccessory(
                node: node(
                    """
                    {"id":2,"type":"List","props":{"searchBarAccessory":{
                        "id":9,"type":"List.Dropdown","props":{},"children":[]}},"children":[]}
                    """
                ).node("searchBarAccessory"))?.initialValue(stored: nil) == nil)
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

    static let memory = MemoryVault()
    static var vault: ExtensionSecretVault { memory.vault }

    static func secretStorage() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ext-secrets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let backing = MemoryVault()
        let storage = ExtensionStorage(directory: directory, vault: backing.vault)
        let password = ExtensionPreferenceSchema(
            name: "apiKey", kind: .password, required: true, effectiveDefault: .string(""))
        let marker = "secret-\(UUID().uuidString)"
        storage.setPreference(extension: "sample", schema: password, value: .string(marker))
        storage.setOAuthTokens(extension: "sample", provider: "github", tokens: marker + "-token")
        storage.setLocalStorage(extension: "sample", key: "kept", value: .string("value"))
        storage.flush()
        let file = (try? String(
            contentsOf: directory.appendingPathComponent("sample.json"), encoding: .utf8)) ?? ""
        check("a password and a token never reach the file", !file.isEmpty && !file.contains(marker))
        let reloaded = ExtensionStorage(directory: directory, vault: backing.vault)
        check(
            "a password reads back from the vault",
            reloaded.preference(extension: "sample", schema: password) == .string(marker))
        check(
            "a token set reads back from the vault",
            reloaded.oauthTokens(extension: "sample", provider: "github") == marker + "-token")
        check(
            "a required password counts as set",
            reloaded.missingRequiredPreferences(extension: "sample", schemas: [password]).isEmpty)

        storage.setPreference(extension: "legacy", key: "apiKey", value: .string("plain"))
        check(
            "a password an older build left in the file is never read as one",
            storage.preference(extension: "legacy", schema: password) == nil)

        backing.refuses = true
        let locked = ExtensionStorage(directory: directory, vault: backing.vault)
        check(
            "a refused write reports it",
            !locked.setPreference(extension: "sample", schema: password, value: .string("new")))
        backing.refuses = false
        check(
            "and a locked read was not cached as empty",
            locked.preference(extension: "sample", schema: password) == .string(marker))

        storage.setFormValues(
            extension: "sample", command: "login", values: ["user": "me", "password": marker],
            secure: ["password"])
        storage.flush()
        let withForm = (try? String(
            contentsOf: directory.appendingPathComponent("sample.json"), encoding: .utf8)) ?? ""
        check("a remembered password field never reaches the file", !withForm.contains(marker))
        check(
            "and reads back with the rest of its form",
            ExtensionStorage(directory: directory, vault: backing.vault)
                .formValues(extension: "sample", command: "login") == ["user": "me", "password": marker])

        reloaded.removeAll(extension: "sample")
        check("uninstalling drops the vault item", backing.items["sample"] == nil)
    }

    static func storageIsolation() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ext-accessory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ExtensionStorage(directory: directory, vault: vault)
        storage.setLocalStorage(extension: "sample", key: "filter", value: .string("extension-data"))
        storage.setAccessoryValue(extension: "sample", key: "filter", value: "selected")
        storage.setPreference(
            extension: "sample", key: "editor", value: .application("/Applications/Editor.app"))
        check(
            "a pick never lands in the namespace JavaScript reads",
            storage.localStorageValue(extension: "sample", key: "filter") == .string("extension-data"))
        check(
            "a pick reads back on its own",
            storage.accessoryValue(extension: "sample", key: "filter") == "selected")
        storage.flush()

        let reloaded = ExtensionStorage(directory: directory, vault: vault)
        check(
            "a pick survives a reload",
            reloaded.accessoryValue(extension: "sample", key: "filter") == "selected")
        check(
            "an app picker persists as its path",
            reloaded.preference(extension: "sample", key: "editor")
                == .string("/Applications/Editor.app"))

        // A store written before dropdowns held anything: the missing key must cost nothing.
        storage.setLocalStorage(extension: "older", key: "kept", value: .string("value"))
        storage.setPreference(extension: "older", key: "token", value: .string("secret"))
        storage.flush()
        let file = directory.appendingPathComponent("older.json")
        if var older = (try? Data(contentsOf: file))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        {
            older.removeValue(forKey: "accessoryValues")
            if let data = try? JSONSerialization.data(withJSONObject: older) {
                try? data.write(to: file)
            }
        }
        let older = ExtensionStorage(directory: directory, vault: vault)
        check(
            "a store with no accessory section keeps its localStorage",
            older.localStorageValue(extension: "older", key: "kept") == .string("value"))
        check(
            "a store with no accessory section keeps its preferences",
            older.preference(extension: "older", key: "token") == .string("secret"))
    }

    static func formValueStorage() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-ext-form-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ExtensionStorage(directory: directory, vault: vault)
        storage.setFormValues(extension: "sample", command: "generate", values: ["a": "1", "b": "2"])
        storage.setFormValues(extension: "sample", command: "generate", values: ["b": "3"])
        storage.setFormValues(extension: "sample", command: "other", values: ["a": "9"])
        storage.flush()

        let reloaded = ExtensionStorage(directory: directory, vault: vault)
        check(
            "form values merge per field and survive a reload",
            reloaded.formValues(extension: "sample", command: "generate") == ["a": "1", "b": "3"])
        check(
            "form values are kept per command",
            reloaded.formValues(extension: "sample", command: "other") == ["a": "9"])
        check(
            "form values never land in the namespace JavaScript reads",
            reloaded.allLocalStorage(extension: "sample").isEmpty)
    }

    static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            passes += 1
            print("ok    \(label)")
        } else {
            failures += 1
            print("FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }
}
