import Foundation

/// One run: the code as submitted and everything it produced, in the order it arrived.
struct PythonCell: Identifiable, Sendable, Equatable {
    enum State: Sendable, Equatable {
        case running
        case succeeded
        case failed
        case interrupted
        /// The interpreter went away mid-cell: a crash, a restart, or the cell's own `exit()`.
        case ended
    }

    struct Output: Sendable, Equatable {
        let stream: PythonStream
        var text: String
    }

    let id: Int
    let code: String
    var number: Int?
    var outputs: [Output] = []
    var result: String?
    var resultTruncated = false
    var failure: PythonFailure?
    var state: State = .running
    var seconds: Double?
    /// Output past the cap, counted so the cell can say what it left out.
    var droppedCharacters = 0

    var isRunning: Bool { state == .running }

    var outputCharacters: Int { outputs.reduce(0) { $0 + $1.text.count } }
}

/// The session's cells and input history, folded from driver events; free of any process.
struct PythonNotebook: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case idle
        case starting
        case ready(version: String)
        /// The interpreter exited; the next run starts a fresh one.
        case ended(String)
    }

    /// Past this many the oldest cells go, so a long session can't grow without bound.
    static let maximumCells = 200
    /// Per cell, matching the driver's own cap on Python-level output.
    static let maximumOutputCharacters = 1_000_000
    static let maximumHistory = 500

    /// Where a session ended, so the cells after it read as a fresh interpreter's.
    struct Divider: Sendable, Equatable {
        let afterCell: Int
        let text: String
    }

    private(set) var cells: [PythonCell] = []
    private(set) var dividers: [Divider] = []
    private(set) var status: Status = .idle
    private(set) var history: [String] = []
    /// Sent but not yet answered: the driver may still say the code wants another line.
    private var pending: [Int: String] = [:]
    private var nextCellID = 1

    var runningCell: PythonCell? { cells.last(where: \.isRunning) }

    var isBusy: Bool { runningCell != nil || !pending.isEmpty }

    mutating func setStatus(_ status: Status) {
        self.status = status
    }

    /// The id the request carries; the cell appears only once the driver starts running it.
    mutating func submit(_ code: String) -> Int {
        let id = nextCellID
        nextCellID += 1
        pending[id] = code
        return id
    }

    mutating func apply(_ event: PythonEvent) {
        switch event {
        case .ready(let version, _):
            status = .ready(version: version)
        case .incomplete(let cell):
            pending[cell] = nil
        case .started(let cell, let number):
            guard let code = pending.removeValue(forKey: cell) else { return }
            start(PythonCell(id: cell, code: code, number: number))
        case .output(let cell, let stream, let text):
            update(cell) { Self.append(text, stream: stream, to: &$0) }
        case .result(let cell, let text, let truncated):
            update(cell) {
                $0.result = text
                $0.resultTruncated = truncated
            }
        case .error(let cell, let failure):
            update(cell) { $0.failure = failure }
        case .finished(let cell, let ok, let seconds, let dropped):
            update(cell) {
                $0.seconds = seconds
                $0.droppedCharacters += dropped
                $0.state = ok ? .succeeded : ($0.failure?.isInterruption == true ? .interrupted : .failed)
            }
        case .exited(let code):
            endSession(String(localized: "Python exited with status \(code)."))
        }
    }

    /// Bytes a subprocess wrote straight to fd 1 or 2 belong to whichever cell ran last.
    mutating func appendRawOutput(_ text: String, stream: PythonStream) {
        guard !text.isEmpty, let index = cells.indices.last else { return }
        Self.append(text, stream: stream, to: &cells[index])
    }

    /// A running cell can never finish once its interpreter is gone, so it is closed here.
    mutating func endSession(_ reason: String) {
        pending.removeAll()
        for index in cells.indices where cells[index].isRunning {
            cells[index].state = .ended
        }
        status = .ended(reason)
        if let last = cells.last?.id, dividers.last?.afterCell != last {
            dividers.append(Divider(afterCell: last, text: reason))
        }
    }

    mutating func clear() {
        cells.removeAll { !$0.isRunning }
        dividers.removeAll()
    }

    private mutating func start(_ cell: PythonCell) {
        cells.append(cell)
        if cells.count > Self.maximumCells { cells.removeFirst(cells.count - Self.maximumCells) }
        if history.last != cell.code { history.append(cell.code) }
        if history.count > Self.maximumHistory { history.removeFirst(history.count - Self.maximumHistory) }
    }

    private mutating func update(_ cell: Int, _ change: (inout PythonCell) -> Void) {
        guard let index = cells.lastIndex(where: { $0.id == cell }) else { return }
        change(&cells[index])
    }

    private static func append(_ text: String, stream: PythonStream, to cell: inout PythonCell) {
        let room = maximumOutputCharacters - cell.outputCharacters
        let kept = room > 0 ? String(text.prefix(room)) : ""
        cell.droppedCharacters += text.count - kept.count
        guard !kept.isEmpty else { return }
        if let last = cell.outputs.indices.last, cell.outputs[last].stream == stream {
            cell.outputs[last].text += kept
        } else {
            cell.outputs.append(PythonCell.Output(stream: stream, text: kept))
        }
    }
}

/// Up and Down in the input, the way a shell walks its history: newest first, back to the draft.
struct PythonHistoryCursor: Sendable, Equatable {
    private var index: Int?
    private var draft = ""

    mutating func older(in history: [String], current: String) -> String? {
        guard !history.isEmpty else { return nil }
        if index == nil { draft = current }
        let next = max((index ?? history.count) - 1, 0)
        guard next != index else { return nil }
        index = next
        return history[next]
    }

    mutating func newer(in history: [String]) -> String? {
        guard let index else { return nil }
        if index + 1 < history.count {
            self.index = index + 1
            return history[index + 1]
        }
        self.index = nil
        return draft
    }

    mutating func reset() {
        index = nil
        draft = ""
    }
}
