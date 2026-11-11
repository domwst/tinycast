import Foundation
import os

struct UpdateInstaller: Sendable {
    enum Phase: Sendable, Equatable {
        case downloading(received: Int64, expected: Int64)
        case extracting
        case verifying

        var message: String {
            switch self {
            case .downloading: return String(localized: "Downloading…")
            case .extracting: return String(localized: "Expanding…")
            case .verifying: return String(localized: "Verifying…")
            }
        }

        /// Only the download knows how far along it is; the rest are short, opaque steps.
        var fraction: Double? {
            guard case .downloading(let received, let expected) = self, expected > 0 else {
                return nil
            }
            return min(1, Double(received) / Double(expected))
        }
    }

    struct Staged: Sendable {
        let app: URL
        let requirement: String
        let codeHash: Data
        /// The copy running now, so a rollback restores it and never something put in its place.
        let runningHash: Data
    }

    let bundleURL: URL
    let stagingDirectory: URL

    private static let logger = Logger(subsystem: "com.tinycast", category: "Updates")

    /// Everything short of the swap, which waits for quit so no old code runs on new files.
    func prepare(
        _ release: AvailableRelease, onProgress: @escaping @Sendable (Phase) -> Void
    ) async throws -> Staged {
        let location = bundleURL.deletingLastPathComponent()
        // The swap runs at quit, too late to report anything, so an unwritable copy is caught now.
        guard FileManager.default.isWritableFile(atPath: location.path),
            FileManager.default.isWritableFile(atPath: bundleURL.path)
        else { throw UpdateFailure.replaceFailed(location.path) }
        guard let requirement = BundleSignature.runningRequirement(),
            let runningHash = BundleSignature.trustedHash(of: bundleURL, requirement: requirement)
        else { throw UpdateFailure.identityMismatch }
        try? FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)
        let archive = stagingDirectory.appendingPathComponent("\(release.tag).zip")
        // A fresh name, created by `expand`: a folder planted in advance is never the one used.
        let expanded = stagingDirectory.appendingPathComponent(
            "expanded-\(UUID().uuidString)", isDirectory: true)

        onProgress(.downloading(received: 0, expected: release.assetSize))
        for try await event in UpdateDownloader.download(release, to: archive) {
            guard case .progress(let received, let expected) = event else { continue }
            onProgress(.downloading(received: received, expected: expected))
        }

        guard try await signatureHolds(archive, by: release.signatureURL) else {
            try? FileManager.default.removeItem(at: archive)
            throw UpdateFailure.signatureInvalid
        }

        onProgress(.extracting)
        let staged: URL
        do {
            staged = try await expand(archive, into: expanded)
        } catch {
            try? FileManager.default.removeItem(at: expanded)
            try? FileManager.default.removeItem(at: archive)
            throw error
        }
        try? FileManager.default.removeItem(at: archive)

        onProgress(.verifying)
        do {
            let codeHash = try verify(staged, is: release, requirement: requirement)
            try Task.checkCancellation()
            return Staged(
                app: staged, requirement: requirement, codeHash: codeHash, runningHash: runningHash)
        } catch {
            try? FileManager.default.removeItem(at: expanded)
            throw error
        }
    }

    /// Anything can write to Caches before quit, so only the exact bytes verified may land.
    func install(_ staged: Staged) throws {
        defer { try? FileManager.default.removeItem(at: staged.app.deletingLastPathComponent()) }
        // Another install may have replaced the app since launch; never roll that back.
        guard Self.info(at: bundleURL)?["CFBundleShortVersionString"] as? String == runningVersion else {
            throw UpdateFailure.replaceFailed(bundleURL.path)
        }
        let codeHash = BundleSignature.trustedHash(of: staged.app, requirement: staged.requirement)
        guard codeHash == staged.codeHash else { throw UpdateFailure.replaceFailed(staged.app.path) }
        let backupName = ".\(bundleURL.lastPathComponent).previous"
        let backup = bundleURL.deletingLastPathComponent().appendingPathComponent(backupName)
        let installed: URL
        do {
            installed =
                try FileManager.default.replaceItemAt(
                    bundleURL, withItemAt: staged.app, backupItemName: backupName,
                    options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]) ?? bundleURL
        } catch {
            throw UpdateFailure.replaceFailed(error.localizedDescription)
        }
        // The swap renames by path, so what landed is checked again; a mismatch puts the old back.
        guard BundleSignature.trustedHash(of: installed, requirement: staged.requirement)
            == staged.codeHash
        else {
            rollBack(installed, to: backup, expecting: staged)
            throw UpdateFailure.replaceFailed(bundleURL.path)
        }
        try? FileManager.default.removeItem(at: backup)
    }

    /// The old copy goes back only if it is still the one that ran; else nothing unverified stays.
    private func rollBack(_ installed: URL, to backup: URL, expecting staged: Staged) {
        let fileManager = FileManager.default
        if BundleSignature.trustedHash(of: backup, requirement: staged.requirement) == staged.runningHash {
            // A nil URL is still a completed swap; only a thrown error means it didn't go back.
            do {
                _ = try fileManager.replaceItemAt(installed, withItemAt: backup, options: .usingNewMetadataOnly)
                return
            } catch {}
        }
        try? fileManager.trashItem(at: installed, resultingItemURL: nil)
        try? fileManager.removeItem(at: backup)
    }

    private var runningVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Nothing is expanded unless the release key signed it: a zip can be built to fill the disk.
    private func signatureHolds(_ archive: URL, by signatureURL: URL?) async throws -> Bool {
        guard let signatureURL else { return false }
        let signature: Data
        do {
            signature = try await UpdateDownloader.data(from: signatureURL)
        } catch {
            try Task.checkCancellation()
            Self.logger.error(
                "Fetching the update signature failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return UpdateSignature.isSigned(archive, by: signature)
    }

    private func expand(_ archive: URL, into directory: URL) async throws -> URL {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw UpdateFailure.extractFailed(error.localizedDescription)
        }
        // `ditto` ships with macOS, keeps the bundle's seal intact, and Foundation has no unzip.
        let result = try await ToolRunner.run(
            URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, directory.path])
        guard result.succeeded else { throw UpdateFailure.extractFailed(result.tail) }
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        // Exactly one bundle, named for its channel: anything beside it was not in the archive.
        guard contents.count == 1, let app = contents.first, app.pathExtension == "app" else {
            throw UpdateFailure.noAppInArchive
        }
        return app
    }

    private func verify(
        _ staged: URL, is release: AvailableRelease, requirement: String
    ) throws -> Data {
        if Quarantine.isSet(on: staged) { Quarantine.clear(from: staged) }
        // Refuse rather than install something the user would then have to unquarantine by hand.
        guard !Quarantine.isSet(on: staged) else { throw UpdateFailure.quarantined }

        guard let codeHash = BundleSignature.trustedHash(of: staged, requirement: requirement)
        else { throw UpdateFailure.identityMismatch }
        let info = Self.info(at: staged)
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateFailure.bundleMismatch
        }
        let found = info?["CFBundleShortVersionString"] as? String
        guard found == release.version.description else {
            throw UpdateFailure.versionMismatch(
                expected: release.version.description, found: found ?? String(localized: "unknown"))
        }
        return codeHash
    }

    /// Off disk, not through `Bundle`, whose cache would answer for the old copy.
    private static func info(at bundleURL: URL) -> [String: Any]? {
        let url = bundleURL.appending(components: "Contents", "Info.plist")
        guard let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return nil }
        return plist as? [String: Any]
    }
}
