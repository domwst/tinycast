# Python

A Python prompt in the launcher. Typing `py` (or `python`) and ↵ opens a palette screen with the
session's cells above a `>>>` input cell: each run is one native block holding its code, what it
printed, the value of its last expression and any error. `py 2**64` and ↵ opens the
screen and runs that line. The session keeps its variables between openings of the launcher. The
feature lives in `Features/Python/`, plus the driver at `Resources/PythonSession.py`.

## Invariants

- **The interpreter is the user's, in its own process.** Tinycast embeds no Python. It starts the
  `python3` it finds with `Resources/PythonSession.py` and talks to it over two private pipes, fd 3
  for requests and fd 4 for events, so a crash, `ctypes` or `os.chdir` in the user's code can never
  reach Tinycast. The child leads its own session, so a stop reaches every subprocess it started.
- **Only typed code runs.** No deep link, quicklink, snippet, extension or AI tool can send code to the
  session. `command/python` opens the screen, and with any `fallbackText` it refuses to open at all,
  so a link can never leave code one Return from running. `runInPython` is query-driven, so it has no
  link and no hotkey either.
- **Code runs on Return, never as it is typed.** Running each keystroke would run half a statement:
  `open("notes.txt", "w")` empties the file before the line is finished. The launcher's `py <code>`
  row only offers the run.
- **Off until switched on, and never by a file.** `pythonEnabled` and `pythonInterpreterPath` have no
  `SettingsFileKey` and are `deliberatelyExcluded` from backups: one arms a code runner, the other
  names a program to execute. The Nix module may set both, since that is the owner's own config.
- **Nothing is kept.** Cells and input history live in memory only, are never logged and never written
  to disk, and go when Tinycast quits or Clear Cells runs.
- **Return never interrupts.** A line typed ahead must not cost the cell it was typed under; ⌘. and the
  running cell's Interrupt button are the only ways to send Ctrl-C.

## Layout

| File | Role |
| --- | --- |
| `Resources/PythonSession.py` | The driver: runs cells, judges unfinished input, reports events |
| `Model/PythonProtocol.swift` | Requests and events as JSON lines, the line splitter and UTF-8 decoder |
| `Model/PythonNotebook.swift` | Cells, dividers and input history folded from events, with their caps |
| `Model/PythonInput.swift` | The input's editing rules, trimming a block, and `py <code>` in the launcher |
| `Service/PythonProcess.swift` | `posix_spawn` with the four pipes, the readers, interrupt and stop |
| `Service/PythonInterpreterLocator.swift` | Which `python3`: the setting, the login shell's, or a known path |
| `UI/PythonCoordinator.swift` | Owns the session, the prompt's unfinished block and the idle stop |
| `UI/PythonScreen.swift` | The palette screen and the cell, divider and empty-state views |

## The driver

`PythonSession.py` drops its own folder from `sys.path` before importing anything, so a `json.py` in
the working folder (the user's home) can't stand in for the stdlib's; only then does it put `''` back,
as the REPL has it. It runs each cell the way IPython does: every statement, then the value of a final
expression, shown with `repr` and kept as `_`. Python-level `print` goes through stand-ins for
`sys.stdout` and `sys.stderr` that batch writes into `output` events for the cell, flushed before its
result or error, so events arrive in reading order. Output written straight to fd 1 or 2 (a subprocess,
a C extension) arrives on the ordinary pipes and joins whichever cell ran last. `input()` reads
`/dev/null` and raises `EOFError` instead of hanging. A cell's output past 1,000,000 characters is
dropped and counted, and a value's `repr` is cut at 100,000.

SIGINT raises `KeyboardInterrupt` only while user code runs; between cells it is ignored, so a late
Ctrl-C can't break the event stream. `exit()` ends the session with its status. The driver exits when
fd 3 closes, and a watcher thread exits it if Tinycast dies mid-cell.

## The prompt

The header's search field is one line and its height is fixed, so the screen hides it, as the
snippet editor does, and draws its own input cell under the cells: a multi-line `TextField` that grows
to twelve lines and holds a whole block. It claims the palette's editing flag while it is up, so a bare
⌫ edits it instead of leaving the screen, and its own key handlers run before the palette's.

↵ sends the whole input. The driver answers `incomplete` when `codeop` says the code isn't finished,
or when the last line is indented: a block ends on an empty line, as at a `...` prompt. The input then
gains a newline in place, indented as its last line, one level deeper after a `:`, and only a run the
driver has started clears it, so a submission that never ran stays put. ⇧↵ always breaks the line at
the caret the same way, ⌘↵ runs whatever is there without asking for more, ⇥ and ⇧⇥ indent and
outdent, and a paste keeps its lines. ↑ on the first line and ↓ on the last walk whole cells of
history; anywhere else they move the caret. ⎋ leaves the screen with the input kept for next time. The
rules themselves are pure functions on `PythonInput`, which the harness checks.

## The session

One session at a time. It starts when the screen opens, so the first line never waits on the shell
lookup, and anything sent before it is up waits in `queued`. It ends on Restart (⌘R), after 15 idle
minutes, when Python is switched off, at quit, or when the interpreter exits or crashes; a divider then
marks where the next run's fresh interpreter begins. A submission that never ran goes back to the
field.

The interpreter is `pythonInterpreterPath` when set, else the `python3` a login, interactive zsh finds
(as Load Shell Environment does), else Homebrew's, else `/usr/bin/python3` only when the developer
tools are installed: without them that stub asks to install them. The child gets the login shell's
`PATH`, since launchd's is minimal. A change to the path applies at the next start.

## Rendering

A cell is a card with its run number, code, status and copy button, and below a rule its output:
printed text in the secondary colour, stderr in the warning colour, the value in the primary colour,
and an error's summary with its traceback folded behind a disclosure. Each cell shows at most 20,000
characters of output, since SwiftUI lays a megabyte out in one pass; Copy Output takes everything
kept. The transcript follows its tail while the reader is at the end, as AI's does.

## Settings and Nix

Settings → General → Python holds the switch and the interpreter path. The nix-darwin module's
`programs.tinycast.python = { enable = true; package = pkgs.python3.withPackages (…); }` writes both
into the release build's preferences at each activation, through `defaults` as `system.primaryUser`.
Left at `enable = false`, it leaves the choice made in Settings alone. Tinycast reads preferences at
launch, so a running copy sees the change after it restarts.

## Testing

`python-session-test` compiles the model and service and drives the real driver with the first
`python3` on the harness's `PATH` (it skips the live half when there is none): results, continuation,
state between cells, output ordering, raw fd output, `input()`, a printed JSON line that must stay
output, Ctrl-C, the output cap, `exit()`, and a stop that must take a child `sleep` with it.
