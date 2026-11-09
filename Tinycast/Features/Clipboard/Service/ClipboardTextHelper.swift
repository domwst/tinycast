import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
nonisolated enum ClipboardTextHelper {
    /// Past any screenshot a clipboard holds; a larger stdin is refused, not buffered.
    private static let maximumInputBytes = 64 * 1024 * 1024

    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count == 3, arguments[1] == "thumbnail" {
            exit(writeThumbnail(edge: Int(arguments[2])) ? 0 : 1)
        }
        do {
            let text: String
            if arguments.count == 2, arguments[1] == "image-data" {
                guard let data = readInput() else { exit(1) }
                text = try await ClipboardTextExtractor.extract(imageData: data)
            } else if arguments.count == 3, ["image", "pdf"].contains(arguments[1]) {
                text = try await ClipboardTextExtractor.extract(
                    at: URL(fileURLWithPath: arguments[2]), isPDF: arguments[1] == "pdf")
            } else {
                exit(2)
            }
            try FileHandle.standardOutput.write(contentsOf: Data(text.utf8))
        } catch {
            exit(1)
        }
    }

    /// The image arrives unsealed over stdin and leaves as a PNG on stdout; neither touches disk.
    private static func readInput() -> Data? {
        var data = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 1 << 20), !chunk.isEmpty {
            data.append(chunk)
            if data.count > maximumInputBytes { return nil }
        }
        return data.isEmpty ? nil : data
    }

    /// `thumbnail <edge>`: the full-size decode's memory leaves with this process.
    private static func writeThumbnail(edge: Int?) -> Bool {
        guard let edge, let input = readInput(),
            let image = CGImageSourceCreateWithData(input as CFData, nil),
            let decoded = CGImageSourceCreateThumbnailAtIndex(
                image, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: edge
                ] as CFDictionary)
        else { return false }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, decoded, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        return (try? FileHandle.standardOutput.write(contentsOf: data as Data)) != nil
    }
}
