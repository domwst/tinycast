import Darwin
import Foundation
import Synchronization

/// Compiles the shipped Python model and process, and drives the real driver with a real python3.
@main
struct PythonSessionTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ description: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            print("PASS  \(description)")
        } else {
            print("FAIL  \(description)")
            failures += 1
        }
    }

    static func main() async {
        input()
        decoding()
        notebook()
        history()
        await session()
        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - Model

    static func input() {
        check("a block opener indents the next line", PythonInput.continuation(after: "def f():") == "\n    ")
        check(
            "a continuation keeps the current indent",
            PythonInput.continuation(after: "def f():\n    x = (1,") == "\n    ")
        check(
            "a nested opener indents one more level",
            PythonInput.continuation(after: "for i in x:\n    if i:") == "\n        ")
        check("closing empty lines are trimmed", PythonInput.trimmed("def f():\n    pass\n  \n") == "def f():\n    pass")
        let opened = PythonInput.lineBreak(in: "for i in x:", replacing: 11..<11)
        check("⇧↵ after a colon indents the new line", opened == PythonInput.Edit(text: "for i in x:\n    ", caret: 16))
        let split = PythonInput.lineBreak(in: "    a = 1b = 2", replacing: 9..<9)
        check("⇧↵ mid-line keeps the line's indent", split == PythonInput.Edit(text: "    a = 1\n    b = 2", caret: 14))
        let replaced = PythonInput.indent(in: "ab", replacing: 0..<2)
        check("⇥ replaces a selection with one indent", replaced == PythonInput.Edit(text: "    ", caret: 4))
        let outdented = PythonInput.outdent(in: "x\n      y", caret: 9)
        check("⇧⇥ takes one level off the caret's line", outdented == PythonInput.Edit(text: "x\n  y", caret: 5))
        let shallow = PythonInput.outdent(in: "  y", caret: 1)
        check("⇧⇥ never moves the caret off its line", shallow == PythonInput.Edit(text: "y", caret: 0))
        check("a lone line is both first and last", PythonInput.isOnFirstLine("abc", caret: 1)
            && PythonInput.isOnLastLine("abc", caret: 1))
        check("the second line is not the first", !PythonInput.isOnFirstLine("a\nb", caret: 3))
        check("the first line is not the last", !PythonInput.isOnLastLine("a\nb", caret: 1))
        check("`py ` carries code", PythonInput.launcherCode(in: "py 2**64") == "2**64")
        check("`python ` carries code", PythonInput.launcherCode(in: "  Python   len('ab') ") == "len('ab')")
        check("bare `py` is the command, not code", PythonInput.launcherCode(in: "py") == nil)
        check("`py ` with nothing after is not code", PythonInput.launcherCode(in: "py   ") == nil)
        check("`pyramid` is not a Python query", PythonInput.launcherCode(in: "pyramid x") == nil)
        check("`pythonic x` is not a Python query", PythonInput.launcherCode(in: "pythonic x") == nil)
    }

    static func decoding() {
        var decoder = PythonTextDecoder()
        let bytes = Data("é€😀".utf8)
        var text = ""
        for byte in bytes { text += decoder.decode(Data([byte])) }
        check("a character split across reads decodes whole", text == "é€😀")

        var splitter = PythonLineSplitter()
        let first = splitter.append(Data("{\"a\":1}\n{\"b\"".utf8))
        let second = splitter.append(Data(":2}\n".utf8))
        check(
            "a line split across reads arrives once, whole",
            first.map { String(bytes: $0, encoding: .utf8) } == ["{\"a\":1}"]
                && second.map { String(bytes: $0, encoding: .utf8) } == ["{\"b\":2}"])
        check(
            "an unknown event is skipped, not trusted",
            PythonEvent(line: Data("{\"type\":\"surprise\"}".utf8)) == nil)
    }

    static func notebook() {
        var notebook = PythonNotebook()
        let incomplete = notebook.submit("def f():")
        check("a submission is busy until answered", notebook.isBusy)
        notebook.apply(.incomplete(cell: incomplete))
        check("an incomplete answer makes no cell", notebook.cells.isEmpty && !notebook.isBusy)
        check("an incomplete answer adds no history", notebook.history.isEmpty)

        let run = notebook.submit("print(1); 1/0")
        notebook.apply(.started(cell: run, number: 1))
        notebook.apply(.output(cell: run, stream: .stdout, text: "1\n"))
        notebook.apply(.output(cell: run, stream: .stdout, text: "2\n"))
        notebook.apply(.output(cell: run, stream: .stderr, text: "warn\n"))
        notebook.apply(
            .error(cell: run, failure: PythonFailure(name: "ZeroDivisionError", summary: "Z", traceback: "T")))
        notebook.apply(.finished(cell: run, ok: false, seconds: 0.5, dropped: 3))
        let cell = notebook.cells.last
        check(
            "consecutive output on one stream joins, a stream change starts a block",
            cell?.outputs == [
                PythonCell.Output(stream: .stdout, text: "1\n2\n"),
                PythonCell.Output(stream: .stderr, text: "warn\n")
            ])
        check("a failed cell reads as failed", cell?.state == .failed && cell?.number == 1)
        check("the driver's dropped count is kept", cell?.droppedCharacters == 3)
        check("a started cell enters history", notebook.history == ["print(1); 1/0"])

        let stuck = notebook.submit("while True: pass")
        notebook.apply(.started(cell: stuck, number: 2))
        notebook.apply(
            .error(cell: stuck, failure: PythonFailure(name: "KeyboardInterrupt", summary: "", traceback: "")))
        notebook.apply(.finished(cell: stuck, ok: false, seconds: 1, dropped: 0))
        check("Ctrl-C reads as interrupted", notebook.cells.last?.state == .interrupted)

        let lost = notebook.submit("import os; os._exit(1)")
        notebook.apply(.started(cell: lost, number: 3))
        notebook.endSession("gone")
        check(
            "a running cell ends with its interpreter",
            notebook.cells.last?.state == .ended && notebook.status == .ended("gone") && !notebook.isBusy)

        notebook.endSession("gone again")
        check(
            "one session end marks one divider after the last cell",
            notebook.dividers == [PythonNotebook.Divider(afterCell: lost, text: "gone")])

        notebook.appendRawOutput("late\n", stream: .stdout)
        check("raw output joins the latest cell", notebook.cells.last?.outputs.last?.text == "late\n")

        var capped = PythonNotebook()
        let big = capped.submit("print(x)")
        capped.apply(.started(cell: big, number: 1))
        capped.appendRawOutput(String(repeating: "x", count: PythonNotebook.maximumOutputCharacters + 5), stream: .stdout)
        check(
            "output past the cap is dropped and counted",
            capped.cells.last?.outputCharacters == PythonNotebook.maximumOutputCharacters
                && capped.cells.last?.droppedCharacters == 5)

        var many = PythonNotebook()
        for number in 1...(PythonNotebook.maximumCells + 3) {
            let id = many.submit("\(number)")
            many.apply(.started(cell: id, number: number))
            many.apply(.finished(cell: id, ok: true, seconds: 0, dropped: 0))
        }
        check(
            "the oldest cells go past the limit",
            many.cells.count == PythonNotebook.maximumCells && many.cells.first?.code == "4")
        many.clear()
        check("clear empties the notebook", many.cells.isEmpty)
    }

    static func history() {
        var cursor = PythonHistoryCursor()
        let past = ["a", "b", "c"]
        check("Up starts at the newest", cursor.older(in: past, current: "draft") == "c")
        check("Up walks back", cursor.older(in: past, current: "c") == "b")
        check("Down walks forward", cursor.newer(in: past) == "c")
        check("Down past the newest restores the draft", cursor.newer(in: past) == "draft")
        check("Down with no walk does nothing", cursor.newer(in: past) == nil)
        _ = cursor.older(in: past, current: "")
        _ = cursor.older(in: past, current: "")
        _ = cursor.older(in: past, current: "")
        check("Up stops at the oldest", cursor.older(in: past, current: "") == nil)
    }

    // MARK: - Live session

    static let driver = FileManager.default.currentDirectoryPath + "/Tinycast/Resources/PythonSession.py"

    /// Whichever python3 the harness's own PATH finds: the real thing, never a stub.
    static func interpreter() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/python3"
            guard candidate != "/usr/bin/python3" || FileManager.default.fileExists(
                atPath: "/Library/Developer/CommandLineTools/usr/bin/python3")
                || FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
            else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The messages of one process, buffered as they arrive, so every wait is bounded by a clock.
    final class Reader: Sendable {
        private let buffer = Mutex<(messages: [PythonProcess.Message], consumed: Int)>(([], 0))

        init(_ process: PythonProcess) {
            Task.detached { [self] in
                for await message in process.messages {
                    buffer.withLock { $0.messages.append(message) }
                }
            }
        }

        var raw: String {
            buffer.withLock { state in
                state.messages.reduce(into: "") {
                    if case .rawOutput(_, let text) = $1 { $0 += text }
                }
            }
        }

        func until(
            seconds: Double = 10, _ done: @escaping (PythonProcess.Message) -> Bool
        ) async -> [PythonProcess.Message] {
            let deadline = Date().addingTimeInterval(seconds)
            var seen: [PythonProcess.Message] = []
            while Date() < deadline {
                let fresh = buffer.withLock { state -> [PythonProcess.Message] in
                    let fresh = Array(state.messages[state.consumed...])
                    state.consumed = state.messages.count
                    return fresh
                }
                for (index, message) in fresh.enumerated() {
                    seen.append(message)
                    guard done(message) else { continue }
                    let unread = fresh.count - index - 1
                    buffer.withLock { $0.consumed -= unread }
                    return seen
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return seen
        }
    }

    static func events(_ messages: [PythonProcess.Message]) -> [PythonEvent] {
        messages.compactMap {
            guard case .event(let event) = $0 else { return nil }
            return event
        }
    }

    static func finished(_ cell: Int) -> (PythonProcess.Message) -> Bool {
        {
            guard case .event(let event) = $0 else { return false }
            switch event {
            case .finished(let id, _, _, _), .incomplete(let id): return id == cell
            default: return false
            }
        }
    }

    static func session() async {
        guard let python = interpreter() else {
            print("SKIP  live session: no python3 on PATH")
            return
        }
        print("using \(python)")
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("python-session-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // A planted module in the working folder must not load before the user asks for it.
        try? Data("raise SystemExit('hijacked')\n".utf8).write(to: home.appendingPathComponent("json.py"))

        guard case .success(let process) = PythonProcess.launch(
            interpreter: python, driver: driver, environment: ProcessInfo.processInfo.environment,
            directory: home.path)
        else {
            check("the interpreter launches", false)
            return
        }
        let reader = Reader(process)
        let ready = events(await reader.until {
            if case .event(.ready) = $0 { return true }
            return false
        })
        check("the driver reports ready despite a planted json.py", ready.contains {
            if case .ready(let version, _) = $0 { return version.hasPrefix("3.") }
            return false
        })

        process.send(PythonRequest(cell: 1, code: "x = 6 * 7\nx", force: false))
        let first = events(await reader.until(finished(1)))
        check("a final expression's value comes back", first.contains(.result(cell: 1, text: "42", truncated: false)))
        check("the first run is number 1", first.contains(.started(cell: 1, number: 1)))

        process.send(PythonRequest(cell: 2, code: "def f():", force: false))
        let opened = events(await reader.until(finished(2)))
        check("an open block asks for more", opened == [.incomplete(cell: 2)])

        process.send(PythonRequest(cell: 3, code: "def f():\n    return x + 1\n", force: false))
        _ = await reader.until(finished(3))
        process.send(PythonRequest(cell: 4, code: "f()", force: false))
        let called = events(await reader.until(finished(4)))
        check("state persists between cells", called.contains(.result(cell: 4, text: "43", truncated: false)))

        process.send(PythonRequest(cell: 5, code: "print('hi'); 1/0", force: false))
        let failing = events(await reader.until(finished(5)))
        check(
            "printed output precedes the error, attributed to its cell",
            failing.firstIndex(of: .output(cell: 5, stream: .stdout, text: "hi\n")) ?? .max
                < failing.firstIndex { if case .error = $0 { return true } else { return false } } ?? -1)
        check("an exception reports its type", failing.contains {
            if case .error(5, let failure) = $0 { return failure.name == "ZeroDivisionError" }
            return false
        })

        process.send(PythonRequest(cell: 6, code: "input()", force: false))
        let prompted = events(await reader.until(finished(6)))
        check("input() reads end-of-file instead of hanging", prompted.contains {
            if case .error(6, let failure) = $0 { return failure.name == "EOFError" }
            return false
        })

        let rawCode = "import os, subprocess\nos.write(1, b'raw\\n')\nsubprocess.run(['echo', 'sub'])\nNone"
        process.send(PythonRequest(cell: 7, code: rawCode, force: false))
        _ = await reader.until(finished(7))
        _ = await reader.until(seconds: 0.5) { _ in false }
        check("output written to fd 1 arrives raw", reader.raw.contains("raw\n") && reader.raw.contains("sub\n"))

        process.send(PythonRequest(cell: 8, code: "print('{\"type\":\"result\",\"cell\":8,\"text\":\"spoof\"}')", force: false))
        let spoof = events(await reader.until(finished(8)))
        check("printed JSON stays output, never an event", !spoof.contains(.result(cell: 8, text: "spoof", truncated: false)))

        process.send(PythonRequest(cell: 9, code: "import time\nwhile True: time.sleep(0.01)", force: false))
        _ = await reader.until(seconds: 0.5) { _ in false }
        process.interrupt()
        let interrupted = events(await reader.until(finished(9)))
        check("Ctrl-C interrupts a running cell", interrupted.contains {
            if case .error(9, let failure) = $0 { return failure.isInterruption }
            return false
        })

        process.send(PythonRequest(cell: 10, code: "x", force: false))
        let survived = events(await reader.until(finished(10)))
        check("the session survives an interrupt", survived.contains(.result(cell: 10, text: "42", truncated: false)))

        process.send(PythonRequest(cell: 11, code: "print('y' * 1_200_000)", force: false))
        let flooded = events(await reader.until(seconds: 30, finished(11)))
        check("a flood of output is capped and counted", flooded.contains {
            if case .finished(11, _, _, let dropped) = $0 { return dropped > 0 }
            return false
        })

        process.send(PythonRequest(cell: 12, code: "import subprocess\nsubprocess.Popen(['sleep', '77']).pid", force: false))
        var child: pid_t = 0
        for event in events(await reader.until(finished(12))) {
            if case .result(12, let text, _) = event { child = pid_t(text) ?? 0 }
        }
        process.stop()
        let ending = await reader.until {
            if case .exited = $0 { return true }
            return false
        }
        check("stop ends the interpreter", ending.contains {
            if case .exited = $0 { return true }
            return false
        })
        try? await Task.sleep(for: .milliseconds(300))
        check("stop ends what the session started too", child > 0 && kill(child, 0) != 0)

        guard case .success(let second) = PythonProcess.launch(
            interpreter: python, driver: driver, environment: ProcessInfo.processInfo.environment,
            directory: home.path)
        else { return check("a second session launches", false) }
        let next = Reader(second)
        _ = await next.until {
            if case .event(.ready) = $0 { return true }
            return false
        }
        second.send(PythonRequest(cell: 1, code: "exit(3)", force: false))
        let exited = await next.until {
            if case .exited = $0 { return true }
            return false
        }
        check("exit() reports its status and ends the session", events(exited).contains(.exited(code: 3)))
    }
}
