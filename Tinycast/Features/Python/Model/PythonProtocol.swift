import Foundation

/// One cell sent to the driver; `force` runs it even where the REPL would ask for another line.
struct PythonRequest: Encodable, Sendable, Equatable {
    let cell: Int
    let code: String
    let force: Bool

    /// One line of JSON: the encoder escapes every newline, so the driver can read by line.
    func line() -> Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }
}

/// What `PythonSession.py` reports on its event pipe.
enum PythonEvent: Sendable, Equatable {
    case ready(version: String, executable: String)
    case incomplete(cell: Int)
    case started(cell: Int, number: Int)
    case output(cell: Int, stream: PythonStream, text: String)
    case result(cell: Int, text: String, truncated: Bool)
    case error(cell: Int, failure: PythonFailure)
    case finished(cell: Int, ok: Bool, seconds: Double, dropped: Int)
    case exited(code: Int)

    /// nil for a line that isn't one of ours, which is skipped rather than trusted.
    init?(line: Data) {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: line) else { return nil }
        switch raw.type {
        case "ready":
            self = .ready(version: raw.version ?? "", executable: raw.executable ?? "")
        case "incomplete":
            guard let cell = raw.cell else { return nil }
            self = .incomplete(cell: cell)
        case "started":
            guard let cell = raw.cell, let number = raw.number else { return nil }
            self = .started(cell: cell, number: number)
        case "output":
            guard let cell = raw.cell, let stream = raw.stream.flatMap(PythonStream.init(rawValue:)),
                let text = raw.text
            else { return nil }
            self = .output(cell: cell, stream: stream, text: text)
        case "result":
            guard let cell = raw.cell, let text = raw.text else { return nil }
            self = .result(cell: cell, text: text, truncated: raw.truncated ?? false)
        case "error":
            guard let cell = raw.cell, let name = raw.name else { return nil }
            self = .error(
                cell: cell,
                failure: PythonFailure(
                    name: name, summary: raw.summary ?? name, traceback: raw.traceback ?? ""))
        case "finished":
            guard let cell = raw.cell else { return nil }
            self = .finished(
                cell: cell, ok: raw.ok ?? false, seconds: raw.seconds ?? 0, dropped: raw.dropped ?? 0)
        case "exited":
            self = .exited(code: raw.code ?? 0)
        default:
            return nil
        }
    }

    private struct Raw: Decodable {
        let type: String
        let cell: Int?
        let number: Int?
        let stream: String?
        let text: String?
        let truncated: Bool?
        let name: String?
        let summary: String?
        let traceback: String?
        let ok: Bool?
        let seconds: Double?
        let dropped: Int?
        let code: Int?
        let version: String?
        let executable: String?
    }
}

enum PythonStream: String, Sendable, Equatable {
    case stdout
    case stderr
}

struct PythonFailure: Sendable, Equatable {
    let name: String
    let summary: String
    let traceback: String

    var isInterruption: Bool { name == "KeyboardInterrupt" }
}

/// Cuts a byte stream into lines, holding a partial one until the rest of it arrives.
struct PythonLineSplitter: Sendable {
    private var pending = Data()

    mutating func append(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending = pending[pending.index(after: newline)...]
        }
        // Rebased so indices stay small and the consumed prefix is released.
        pending = Data(pending)
        return lines
    }
}

/// UTF-8 decoding across reads: a character split between two of them waits for its tail.
struct PythonTextDecoder: Sendable {
    private var pending = Data()

    mutating func decode(_ bytes: Data) -> String {
        pending.append(bytes)
        let complete = Self.completePrefixLength(of: pending)
        // Lossy on purpose: a subprocess may print bytes that were never UTF-8.
        let text = String(decoding: pending.prefix(complete), as: UTF8.self)
        pending = Data(pending.dropFirst(complete))
        return text
    }

    /// Everything but a trailing, unfinished multi-byte sequence.
    private static func completePrefixLength(of data: Data) -> Int {
        let bytes = [UInt8](data.suffix(3))
        for back in 1...max(bytes.count, 1) where back <= bytes.count {
            let byte = bytes[bytes.count - back]
            guard byte & 0xC0 == 0x80 else {
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return needed > back ? data.count - back : data.count
            }
        }
        return data.count
    }
}
