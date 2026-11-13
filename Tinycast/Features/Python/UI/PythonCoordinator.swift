import AppKit
import Observation
import SwiftUI

/// Owns the one Python session: its interpreter, its cells, and the input being typed.
@MainActor
@Observable
final class PythonCoordinator {
    private(set) var notebook = PythonNotebook()
    /// The input cell's text; it clears only once the driver starts running it.
    var draft = ""
    var draftSelection: TextSelection?
    private(set) var interpreter: PythonInterpreter?

    @ObservationIgnored private var process: PythonProcess?
    @ObservationIgnored private var launching: Task<Void, Never>?
    @ObservationIgnored private var listening: Task<Void, Never>?
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    /// Sent before the interpreter was up; the pipe takes them once it is.
    @ObservationIgnored private var queued: [PythonRequest] = []
    /// The submission awaiting its answer: a run clears the input, a need for more extends it.
    @ObservationIgnored private var awaiting: Int?
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
        paletteCoordinator.showPalette(mode: .python)
        replaceDraft(with: code)
        submit()
    }

    /// ↵: runs the input, or extends it in place when the driver says it isn't finished.
    func submit(force: Bool = false) {
        guard !isBusy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        historyCursor.reset()
        // The driver needs a block's closing empty line; the cell and its history don't.
        let cell = notebook.submit(PythonInput.trimmed(draft))
        awaiting = cell
        send(PythonRequest(cell: cell, code: force ? PythonInput.trimmed(draft) : draft, force: force))
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
    }

    // MARK: - Editing the input

    /// ⇧↵: a new line at the caret, indented as the line before it, one level deeper after `:`.
    func insertLineBreak() {
        apply(PythonInput.lineBreak(in: draft, replacing: selectedOffsets))
    }

    /// ⇥ indents at the caret; ⇧⇥ takes one level off the caret's line.
    func indent(backwards: Bool) {
        let selected = selectedOffsets
        apply(
            backwards
                ? PythonInput.outdent(in: draft, caret: selected.lowerBound)
                : PythonInput.indent(in: draft, replacing: selected))
    }

    /// ↑ on the input's first line and ↓ on its last walk whole cells; elsewhere the caret moves.
    func recallHistory(older: Bool) -> Bool {
        let selected = selectedOffsets
        let onEdge =
            older
            ? PythonInput.isOnFirstLine(draft, caret: selected.lowerBound)
            : PythonInput.isOnLastLine(draft, caret: selected.upperBound)
        guard onEdge else { return false }
        let recalled =
            older
            ? historyCursor.older(in: notebook.history, current: draft)
            : historyCursor.newer(in: notebook.history)
        if let recalled { replaceDraft(with: recalled) }
        return true
    }

    /// The selection in characters, or the end when the field has reported none.
    private var selectedOffsets: Range<Int> {
        guard case .selection(let range)? = draftSelection?.indices,
            range.lowerBound >= draft.startIndex, range.upperBound <= draft.endIndex
        else { return draft.count..<draft.count }
        let lower = draft.distance(from: draft.startIndex, to: range.lowerBound)
        return lower..<(lower + draft.distance(from: range.lowerBound, to: range.upperBound))
    }

    private func apply(_ edit: PythonInput.Edit) {
        draft = edit.text
        let index = draft.index(draft.startIndex, offsetBy: min(edit.caret, draft.count))
        draftSelection = TextSelection(range: index..<index)
    }

    private func replaceDraft(with text: String) {
        draft = text
        draftSelection = TextSelection(range: draft.endIndex..<draft.endIndex)
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
            if case .ended = notebook.status { return dropAwaiting() }
            notebook.endSession(Self.describe(status))
            dropAwaiting()
        }
    }

    /// The prompt follows the driver's answer: more lines for a block, a clear field for a run.
    private func settle(_ event: PythonEvent) {
        switch event {
        case .incomplete(let cell) where cell == awaiting:
            awaiting = nil
            replaceDraft(with: draft + PythonInput.continuation(after: draft))
        case .started(let cell, _) where cell == awaiting:
            awaiting = nil
            replaceDraft(with: "")
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
        dropAwaiting()
    }

    /// A submission that never ran stays in the input, since only a started run clears it.
    private func dropAwaiting() {
        awaiting = nil
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
        dropAwaiting()
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
