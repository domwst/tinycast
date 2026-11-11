import Foundation
import Observation

/// Mirrors the stores bound to it into settings.json, and applies the file's edits back to them.
@MainActor
final class SettingsFileRepository {
    var onIssues: (([SettingsFileIssue]) -> Void)?

    private let fileURL: URL
    private let bindings: [SettingsFileBinding]
    /// Runs once every binding has written, for a change that spans keys.
    private let commit: () -> [SettingsFileIssue]
    private let monitor: SettingsFileMonitor
    /// The bytes last read or written, so the monitor's echo of a save is not taken for an edit.
    private var lastSeen: Data?
    /// The render the stores and the file last agreed on; a save writes only past it.
    private var baseline: Data?
    private var saveTask: Task<Void, Never>?

    private static let saveDelay = Duration.milliseconds(300)

    init(
        fileURL: URL, bindings: [SettingsFileBinding],
        commit: @escaping () -> [SettingsFileIssue] = { [] }
    ) {
        self.fileURL = fileURL
        self.bindings = bindings
        self.commit = commit
        monitor = SettingsFileMonitor(fileURL: fileURL)
    }

    isolated deinit {
        saveTask?.cancel()
    }

    /// Follows both sides from here on; `importing` applies the file first, else it is replaced.
    func start(importing: Bool) {
        tightenPermissions()
        if importing, FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try? Data(contentsOf: fileURL)
            lastSeen = data
            let issues = data.map { apply($0) } ?? [.unreadable]
            baseline = renderObserved()
            report(issues)
        } else {
            save()
        }
        monitor.onChange = { [weak self] in self?.reload() }
        monitor.start()
    }

    /// Writes a pending save now, for a quit or a stop that cannot wait out the delay.
    func flush() {
        guard let saveTask else { return }
        saveTask.cancel()
        save()
    }

    // MARK: - Reading

    private func reload() {
        // Missing mid-save is normal: the rename that completes it fires an event of its own.
        guard let data = try? Data(contentsOf: fileURL), data != lastSeen else { return }
        lastSeen = data
        let issues = apply(data)
        baseline = render()
        report(issues)
    }

    private func apply(_ data: Data) -> [SettingsFileIssue] {
        do {
            let parsed = try SettingsFileFormat.parse(data)
            return parsed.issues + apply(parsed.values)
        } catch {
            return [error]
        }
    }

    /// A key the file leaves out, or spells wrong, keeps its current value.
    private func apply(_ values: [SettingsFileKey: SettingsFileJSON]) -> [SettingsFileIssue] {
        bindings.flatMap { binding in
            values[binding.key].map(binding.write) ?? []
        } + commit()
    }

    // MARK: - Writing

    private func render() -> Data {
        SettingsFileFormat.render(
            Dictionary(uniqueKeysWithValues: bindings.map { ($0.key, $0.read()) }))
    }

    /// Renders with every bound value tracked, so the next change anywhere schedules a save.
    private func renderObserved() -> Data {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleSave() }
        }
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.saveDelay)
            } catch {
                return
            }
            self?.save()
        }
    }

    private func save() {
        saveTask = nil
        let data = renderObserved()
        guard data != baseline else { return }
        if !write(data) { report([.unwritable]) }
    }

    /// Atomic, and into a symlink's target, so a link into a dotfiles repository stays a link.
    private func write(_ data: Data) -> Bool {
        let target = fileURL.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        let partial = folder.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Born 0600, never chmodded after: a home folder is readable by every other account.
            let descriptor = open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { return false }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.close()
            guard rename(partial.path, target.path) == 0 else {
                try? FileManager.default.removeItem(at: partial)
                return false
            }
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        lastSeen = data
        baseline = data
        return true
    }

    /// A file and folder an older build made at 0644 and 0755; a folder that's a link isn't ours.
    private func tightenPermissions() {
        let folder = fileURL.deletingLastPathComponent()
        let attributes = try? FileManager.default.attributesOfItem(atPath: folder.path)
        if attributes?[.type] as? FileAttributeType == .typeDirectory { Self.revokeOthers(at: folder) }
        Self.revokeOthers(at: fileURL.resolvingSymlinksInPath())
    }

    /// Group and other bits only: the owner's own choice, even an unreadable 000, stays.
    private static func revokeOthers(at url: URL) {
        let manager = FileManager.default
        guard let mode = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int,
            mode & 0o077 != 0
        else { return }
        try? manager.setAttributes([.posixPermissions: mode & ~0o077], ofItemAtPath: url.path)
    }

    private func report(_ issues: [SettingsFileIssue]) {
        guard !issues.isEmpty else { return }
        onIssues?(issues)
    }
}
