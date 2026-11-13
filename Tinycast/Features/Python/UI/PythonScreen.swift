import SwiftUI

/// Python: the search field is the `>>>` prompt, and the screen is the session's cells.
struct PythonScreen: PaletteScreen {
    let vm: PaletteState
    let coordinator: PythonCoordinator

    struct Row: Identifiable {
        let id = "python-prompt"
    }

    let rows = [Row()]

    var primaryActionTitle: String {
        coordinator.isBusy ? String(localized: "Running") : String(localized: "Run")
    }

    /// Return never interrupts: a line typed ahead must not cost the cell it was typed under.
    func isPrimaryActionEnabled(at selection: Int) -> Bool { !coordinator.isBusy }

    func activate(at selection: Int) {
        if coordinator.submit(vm.query) { vm.query = "" }
    }

    /// ⌘↵ runs what is there now, even where the REPL would ask for another line.
    func secondary(at selection: Int) -> Bool {
        if coordinator.submit(vm.query, force: true) { vm.query = "" }
        return true
    }

    /// ⇥ indents, as in any code editor; the palette's own ring has nothing to offer here.
    func tab(at selection: Int, backwards: Bool) -> Bool {
        coordinator.indent(backwards: backwards)
        return true
    }

    func move(_ delta: Int, axis: PaletteAxis, from selection: Int) -> Int? {
        guard axis == .vertical else { return nil }
        coordinator.recallHistory(older: delta < 0)
        return selection
    }

    func perform(_ shortcut: PaletteShortcut, at selection: Int) -> Bool {
        switch shortcut {
        case .pin where coordinator.isRunning: coordinator.interrupt()
        case .restart: coordinator.restart()
        case .newItem: coordinator.clear()
        case .copyFile where coordinator.lastOutput != nil: coordinator.copyLastOutput()
        case .settings: coordinator.showSettings()
        default: return false
        }
        return true
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        var items: [PopoverMenuItem] = []
        if coordinator.isRunning {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Interrupt"), systemImage: "stop.fill", shortcut: "⌘."
                ) {
                    coordinator.interrupt()
                })
        }
        items.append(
            PopoverMenuItem(
                title: String(localized: "Run Now"), systemImage: "play.fill",
                shortcut: "⌘↵"
            ) {
                if coordinator.submit(vm.query, force: true) { vm.query = "" }
            })
        if coordinator.lastOutput != nil {
            items.append(
                PopoverMenuItem(
                    title: String(localized: "Copy Last Output"), systemImage: "doc.on.doc",
                    startsSection: true, shortcut: "⇧⌘C"
                ) {
                    coordinator.copyLastOutput()
                })
        }
        items.append(
            PopoverMenuItem(
                title: String(localized: "Clear Cells"), systemImage: "eraser",
                startsSection: coordinator.lastOutput == nil, shortcut: "⌘N"
            ) {
                coordinator.clear()
            })
        items.append(
            PopoverMenuItem(
                title: String(localized: "Restart Python"), systemImage: "arrow.clockwise", shortcut: "⌘R"
            ) {
                coordinator.restart()
            })
        items.append(
            PopoverMenuItem(
                title: String(localized: "Python Settings"), systemImage: "slider.horizontal.3",
                startsSection: true, shortcut: "⌥⌘,"
            ) {
                coordinator.showSettings()
            })
        return PopoverMenuContent(header: String(localized: "Python"), items: items)
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(PythonNotebookView(coordinator: coordinator))
    }
}

private struct PythonNotebookView: View {
    @Environment(\.metrics) private var metrics
    let coordinator: PythonCoordinator
    @State private var followsTail = true

    private var notebook: PythonNotebook { coordinator.notebook }

    /// Anything that grows the page, so the view can follow it down while the reader is at the end.
    private var growth: Int {
        notebook.cells.reduce(notebook.cells.count + coordinator.pendingLines.count) {
            $0 &+ $1.outputCharacters &+ ($1.result?.count ?? 0) &+ ($1.failure == nil ? 0 : 1)
                &+ ($1.isRunning ? 0 : 7)
        }
    }

    var body: some View {
        if notebook.cells.isEmpty, coordinator.pendingLines.isEmpty {
            PythonEmptyState(coordinator: coordinator)
        } else {
            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: metrics.spacing.lg) {
                    PythonStatusLine(coordinator: coordinator)
                    ForEach(notebook.cells) { cell in
                        PythonCellView(cell: cell, onInterrupt: coordinator.interrupt, onCopy: coordinator.copy)
                            .id(cell.id)
                        if let divider = notebook.dividers.first(where: { $0.afterCell == cell.id }) {
                            PythonDividerView(text: divider.text)
                        }
                    }
                    if !coordinator.pendingLines.isEmpty {
                        PythonPendingBlockView(lines: coordinator.pendingLines)
                    }
                    Color.clear.frame(height: metrics.spacing.xxs).id(Self.tail)
                }
                .padding(.top, metrics.spacing.lg)
                .padding(.bottom, metrics.spacing.chatTranscriptBottom)
                .padding(.horizontal, metrics.spacing.xxl)
                .frame(maxWidth: .infinity)
            }
            .edgeDissolve()
            .thinScrollbar()
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height + geometry.contentInsets.top
                    >= geometry.contentSize.height - metrics.spacing.chatFollowTailSlack
            } action: { _, atEnd in
                followsTail = atEnd
            }
            .onChange(of: notebook.cells.count) {
                followsTail = true
                proxy.scrollTo(Self.tail, anchor: .bottom)
            }
            .onChange(of: growth) {
                guard followsTail else { return }
                proxy.scrollTo(Self.tail, anchor: .bottom)
            }
        }
    }

    private static let tail = "python-transcript-tail"
}

/// Which interpreter answers, and why it no longer does once its session has ended.
private struct PythonStatusLine: View {
    @Environment(\.metrics) private var metrics
    let coordinator: PythonCoordinator

    var body: some View {
        HStack(spacing: metrics.spacing.sm) {
            Text(PythonEmptyState.title(for: coordinator.notebook.status))
            if let path = coordinator.interpreter?.path {
                Text(verbatim: path).truncationMode(.middle)
            }
        }
        .lineLimit(1)
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textTertiary)
    }
}

private struct PythonEmptyState: View {
    @Environment(\.metrics) private var metrics
    let coordinator: PythonCoordinator

    static func title(for status: PythonNotebook.Status) -> String {
        switch status {
        case .idle, .starting: return String(localized: "Starting Python…")
        case .ready(let version): return String(localized: "Python \(version)")
        case .ended(let reason): return reason
        }
    }

    private var hasFailed: Bool {
        if case .ended = coordinator.notebook.status { return coordinator.interpreter == nil }
        return false
    }

    var body: some View {
        VStack(spacing: metrics.spacing.md) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(metrics.typography.calcResult)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(Self.title(for: coordinator.notebook.status))
                .font(metrics.typography.rowTitle)
                .foregroundStyle(hasFailed ? Theme.Colors.destructive : Theme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            if let path = coordinator.interpreter?.path {
                Text(verbatim: path)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if hasFailed {
                Button(String(localized: "Python Settings"), action: coordinator.showSettings)
            } else {
                Text("↵ runs a line  ·  ⌘↵ runs it now  ·  ⌘. interrupts  ·  ⌘R restarts")
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
        }
        .padding(metrics.spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One run as a native block: the code, then what it printed, its value and any error.
private struct PythonCellView: View {
    @Environment(\.metrics) private var metrics
    let cell: PythonCell
    let onInterrupt: () -> Void
    let onCopy: (String) -> Void

    /// SwiftUI lays a megabyte of text out in one pass, so the block shows a head and says so.
    static let displayLimit = 20_000

    private var hasOutput: Bool {
        !cell.outputs.isEmpty || cell.result != nil || cell.failure != nil || cell.droppedCharacters > 0
            || hiddenCharacters > 0
    }

    private var hiddenCharacters: Int {
        max(cell.outputCharacters - Self.displayLimit, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            code
            if hasOutput {
                Rectangle().fill(Theme.Colors.cardStroke).frame(height: 1)
                output
            }
        }
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
                .fill(Theme.Colors.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.cardStroke))
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous))
    }

    private var code: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.md) {
            Text(verbatim: cell.number.map { "[\($0)]" } ?? "[ ]")
                .font(metrics.typography.keyCap)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(verbatim: cell.code)
                .font(metrics.typography.code)
                .foregroundStyle(Theme.Colors.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            PythonCellStatus(cell: cell, onInterrupt: onInterrupt)
            PythonCopyButton(help: String(localized: "Copy Code")) { onCopy(cell.code) }
        }
        .padding(metrics.spacing.lg)
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            ForEach(Array(visibleOutputs.enumerated()), id: \.offset) { _, block in
                Text(verbatim: block.text.hasSuffix("\n") ? String(block.text.dropLast()) : block.text)
                    .font(metrics.typography.code)
                    .foregroundStyle(block.stream == .stderr ? Theme.Colors.warning : Theme.Colors.textSecondary)
                    .textSelection(.enabled)
            }
            if let result = cell.result {
                Text(verbatim: cell.resultTruncated ? result + "…" : result)
                    .font(metrics.typography.code)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .textSelection(.enabled)
            }
            if let failure = cell.failure {
                PythonFailureView(failure: failure)
            }
            let omitted = cell.droppedCharacters + hiddenCharacters
            if omitted > 0 {
                HStack(spacing: metrics.spacing.sm) {
                    Text("\(omitted.formatted()) more characters not shown")
                    PythonCopyButton(help: String(localized: "Copy Output")) {
                        onCopy(cell.outputs.map(\.text).joined())
                    }
                }
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .padding(metrics.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.controlSurface.opacity(0.35))
    }

    /// The first `displayLimit` characters, cut at a block boundary or inside the last one.
    private var visibleOutputs: [PythonCell.Output] {
        var room = Self.displayLimit
        var shown: [PythonCell.Output] = []
        for block in cell.outputs where room > 0 {
            let text = block.text.count > room ? String(block.text.prefix(room)) : block.text
            room -= text.count
            shown.append(PythonCell.Output(stream: block.stream, text: text))
        }
        return shown
    }
}

private struct PythonCellStatus: View {
    @Environment(\.metrics) private var metrics
    let cell: PythonCell
    let onInterrupt: () -> Void

    var body: some View {
        Group {
            switch cell.state {
            case .running:
                HStack(spacing: metrics.spacing.sm) {
                    ProgressView().controlSize(.small)
                    Button(String(localized: "Interrupt"), action: onInterrupt)
                        .buttonStyle(.link)
                        .help(String(localized: "Interrupt  ⌘."))
                }
            case .succeeded:
                Text(verbatim: Self.duration(cell.seconds ?? 0))
                    .foregroundStyle(Theme.Colors.textTertiary)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.Colors.destructive)
            case .interrupted:
                Image(systemName: "stop.circle.fill").foregroundStyle(Theme.Colors.warning)
            case .ended:
                Image(systemName: "power.circle.fill").foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .font(metrics.typography.rowTrailing)
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 1 {
            return Duration.milliseconds(Int((seconds * 1000).rounded()))
                .formatted(.units(allowed: [.milliseconds], width: .narrow))
        }
        return Duration.milliseconds(Int((seconds * 1000).rounded()))
            .formatted(.units(allowed: [.minutes, .seconds], width: .narrow, fractionalPart: .show(length: 1)))
    }
}

/// The exception's one line, with its traceback folded behind it until asked for.
private struct PythonFailureView: View {
    @Environment(\.metrics) private var metrics
    let failure: PythonFailure
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Button {
                expanded.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(metrics.typography.disclosure)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(verbatim: failure.summary)
                        .font(metrics.typography.code)
                        .foregroundStyle(failure.isInterruption ? Theme.Colors.warning : Theme.Colors.destructive)
                        .multilineTextAlignment(.leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(failure.traceback.isEmpty)
            .help(expanded ? String(localized: "Hide Traceback") : String(localized: "Show Traceback"))
            if expanded {
                Text(verbatim: failure.traceback.trimmingCharacters(in: .newlines))
                    .font(metrics.typography.code)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The unfinished block above the prompt, dashed because none of it has run yet.
private struct PythonPendingBlockView: View {
    @Environment(\.metrics) private var metrics
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Text(verbatim: lines.joined(separator: "\n"))
                .font(metrics.typography.code)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text("An empty line runs the block; ⌘↵ runs it now, ⎋ discards it.")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(metrics.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
                .strokeBorder(Theme.Colors.cardStroke, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

private struct PythonDividerView: View {
    @Environment(\.metrics) private var metrics
    let text: String

    var body: some View {
        HStack(spacing: metrics.spacing.md) {
            line
            Text(verbatim: text).fixedSize()
            line
        }
        .font(metrics.typography.rowTrailing)
        .foregroundStyle(Theme.Colors.textTertiary)
    }

    private var line: some View {
        Rectangle().fill(Theme.Colors.separator).frame(height: 1)
    }
}

private struct PythonCopyButton: View {
    @Environment(\.metrics) private var metrics
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
