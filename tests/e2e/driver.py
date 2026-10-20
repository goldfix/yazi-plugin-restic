"""Drive a real Yazi inside a pseudo terminal and read what it renders (via the `pyte` terminal emulator)."""

import fcntl
import os
import pty
import select
import signal
import struct
import termios
import time
from pathlib import Path

import pyte

ROWS, COLS = 30, 120


class _Screen(pyte.Screen):
    """pyte rejects a few private CSI reports that Yazi emits at startup; ignore them."""

    def report_device_status(self, *args, **kwargs):
        pass

    def report_device_attributes(self, *args, **kwargs):
        pass


class YaziDriver:
    """One Yazi process. `send` types keys, `wait_for` polls the rendered screen."""

    def __init__(self, cwd: Path, config_home: Path, state_home: Path):
        self.cwd = cwd
        env = dict(os.environ, TERM="xterm-256color", YAZI_CONFIG_HOME=str(config_home), XDG_STATE_HOME=str(state_home), YAZI_LOG="debug")
        self.log = state_home / "yazi" / "yazi.log"
        self.screen = _Screen(COLS, ROWS)
        self._stream = pyte.ByteStream(self.screen)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvpe("yazi", ["yazi", str(cwd)], env)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
        self.wait_for("", timeout=5)

    def _pump(self, seconds: float) -> None:
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if not select.select([self.fd], [], [], 0.05)[0]:
                continue
            try:
                data = os.read(self.fd, 65536)
            except OSError:
                return
            if b"\x1b[c" in data or b"\x1b[0c" in data:  # answer terminal capability probes
                os.write(self.fd, b"\x1b[?62;c")
            self._stream.feed(data)

    @property
    def text(self) -> str:
        return "\n".join(line.rstrip() for line in self.screen.display).rstrip()

    def send(self, keys: str, settle: float = 0.3) -> None:
        os.write(self.fd, keys.encode())
        self._pump(settle)

    def wait_for(self, needle: str, timeout: float = 10) -> str:
        """Pump until `needle` is on screen; raise with the screen content otherwise."""
        end = time.monotonic() + timeout
        while True:
            self._pump(0.1)
            if needle in self.text:
                return self.text
            if time.monotonic() > end:
                raise AssertionError(f"{needle!r} not on screen after {timeout}s:\n{self.text}")

    def wait_cwd(self, suffix: str, timeout: float = 10) -> str:
        """Pump until the header line (current directory) ends with `suffix`."""
        end = time.monotonic() + timeout
        while True:
            self._pump(0.1)
            if self.text.splitlines()[0].endswith(suffix):
                return self.text
            if time.monotonic() > end:
                raise AssertionError(f"cwd does not end with {suffix!r} after {timeout}s:\n{self.text}")

    def close(self) -> None:
        # A killed process can hang in `exit` (macOS) until the pty master has drained its pending output, and a
        # blocking waitpid would then freeze the whole test run: keep reading while waiting for it to go away.
        try:
            os.kill(self.pid, signal.SIGKILL)
            deadline = time.monotonic() + 5
            while os.waitpid(self.pid, os.WNOHANG) == (0, 0) and time.monotonic() < deadline:
                self._pump(0.05)
        except OSError:
            pass
        os.close(self.fd)
