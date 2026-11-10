import Foundation

/// Side-by-side apps with their own bundle ids, so a build updates within its own.
enum ReleaseChannel: Sendable {
    case stable
    case beta
    /// A local build. It has no release stream, and never updates itself.
    case development
    /// Installed by a package manager, which owns its updates, so it never replaces itself.
    case packaged

    /// `packagedBy` is the `TinycastPackagedBy` value a package build sets, such as `nix`.
    init(bundleID: String?, packagedBy: String? = nil) {
        if let packagedBy, !packagedBy.isEmpty, bundleID != nil {
            self = .packaged
            return
        }
        switch bundleID {
        case "com.tinycast.app": self = .stable
        case "com.tinycast.app.beta": self = .beta
        default: self = .development
        }
    }

    var updatesItself: Bool { self == .stable || self == .beta }

    /// Beta ships as a GitHub prerelease and stable does not; neither ever sees the other's.
    func accepts(prerelease: Bool) -> Bool {
        switch self {
        case .stable: return !prerelease
        case .beta: return prerelease
        case .development, .packaged: return false
        }
    }
}
