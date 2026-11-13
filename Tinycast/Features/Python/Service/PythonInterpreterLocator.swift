import Foundation
import Synchronization

/// Which `python3` a session runs, and the `PATH` its subprocesses should see.
struct PythonInterpreter: Sendable, Equatable {
    let path: String
    /// The login shell's `PATH`; nil keeps Tinycast's own, which launchd keeps minimal.
    let searchPath: String?
}

/// Finds the interpreter: the configured path, else the login shell's `python3`, else a known one.
enum PythonInterpreterLocator {
    enum Failure: Error, Sendable, Equatable {
        case notExecutable(String)
        case notFound

        var message: String {
            switch self {
            case .notExecutable(let path):
                return String(localized: "The Python interpreter at “\(path)” can't be run.")
            case .notFound:
                return String(localized: "Tinycast couldn't find python3. Set its path in Settings.")
            }
        }
    }

    @concurrent
    static func resolve(configured: String) async -> Result<PythonInterpreter, Failure> {
        let shell = await loginShellLookup()
        let configured = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            let path = (configured as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: path) else {
                return .failure(.notExecutable(configured))
            }
            return .success(PythonInterpreter(path: path, searchPath: shell.searchPath))
        }
        if let found = shell.python, FileManager.default.isExecutableFile(atPath: found) {
            return .success(PythonInterpreter(path: found, searchPath: shell.searchPath))
        }
        guard let fallback = fallbacks().first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return .failure(.notFound)
        }
        return .success(PythonInterpreter(path: fallback, searchPath: shell.searchPath))
    }

    /// `/usr/bin/python3` only with developer tools: without them it asks to install them instead.
    private static func fallbacks() -> [String] {
        var paths = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        if let developer = developerDirectory(),
            FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/python3")
        {
            paths.append("/usr/bin/python3")
        }
        return paths
    }

    private static func developerDirectory() -> String? {
        let output = run("/usr/bin/xcode-select", ["-p"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == false ? output : nil
    }

    /// The same login, interactive zsh Load Shell Environment uses, so `.zshrc`'s PATH counts.
    private static func loginShellLookup() async -> (python: String?, searchPath: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Separators a shell config can't plausibly print, so its chatter is cut away.
                let script = #"printf '\036%s\036%s\036' "$(command -v python3)" "$PATH""#
                let output = run("/bin/zsh", ["-ilc", script], environment: ["TINYCAST": "1"])
                let fields = output?.components(separatedBy: "\u{1E}") ?? []
                guard fields.count >= 4 else { return continuation.resume(returning: (nil, nil)) }
                let python = fields[fields.count - 3]
                let searchPath = fields[fields.count - 2]
                continuation.resume(
                    returning: (python.isEmpty ? nil : python, searchPath.isEmpty ? nil : searchPath))
            }
        }
    }

    /// A slow or hung shell config gets this long before the lookup gives up on it.
    private static let lookupTimeout: DispatchTimeInterval = .seconds(5)

    private static func run(
        _ executable: String, _ arguments: [String], environment: [String: String] = [:]
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        let output = Foundation.Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard let exit = try? process.runObservingExit() else { return nil }
        let processID = process.processIdentifier
        let finished = Mutex(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + lookupTimeout) {
            finished.withLock { done in
                if !done { kill(processID, SIGTERM) }
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        exit.wait()
        finished.withLock { $0 = true }
        guard process.terminationStatus == 0 else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
