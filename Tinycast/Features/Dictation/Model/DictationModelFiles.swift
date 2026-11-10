import Foundation

/// Every file a model install takes, pinned by size and SHA-256 when the app was built.
enum DictationModelFiles {
    struct File: Sendable, Equatable {
        let repository: String
        let revision: String
        let path: String
        let size: Int64
        let sha256: String
    }

    static func files(for model: DictationModel) -> [File] { pinned[model] ?? [] }
}
