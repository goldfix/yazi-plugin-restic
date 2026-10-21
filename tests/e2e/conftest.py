"""Fixtures: a real restic repository, an isolated Yazi config that loads this plugin, and a driver."""

import glob
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from .driver import YaziDriver

ROOT = Path(__file__).resolve().parents[2]
# E2E_PLUGIN_DIR points the tests at an installed build (package smoke test) instead of the sources.
PLUGIN_DIR = Path(os.environ.get("E2E_PLUGIN_DIR") or ROOT / "restic.yazi")
PASSWORD = "secret"

KEYMAP = """
[[mgr.prepend_keymap]]
on  = "<Enter>"
run = "plugin restic -- enter"

[[mgr.prepend_keymap]]
on  = [ "r", "e" ]
run = "plugin restic -- restore"

[[mgr.prepend_keymap]]
on  = "H"
run = "plugin restic -- leave"

[[mgr.prepend_keymap]]
on  = [ "r", "b" ]
run = "plugin restic -- back"

[[mgr.prepend_keymap]]
on  = [ "r", "v" ]
run = "plugin restic -- version"
"""

YAZI_TOML = """
[plugin]
prepend_previewers = [ { url = "/tmp/yazi-restic-*/**", run = "restic" } ]
prepend_spotters = [
  { url = "/tmp/yazi-restic-*/**", run = "restic" },
  { url = "/tmp/yazi-restic-*/**/", run = "restic" },
  { url = "*.restic", run = "restic" },
]

[opener]
logopen = [ { run = 'echo "OPENED $(basename %s1) $(wc -c < %s1 | tr -d " ")" >> "$E2E_OPEN_LOG"', desc = "log" } ]

[open]
prepend_rules = [ { url = "*", use = "logopen" } ]
"""


def _restic(repo: Path, *args: str, cwd: Path | None = None) -> None:
    subprocess.run(["restic", "-r", str(repo), *args], check=True, cwd=cwd, capture_output=True, env=dict(os.environ, RESTIC_PASSWORD=PASSWORD))


@pytest.fixture
def workspace(tmp_path):
    """tmp/work/{demo.restic, repo/} with one snapshot of data/{a.txt, docs/{report.md, blob.bin}}."""
    src, work = tmp_path / "src", tmp_path / "work"
    (src / "data" / "docs").mkdir(parents=True)
    (src / "data" / "a.txt").write_text("hello\n")
    (src / "data" / "docs" / "report.md").write_text("# report\n")
    (src / "data" / "docs" / "blob.bin").write_bytes(os.urandom(3000))
    work.mkdir()
    _restic(work / "repo", "init")
    _restic(work / "repo", "backup", "data", "--tag", "e2e", cwd=src)  # relative path => backup paths start at /data
    (work / "demo.restic").write_text("repository = ./repo\n")
    return work


@pytest.fixture
def yazi(tmp_path, workspace, monkeypatch):
    config, state = tmp_path / "config", tmp_path / "state"
    (config / "plugins").mkdir(parents=True)
    (config / "plugins" / "restic.yazi").symlink_to(PLUGIN_DIR)
    (config / "init.lua").write_text('require("restic"):setup()\n')
    (config / "keymap.toml").write_text(KEYMAP)
    (config / "yazi.toml").write_text(YAZI_TOML)
    monkeypatch.setenv("E2E_OPEN_LOG", str(tmp_path / "open.log"))

    before = set(glob.glob("/tmp/yazi-restic-*/*"))
    driver = YaziDriver(workspace, config, state)
    driver.open_log = tmp_path / "open.log"
    yield driver
    driver.close()
    for leftover in set(glob.glob("/tmp/yazi-restic-*/*")) - before:
        shutil.rmtree(leftover, ignore_errors=True)


@pytest.fixture
def repo_open(yazi):
    """Yazi with the demo repository opened and the cursor on the (only) snapshot directory."""
    yazi.send("j")  # demo.restic (the `repo` folder sorts first)
    yazi.send("\r")
    yazi.wait_for("Repository password")
    yazi.send(f"{PASSWORD}\r")
    yazi.wait_for("latest")
    return yazi


@pytest.fixture
def in_data(repo_open):
    """Yazi inside `<snapshot>/data`, whose content (docs/, a.txt) is already listed."""
    repo_open.wait_for("data")  # hover expansion lists the snapshot for the preview pane
    repo_open.send("l")
    repo_open.wait_cwd("[e2e]")
    repo_open.wait_for("docs")  # hover expansion lists `data` for the preview pane
    repo_open.send("l")
    repo_open.wait_cwd("/data")
    return repo_open
