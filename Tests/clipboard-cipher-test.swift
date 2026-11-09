import CryptoKit
import Foundation

/// Compiles the shipped seal: `SealedFile`'s segmented format and the per-field text cipher.
@main
struct ClipboardCipherTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    /// UUID-suffixed, per docs/testing.md: harnesses run in parallel against the real system.
    static func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipboard-cipher-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func main() {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        roundTrips(in: root)
        tampering(in: root)
        layout(in: root)
        fields()

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
    }

    // MARK: - SealedFile

    static func roundTrips(in root: URL) {
        let key = SymmetricKey(size: .bits256)
        let segment = SealedFile.segmentSize
        for size in [0, 1, segment - 1, segment, segment + 1, 3 * segment + 17] {
            let url = root.appendingPathComponent("blob-\(size).sealed")
            let data = bytes(size)
            do {
                try SealedFile.write(data, to: url, key: key)
                let read = try SealedFile.read(url, key: key)
                check("\(size) bytes round trip", read == data)
            } catch {
                check("\(size) bytes round trip (\(error))", false)
            }
            check("\(size) bytes: the plaintext size is implied", SealedFile.plaintextSize(of: url) == size)
            check("\(size) bytes: the file reads as sealed", SealedFile.isSealed(url))
        }
        let marker = Data("MARKER-\(UUID().uuidString)".utf8)
        let url = root.appendingPathComponent("marker.sealed")
        try? SealedFile.write(marker + bytes(segment * 2), to: url, key: key)
        let raw = (try? Data(contentsOf: url)) ?? Data()
        check("no plaintext survives in the file", raw.range(of: marker) == nil)
        let again = root.appendingPathComponent("again.sealed")
        try? SealedFile.write(marker, to: again, key: key)
        let first = try? Data(contentsOf: again)
        try? SealedFile.write(marker, to: again, key: key)
        check("sealing the same bytes twice differs", first != (try? Data(contentsOf: again)))
        check("a plain file is not sealed", !SealedFile.isSealed(URL(fileURLWithPath: #filePath)))
    }

    static func tampering(in root: URL) {
        let key = SymmetricKey(size: .bits256)
        let segment = SealedFile.segmentSize
        let data = bytes(2 * segment + 100)
        let url = root.appendingPathComponent("original.sealed")
        try? SealedFile.write(data, to: url, key: key)
        let raw = (try? Data(contentsOf: url)) ?? Data()

        check("the wrong key fails", readError(url, key: SymmetricKey(size: .bits256)) == .damaged)

        let renamed = root.appendingPathComponent("renamed.sealed")
        try? raw.write(to: renamed)
        check("a renamed file fails: its name is authenticated", readError(renamed, key: key) == .damaged)

        // Cut exactly after the first two whole segments: only the final flag catches this.
        let boundary = 12 + 2 * (segment + 16)
        check(
            "a file cut at a segment boundary fails",
            readError(write(raw.prefix(boundary), as: "original.sealed", in: root, "cut"), key: key)
                == .damaged)
        check(
            "a file cut mid-segment fails",
            readError(write(raw.prefix(raw.count - 5), as: "original.sealed", in: root, "mid"), key: key)
                == .damaged)
        check(
            "a byte appended fails",
            readError(write(raw + Data([0]), as: "original.sealed", in: root, "long"), key: key)
                == .damaged)
        var flipped = raw
        flipped[raw.count / 2] ^= 0x01
        check(
            "a flipped bit fails",
            readError(write(flipped, as: "original.sealed", in: root, "flip"), key: key) == .damaged)
        var reordered = raw
        let first = raw.subdata(in: 12..<(12 + segment + 16))
        let second = raw.subdata(in: (12 + segment + 16)..<(12 + 2 * (segment + 16)))
        reordered.replaceSubrange(12..<(12 + 2 * (segment + 16)), with: second + first)
        check(
            "swapped segments fail",
            readError(write(reordered, as: "original.sealed", in: root, "swap"), key: key)
                == .damaged)
        check(
            "a missing file is unreadable",
            readError(root.appendingPathComponent("absent.sealed"), key: key) == .unreadable)
    }

    /// Same file name in a folder of its own, so only the bytes differ from the original.
    static func write(_ data: Data, as name: String, in root: URL, _ folder: String) -> URL {
        let directory = root.appendingPathComponent(folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? data.write(to: url)
        return url
    }

    static func readError(_ url: URL, key: SymmetricKey) -> SealedFile.Failure? {
        do {
            _ = try SealedFile.read(url, key: key)
            return nil
        } catch {
            return error as? SealedFile.Failure
        }
    }

    static func layout(in root: URL) {
        let key = SymmetricKey(size: .bits256)
        let url = root.appendingPathComponent("layout.sealed")
        try? SealedFile.write(bytes(10), to: url, key: key)
        let raw = (try? Data(contentsOf: url)) ?? Data()
        check("the file starts with its magic and version", Array(raw.prefix(5)) == Array("TCSF".utf8) + [1])
        check("one segment is header, plaintext and tag", raw.count == 12 + 10 + 16)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions]
        check("only the owner can read it", (mode as? NSNumber)?.intValue == 0o600)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        check("no partial file is left behind", !leftovers.contains { $0.hasSuffix(".partial") })
        check("an impossible size implies nothing", SealedFile.plaintextSize(ofSealedSize: 12 + 15) == nil)
    }

    // MARK: - ClipboardCipher

    static func fields() {
        let root = ClipboardCipher.makeRootKey()
        let cipher = ClipboardCipher(rootKey: root)
        let row = UUID()
        guard let sealed = cipher.seal("secret token", field: .text, row: row) else {
            return check("a value seals", false)
        }
        check("a value opens under its field and row", cipher.open(sealed, field: .text, row: row) == "secret token")
        check(
            "the same root key derives the same cipher",
            ClipboardCipher(rootKey: root).open(sealed, field: .text, row: row) == "secret token")
        check("another field can't open it", cipher.open(sealed, field: .source, row: row) == nil)
        check("another row can't open it", cipher.open(sealed, field: .text, row: UUID()) == nil)
        check(
            "another root key can't open it",
            ClipboardCipher(rootKey: ClipboardCipher.makeRootKey()).open(sealed, field: .text, row: row)
                == nil)
        var tampered = sealed
        tampered[tampered.count - 1] ^= 0x01
        check("a tampered value fails", cipher.open(tampered, field: .text, row: row) == nil)
        check(
            "no plaintext survives in the sealed value",
            sealed.range(of: Data("secret token".utf8)) == nil)
        check(
            "sealing twice differs",
            cipher.seal("secret token", field: .text, row: row) != sealed)
        check(
            "an empty value round trips",
            cipher.seal("", field: .text, row: row).flatMap { cipher.open($0, field: .text, row: row) } == "")
        let blobKeyBytes = cipher.blobKey.withUnsafeBytes { Data($0) }
        let rootBytes = root.withUnsafeBytes { Data($0) }
        check("the blob key is derived, not the root key itself", blobKeyBytes != rootBytes)
    }
}
