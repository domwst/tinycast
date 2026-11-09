import Foundation

/// One run's scratch tree, in Caches so PNGs hardlink and a crashed run's orphan ages out.
struct BackupStaging: Sendable {
    let root: URL

    init(base: URL = AppPaths.caches()) throws {
        let container = Self.container(in: base)
        // A link planted in place of the folder would put plaintext, and sweeps, wherever it points.
        if (try? FileManager.default.attributesOfItem(atPath: container.path))?[.type]
            as? FileAttributeType == .typeSymbolicLink
        {
            try FileManager.default.removeItem(at: container)
        }
        Self.sweep(container, before: Date().addingTimeInterval(-86_400))
        root = container.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Called at launch with the launch time: every older tree is a dead run's plaintext.
    static func sweepOrphans(before cutoff: Date, base: URL = AppPaths.caches()) {
        sweep(container(in: base), before: cutoff)
    }

    private static func container(in base: URL) -> URL {
        base.appendingPathComponent("backup-staging", isDirectory: true)
    }

    /// A run killed mid-flight leaves its tree behind, and nothing else ever reclaims it.
    private static func sweep(_ container: URL, before cutoff: Date) {
        guard (try? FileManager.default.attributesOfItem(atPath: container.path))?[.type]
            as? FileAttributeType == .typeDirectory
        else { return }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let orphans =
            (try? FileManager.default.contentsOfDirectory(
                at: container, includingPropertiesForKeys: Array(keys))) ?? []
        for url in orphans {
            let modified = (try? url.resourceValues(forKeys: keys))?.contentModificationDate
            if modified ?? .distantPast < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    var bundle: BackupBundle { BackupBundle(root: root) }

    func discard() {
        try? FileManager.default.removeItem(at: root)
    }
}
