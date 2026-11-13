import AppKit
import Observation

/// Owns the one Python session: its interpreter, its cells, and the prompt's unfinished block.
@MainActor
@Observable
final class PythonCoordinator {
    private(set) var notebook = PythonNotebook()
    /// Lines of a block the driver said isn't finished, shown above the field's current line.
    private(set) var pendingLines: [String] = []
    private(set) var interpreter: PythonInterpreter?

    @ObservationIgnored private var process: PythonProcess?
    @ObservationIgnored private var launching: Task<Void, Never>?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    /// Sent before the interpreter was up; the pipe takes them once it is.
    @ObservationIgnored private var queued: [PythonRequest] = []
    /// The field's line of a submission awaiting its answer, put back if it needs more.
    @ObservationIgnored private var awaiting: (cell: Int, line: String)?
    @ObservationIgnored private var historyCursor = PythonHistoryCursor()

    private let settings: AppSettings
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let appIndex: AppIndex
    private unowned let core: AppCore
    private let driverPath: String?

    /// Long enough for a coffee, short enough that a forgotten interpreter doesn't linger all day.
    static let idleLimit: Duration = .seconds(15 * 60)

    init(
        settings: AppSettings, palette: PaletteState, paletteCoordinator: PaletteCoordinator,
        appIndex: AppIndex, core: AppCore,
        driverPath: String? = Bundle.main.path(forResource: "PythonSession", ofType: "py")
    ) {
        self.settings = settings
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.appIndex = appIndex
        self.core = core
        self.driverPath = driverPath
    }

    var isRunning: Bool { notebook.runningCell != nil }
    var isBusy: Bool { notebook.isBusy }

    func applyEnabled() {
        appIndex.setCommandsVisible([.python], settings.pythonEnabled)
        guard !settings.pythonEnabled else { return }
        shutDown(reason: String(localized: "Python was switched off."))
        pendingLines = []
        if palette.mode == .python { palette.prepare(mode: .launcher) }
    }

    /// The command toggles the screen; `py <code>` always opens it and runs the code.
    func open(running code: String? = nil) {
        guard settings.pythonEnabled else { return }
        guard let code else {
            guard !paletteCoordinator.isShowing(.python) else { return paletteCoordinator.hidePalette() }
            paletteCoordinator.showPalette(mode: .python)
            ensureSession()
            return
        }
        guard !isBusy else { return paletteCoordinator.showPalette(mode: .python, seeding: code) }
        // A command from the launcher is a fresh statement, not the tail of an abandoned block.
        pendingLines = []
        paletteCoordinator.showPalette(mode: .python)
        _ = submit(code)
    }

    /// False when nothing was sent, so the field keeps what was typed.
    func submit(_ line: String, force: Bool = false) -> Bool {
        guard !isBusy else { return false }
        let code = (pendingLines + [line]).joined(separator: "\n")
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pendingLines = []
            return false
        }
        historyCursor.reset()
        // The driver needs a block's closing empty line; the cell and its history don't.
        let cell = notebook.submit(PythonInput.trimmed(code))
        awaiting = (cell, line)
        send(PythonRequest(cell: cell, code: force ? PythonInput.trimmed(code) : code, force: force))
        return true
    }

    func interrupt() {
        guard isRunning else { return }
        process?.interrupt()
    }

    /// A clean interpreter; the cells stay, divided from the ones that follow.
    func restart() {
        shutDown(reason: String(localized: "Restarted."))
        ensureSession()
    }

    func clear() {
        notebook.clear()
        pendingLines = []
    }

    /// ⎋ with an empty field drops the unfinished block, as Ctrl-C does at a `...` prompt.
    func cancelPendingLines() -> Bool {
        guard !pendingLines.isEmpty else { return false }
        pendingLines = []
        return true
    }

    /// ⌫ on an empty field steps back into the block's last line, as deleting a newline would.
    func reopenLastPendingLine() -> Bool {
        guard let last = pendingLines.popLast() else { return false }
        palette.query = last
        return true
    }

    /// A pasted block's lines join the unfinished block, leaving its last line in the field.
    func absorbLineBreaks() -> Bool {
        guard palette.query.contains(where: \.isNewline) else { return false }
        let normalized = palette.query.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.components(separatedBy: "\n")
        let last = lines.removeLast()
        pendingLines += lines
        palette.query = last
        return true
    }

    func indent(backwards: Bool) {
        if backwards {
            let removable = palette.query.prefix(PythonInput.indentUnit.count).prefix { $0 == " " }
            palette.query.removeFirst(removable.count)
        } else {
            palette.query += PythonInput.indentUnit
        }
    }

    /// ↑ and ↓ walk whole cells; a multi-line one lands as its block plus its last line.
    func recallHistory(older: Bool) {
        let current = (pendingLines + [palette.query]).joined(separator: "\n")
        let recalled =
            older
            ? historyCursor.older(in: notebook.history, current: current)
            : historyCursor.newer(in: notebook.history)
        guard let recalled else { return }
        var lines = recalled.components(separatedBy: "\n")
        let last = lines.removeLast()
        pendingLines = lines
        palette.query = last
    }

    var lastOutput: String? {
        guard let cell = notebook.cells.last(where: { !$0.isRunning }) else { return nil }
        var printed = cell.outputs.map(\.text).joined()
        if printed.hasSuffix("\n") { printed.removeLast() }
        let parts = [printed.isEmpty ? nil : printed, cell.result, cell.failure?.summary]
        let text = parts.compactMap { $0 }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    func copyLastOutput() {
        guard let text = lastOutput else { return }
        copy(text)
    }

    func copy(_ text: String) {
        Paster.copyPlainText(text)
    }

    func showSettings() {
        if paletteCoordinator.isVisible { paletteCoordinator.hidePalette(restoreFocus: false) }
        core.settingsCoordinator.showSettings(tab: .general, revealing: .section(.generalPython))
    }

    /// Called at quit: the interpreter and anything it started go with Tinycast.
    func prepareForTermination() {
        shutDown(reason: String(localized: "Tinycast quit."))
    }

    // MARK: - Session

    /// Warm by the time the first line is typed, so its run never waits on a shell lookup.
    func ensureSession() {
        guard settings.pythonEnabled, process == nil, launching == nil else { return }
        guard let driverPath else {
            return fail(String(localized: "Tinycast's Python driver is missing from the app."))
        }
        notebook.setStatus(.starting)
        launching = Task { [weak self] in
            guard let self else { return }
            let resolution = await PythonInterpreterLocator.resolve(configured: settings.pythonInterpreterPath)
            guard !Task.isCancelled else { return }
            launching = nil
            switch resolution {
            case .failure(let failure): fail(failure.message)
            case .success(let interpreter): start(interpreter, driver: driverPath)
            }
        }
    }

    private func start(_ interpreter: PythonInterpreter, driver: String) {
        var environment = ProcessInfo.processInfo.environment
        if let searchPath = interpreter.searchPath { environment["PATH"] = searchPath }
        let launched = PythonProcess.launch(
            interpreter: interpreter.path, driver: driver, environment: environment,
            directory: NSHomeDirectory())
        switch launched {
        case .failure(let error):
            fail(String(localized: "Python couldn't start: \(error.localizedDescription)"))
        case .success(let process):
            self.process = process
            self.interpreter = interpreter
            for request in queued { process.send(request) }
            queued.removeAll()
            listening = Task { [weak self] in
                for await message in process.messages {
                    guard let self, self.process === process else { return }
                    handle(message, from: process)
                }
            }
            scheduleIdleStop()
        }
    }

    private func send(_ request: PythonRequest) {
        if let process {
            process.send(request)
        } else {
            queued.append(request)
            ensureSession()
        }
    }

    private func handle(_ message: PythonProcess.Message, from process: PythonProcess) {
        switch message {
        case .event(let event):
            notebook.apply(event)
            settle(event)
        case .rawOutput(let stream, let text):
            notebook.appendRawOutput(text, stream: stream)
        case .exited(let status):
            self.process = nil
            listening = nil
            idleTimer?.cancel()
            // `exit()` already said why; only a crash still needs telling.
            if case .ended = notebook.status { return restoreAwaitingLine() }
            notebook.endSession(Self.describe(status))
            restoreAwaitingLine()
        }
    }

    /// The prompt follows the driver's answer: more lines for a block, a clear field for a run.
    private func settle(_ event: PythonEvent) {
        switch event {
        case .incomplete(let cell) where cell == awaiting?.cell:
            pendingLines.append(awaiting?.line ?? "")
            awaiting = nil
            let code = pendingLines.joined(separator: "\n")
            if palette.mode == .python, palette.query.isEmpty {
                palette.query = String(PythonInput.continuation(after: code).dropFirst())
            }
        case .started(let cell, _) where cell == awaiting?.cell:
            awaiting = nil
            pendingLines = []
        case .finished:
            scheduleIdleStop()
        default:
            break
        }
    }

    private func fail(_ reason: String) {
        launching = nil
        queued.removeAll()
        notebook.endSession(reason)
        restoreAwaitingLine()
    }

    /// A submission that never ran goes back to the field rather than vanishing with the session.
    private func restoreAwaitingLine() {
        guard let awaiting else { return }
        self.awaiting = nil
        if palette.mode == .python, palette.query.isEmpty { palette.query = awaiting.line }
    }

    private func shutDown(reason: String) {
        launching?.cancel()
        launching = nil
        queued.removeAll()
        idleTimer?.cancel()
        idleTimer = nil
        guard let process else {
            if case .starting = notebook.status { notebook.setStatus(.idle) }
            return
        }
        // Forgotten at once, so a restart launches without waiting for the old one to be reaped.
        self.process = nil
        listening?.cancel()
        listening = nil
        process.stop()
        notebook.endSession(reason)
        restoreAwaitingLine()
    }

    private func scheduleIdleStop() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.idleLimit)) != nil, let self else { return }
            guard !isBusy else { return scheduleIdleStop() }
            shutDown(reason: String(localized: "Python stopped after 15 idle minutes."))
        }
    }

    private static func describe(_ status: Int32) -> String {
        let signal = Int(status & 0x7F)
        guard signal != 0 else {
            return String(localized: "Python exited with status \(Int((status >> 8) & 0xFF)).")
        }
        return String(localized: "Python quit unexpectedly (signal \(signal)).")
    }
}
