import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Which image paths a `.rayconfig` may hand the clipboard: one could name `~/.ssh/id_ed25519`.
enum RaycastImagePolicy {
    /// Every Raycast channel (stable, beta, alpha, internal) shares this bundle-id prefix.
    static let bundleIDPrefix = "com.raycast"
    /// Past any screenshot Raycast keeps; a bigger "image" is refused rather than read.
    static let maximumBytes = 64 * 1024 * 1024

    /// A real, decodable image file inside one of Raycast's own Application Support folders.
    static func accepts(
        _ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let support =
            home.appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .standardizedFileURL.path + "/"
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard !path.split(separator: "/").contains(".."), url.path.hasPrefix(support),
            url.path.dropFirst(support.count).hasPrefix(bundleIDPrefix),
            url.resolvingSymlinksInPath().path == url.path,
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            ((attributes[.size] as? NSNumber)?.intValue ?? .max) <= maximumBytes,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source) as String?,
            UTType(type)?.conforms(to: .image) == true, CGImageSourceGetCount(source) > 0
        else { return false }
        return true
    }
}
