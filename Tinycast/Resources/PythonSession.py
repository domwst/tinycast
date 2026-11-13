"""Tinycast's Python session driver.

Tinycast starts this with the user's own `python3` and talks to it over two private pipes: requests
arrive on fd 3 and events leave on fd 4, one JSON object per line. Code the user runs never sees
either, so nothing it prints can be mistaken for a result. Python-level output travels as events,
attributed to the cell that wrote it; output written straight to fd 1 or 2 (a subprocess, a C
extension) reaches Tinycast on the ordinary pipes.
"""

import os
import sys

# The driver's own folder comes first on `sys.path`; nothing of Tinycast's may shadow a module.
if sys.path and os.path.realpath(sys.path[0] or ".") == os.path.dirname(os.path.realpath(__file__)):
    del sys.path[0]

import ast
import builtins
import codeop
import io
import json
import linecache
import signal
import threading
import time
import traceback
import types

REQUESTS_FD = 3
EVENTS_FD = 4
# One cell's printed output past this is dropped, and counted, rather than flooding the window.
OUTPUT_LIMIT = 1_000_000
REPR_LIMIT = 100_000
FLUSH_INTERVAL = 0.05
FLUSH_SIZE = 8192

_emit_lock = threading.Lock()
_running = False
_streams = []


def _clean(text):
    """Lone surrogates have no UTF-8 spelling; replace them so every event decodes."""
    return text.encode("utf-8", "replace").decode("utf-8")


def emit(event):
    data = (json.dumps(event, ensure_ascii=False) + "\n").encode("utf-8")
    with _emit_lock:
        view = memoryview(data)
        while view:
            written = os.write(EVENTS_FD, view)
            view = view[written:]


class CellStream(io.TextIOBase):
    """Stands in for `sys.stdout` or `sys.stderr`, batching writes into events for one cell."""

    def __init__(self, name, fd):
        super().__init__()
        self.name = name
        self._fd = fd
        self._lock = threading.Lock()
        self._parts = []
        self._size = 0
        self._last_flush = time.monotonic()
        self.cell = None
        self.written = 0
        self.dropped = 0

    @property
    def encoding(self):
        return "utf-8"

    def writable(self):
        return True

    def isatty(self):
        return False

    def fileno(self):
        # A subprocess handed `sys.stdout` writes to the real descriptor, which Tinycast also reads.
        return self._fd

    def begin(self, cell):
        with self._lock:
            self.cell = cell
            self.written = 0
            self.dropped = 0

    def write(self, text):
        if not isinstance(text, str):
            raise TypeError("write() argument must be str, not %s" % type(text).__name__)
        with self._lock:
            room = OUTPUT_LIMIT - self.written
            kept = text[: max(room, 0)]
            self.dropped += len(text) - len(kept)
            self.written += len(kept)
            if kept:
                self._parts.append(kept)
                self._size += len(kept)
            due = time.monotonic() - self._last_flush >= FLUSH_INTERVAL
            if self._size >= FLUSH_SIZE or (due and self._parts):
                self._flush_locked()
        return len(text)

    def flush(self):
        with self._lock:
            self._flush_locked()

    def _flush_locked(self):
        self._last_flush = time.monotonic()
        if not self._parts:
            return
        text = "".join(self._parts)
        self._parts = []
        self._size = 0
        emit({"type": "output", "cell": self.cell, "stream": self.name, "text": _clean(text)})


def _flusher(streams):
    """A print followed by a long sleep must still show; writes alone only flush when they come."""
    while True:
        time.sleep(FLUSH_INTERVAL * 2)
        for stream in streams:
            stream.flush()


def _watch_parent(parent):
    """Tinycast closing fd 3 ends an idle driver; one killed mid-cell needs this to notice."""
    while True:
        time.sleep(1)
        if os.getppid() != parent:
            os._exit(0)


def _interrupt(signum, frame):
    # Ctrl-C reaches only the user's code; between cells it must not break the event stream.
    if _running:
        raise KeyboardInterrupt


def _flush_streams():
    """What a cell printed goes out before its value or error, so events arrive in reading order."""
    for stream in _streams:
        stream.flush()


def _error_event(cell, error, skip_driver_frames):
    tb = error.__traceback__
    if skip_driver_frames:
        while tb is not None and not tb.tb_frame.f_code.co_filename.startswith("<cell"):
            tb = tb.tb_next
    lines = traceback.format_exception(type(error), error, tb)
    summary = traceback.format_exception_only(type(error), error)[-1].strip()
    return {
        "type": "error",
        "cell": cell,
        "name": type(error).__name__,
        "summary": _clean(summary),
        "traceback": _clean("".join(lines)),
    }


def _run(cell, number, code, namespace):
    """Runs a cell the way IPython does: every statement, then shows a final expression's value."""
    global _running
    filename = "<cell %d>" % number
    linecache.cache[filename] = (len(code), None, code.splitlines(True), filename)
    try:
        tree = compile(code, filename, "exec", ast.PyCF_ONLY_AST)
    except (SyntaxError, ValueError, OverflowError) as error:
        emit(_error_event(cell, error, skip_driver_frames=False))
        return False
    last = None
    if tree.body and isinstance(tree.body[-1], ast.Expr):
        last = ast.Expression(tree.body.pop().value)
    _running = True
    try:
        exec(compile(tree, filename, "exec"), namespace)
        if last is not None:
            value = eval(compile(last, filename, "eval"), namespace)
            if value is not None:
                builtins._ = value
                text = repr(value)
                _flush_streams()
                truncated = len(text) > REPR_LIMIT
                emit({
                    "type": "result",
                    "cell": cell,
                    "text": _clean(text[:REPR_LIMIT]),
                    "truncated": truncated,
                })
        return True
    except SystemExit:
        raise
    except BaseException as error:
        _running = False
        _flush_streams()
        emit(_error_event(cell, error, skip_driver_frames=True))
        return False
    finally:
        _running = False


def _wants_more(code, force):
    """REPL rules: an open bracket or block asks for more, and a block ends on an empty line."""
    if force:
        return False
    try:
        if codeop.compile_command(code, "<input>", "exec") is None:
            return True
    except (SyntaxError, ValueError, OverflowError):
        return False
    last = code.split("\n")[-1]
    return last[:1] in (" ", "\t") and last.strip() != ""


def main():
    parent = os.getppid()
    for fd in (REQUESTS_FD, EVENTS_FD):
        os.set_inheritable(fd, False)
    requests = io.open(REQUESTS_FD, "rb")

    module = types.ModuleType("__main__")
    module.__builtins__ = builtins
    sys.modules["__main__"] = module
    namespace = module.__dict__
    sys.argv = [""]
    sys.path.insert(0, "")

    stdout = CellStream("stdout", 1)
    stderr = CellStream("stderr", 2)
    sys.stdout = stdout
    sys.stderr = stderr
    _streams.extend([stdout, stderr])
    sys.stdin = io.open(os.devnull, "r")
    signal.signal(signal.SIGINT, _interrupt)
    threading.Thread(target=_flusher, args=([stdout, stderr],), daemon=True).start()
    threading.Thread(target=_watch_parent, args=(parent,), daemon=True).start()

    emit({
        "type": "ready",
        "version": sys.version.split()[0],
        "executable": _clean(sys.executable or ""),
    })

    number = 0
    for line in requests:
        try:
            request = json.loads(line)
            cell = int(request["cell"])
            code = str(request["code"])
        except (ValueError, KeyError, TypeError):
            continue
        if _wants_more(code, bool(request.get("force"))):
            emit({"type": "incomplete", "cell": cell})
            continue
        number += 1
        emit({"type": "started", "cell": cell, "number": number})
        for stream in (stdout, stderr):
            stream.begin(cell)
        started = time.monotonic()
        exit_code = None
        try:
            ok = _run(cell, number, code, namespace)
        except SystemExit as error:
            ok = True
            code_value = error.code
            exit_code = code_value if isinstance(code_value, int) else (0 if code_value is None else 1)
            if code_value is not None and not isinstance(code_value, int):
                print(code_value, file=sys.stderr)
        _flush_streams()
        dropped = stdout.dropped + stderr.dropped
        emit({
            "type": "finished",
            "cell": cell,
            "ok": ok,
            "seconds": round(time.monotonic() - started, 6),
            "dropped": dropped,
        })
        if exit_code is not None:
            emit({"type": "exited", "code": exit_code})
            os._exit(exit_code)
    os._exit(0)


if __name__ == "__main__":
    main()
