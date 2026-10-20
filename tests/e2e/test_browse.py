"""End-to-end scenarios (acceptance table of AGENTS.md) against a real Yazi and a real restic repository."""

import os
import shutil
from pathlib import Path

import pytest

SFTP_SERVER = next((p for p in ("/usr/libexec/sftp-server", "/usr/lib/openssh/sftp-server", "/usr/lib/ssh/sftp-server") if Path(p).exists()), None)


def test_wrong_password_reports_error_and_stays_put(yazi):
    yazi.send("j")
    yazi.send("\r")
    yazi.wait_for("Repository password")
    yazi.send("not-the-password\r")
    screen = yazi.wait_for("wrong password")
    assert "yazi-restic" not in screen.splitlines()[0]  # still in the original folder


def test_cancelled_prompt_does_nothing(yazi):
    yazi.send("j")
    yazi.send("\r")
    yazi.wait_for("Repository password")
    yazi.send("\x1b", settle=0.5)  # Esc leaves insert mode...
    yazi.send("\x1b", settle=0.5)  # ...and a second Esc cancels the input
    screen = yazi.text
    assert "Repository password" not in screen
    assert "yazi-restic" not in screen.splitlines()[0]


def test_password_prompt_is_masked(yazi):
    yazi.send("j")
    yazi.send("\r")
    yazi.wait_for("Repository password")
    yazi.send("topsecret", settle=0.5)
    assert "topsecret" not in yazi.text


def test_ghost_root_lists_snapshots_and_expands_lazily(repo_open):
    screen = repo_open.text
    assert screen.splitlines()[0].startswith("/tmp/yazi-restic-")
    assert "latest" in screen
    repo_open.wait_for("data")  # preview of the hovered snapshot shows its first level (hover expansion)


def test_entering_a_folder_expands_it_and_drops_the_marker(in_data):
    screen = in_data.wait_for("a.txt")
    assert "docs" in screen
    assert ".unfetched" not in screen


def test_hover_shows_backup_metadata(in_data):
    in_data.send("j")  # a.txt
    screen = in_data.wait_for("Backup path: /data/a.txt")
    assert "Type: file" in screen
    assert "Size: 6B (6 bytes)" in screen
    assert "-rw-r--r--" in screen
    assert "Local copy: no" in screen


def test_enter_fetches_a_placeholder_then_opens_it(in_data):
    in_data.send("j")
    in_data.wait_for("Backup path: /data/a.txt")
    in_data.send("\r")
    in_data.wait_for("Local copy: yes")
    for _ in range(50):
        if in_data.open_log.exists():
            break
        in_data.send("", settle=0.1)
    assert "OPENED a.txt 6" in in_data.open_log.read_text()


def test_restore_directory(in_data, tmp_path):
    in_data.wait_for("blob.bin")  # cursor is on docs/: its content shows in the preview
    target = tmp_path / "restored"
    in_data.send("re")
    in_data.wait_for("Restore to:")
    in_data.send("\x15")  # Ctrl-U: clear the suggested destination
    in_data.send(f"{target}\r")
    in_data.wait_for("Restored 1 item(s)")
    assert (target / "data" / "docs" / "report.md").read_text() == "# report\n"
    assert (target / "data" / "docs" / "blob.bin").stat().st_size == 3000


def test_restore_restores_every_selected_entry_not_the_hovered_one(in_data, tmp_path):
    in_data.wait_for("blob.bin")  # cursor is on docs/
    in_data.send(" ")  # Space selects docs/ and moves the cursor down to a.txt...
    in_data.send(" ")  # ...which is selected too; the cursor stays on the last entry
    target = tmp_path / "restored"
    in_data.send("re")
    in_data.wait_for("Restore to:")
    in_data.send("\x15")
    in_data.send(f"{target}\r")
    before = in_data.text
    screen = in_data.wait_for("Restored 2 item(s)")
    assert (target / "data" / "docs" / "report.md").read_text() == "# report\n"
    assert (target / "data" / "a.txt").read_text() == "hello\n"
    assert before.splitlines()[0].rstrip().endswith("data                         2")  # header: 2 selected
    assert screen.splitlines()[0].rstrip().endswith("/data")  # restored: the selection is cleared
    assert "Restoring 2 item(s) from snapshot" in screen  # one restic call for the whole selection


def test_reopening_a_repository_reuses_fetched_files(in_data):
    in_data.send("j")  # a.txt
    in_data.wait_for("Backup path: /data/a.txt")
    in_data.send("\r")
    in_data.wait_for("Local copy: yes")

    workspace = in_data.cwd
    in_data.send("g ")  # interactive cd
    in_data.send(f"{workspace}\r")
    in_data.wait_cwd("/work")
    in_data.wait_for("repository = ./repo")  # Yazi remembers the cursor: the .restic file is hovered already
    in_data.send("\r")
    in_data.wait_for("Repository password")
    in_data.send("secret\r")
    in_data.wait_for("latest")

    in_data.send("l")
    in_data.wait_cwd("[e2e]")
    in_data.wait_for("docs")
    in_data.send("l")
    in_data.wait_cwd("/data")
    # Yazi remembers the cursor, so a.txt is hovered again
    screen = in_data.wait_for("Backup path: /data/a.txt")  # metadata is listed again...
    assert "Local copy: yes" in screen  # ...and the file fetched before is still there


def test_browsing_through_latest_works_like_the_snapshot_dir(repo_open):
    repo_open.wait_for("data")
    repo_open.send("j")  # latest -> <snapshot dir>
    repo_open.send("l")
    repo_open.wait_cwd("/latest")
    repo_open.wait_for("docs")  # hover expansion of latest/data
    repo_open.send("l")
    repo_open.wait_cwd("/latest/data")
    repo_open.send("j")  # a.txt
    repo_open.wait_for("Backup path: /data/a.txt")
    repo_open.send("\r")
    repo_open.wait_for("Local copy: yes")


def test_version_action_reports_the_installed_version(yazi):
    yazi.send("rv")
    yazi.wait_for("restic.yazi 0.0.0")


@pytest.fixture
def sftp_setup(tmp_path, workspace, monkeypatch):
    """Two sftp `.restic` files (default / `ssh_batch_mode = no`) and a `ssh` first on PATH that records its
    arguments and fails like an unknown host key would. Must run before Yazi starts (it inherits the PATH)."""
    (workspace / "sftp-batch.restic").write_text("repository = sftp:bob@example.org:/srv/repo\n")
    (workspace / "sftp-manual.restic").write_text("repository = sftp:bob@example.org:/srv/repo\nssh_batch_mode = no\n")
    bin_dir, log = tmp_path / "fakebin", tmp_path / "ssh.args"
    bin_dir.mkdir()
    script = bin_dir / "ssh"
    script.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{log}"\necho "Host key verification failed." >&2\nexit 255\n')
    script.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    return log


def open_repo_file(yazi, downs):
    yazi.send("j" * downs)  # entries: repo/, demo.restic, sftp-batch.restic, sftp-manual.restic
    yazi.send("\r")
    yazi.wait_for("Repository password")
    yazi.send("secret\r")
    return yazi.wait_for("Host key verification failed")  # ssh's own message, not restic's generic sftp error


def test_sftp_repository_runs_ssh_in_batch_mode_by_default(sftp_setup, yazi):
    screen = open_repo_file(yazi, 2)
    assert "BatchMode=yes" in sftp_setup.read_text()
    assert "ssh-agent" in screen or "ssh cannot ask" in screen  # the hint


def test_ssh_batch_mode_can_be_disabled_in_the_restic_file(sftp_setup, yazi):
    open_repo_file(yazi, 3)
    assert "BatchMode" not in sftp_setup.read_text()


@pytest.fixture
def local_sftp(tmp_path, workspace, monkeypatch):
    """A `ssh` first on PATH that logs its arguments and serves the demo repository through the local
    `sftp-server`, so a whole sftp session works without a network. Must run before Yazi starts."""
    if SFTP_SERVER is None:
        pytest.skip("no sftp-server binary on this machine")
    repo = workspace / "repo"
    (workspace / "sftp-batch.restic").write_text(f"repository = sftp:bob@example.org:{repo}\n")
    (workspace / "sftp-manual.restic").write_text(f"repository = sftp:bob@example.org:{repo}\nssh_batch_mode = no\n")
    bin_dir, log = tmp_path / "localbin", tmp_path / "ssh.calls"
    bin_dir.mkdir()
    script = bin_dir / "ssh"
    script.write_text(f'#!/bin/sh\nprintf "CALL" >> "{log}"\nfor a in "$@"; do printf " %s" "$a" >> "{log}"; done\necho >> "{log}"\nexec {SFTP_SERVER}\n')
    script.chmod(0o755)
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    assert shutil.which("ssh") == str(script)
    return log


def browse_sftp_repo(yazi, downs):
    yazi.send("j" * downs)
    yazi.send("\r")
    yazi.wait_for("Repository password")
    yazi.send("secret\r")
    yazi.wait_for("latest")
    yazi.wait_for("data")  # hover expansion: a second restic call (`ls`) after the one that opened the repository
    yazi.send("l")
    yazi.wait_cwd("[e2e]")
    yazi.wait_for("docs")  # and a third one for the folder below


def test_every_restic_call_of_an_sftp_session_uses_batch_mode(local_sftp, yazi):
    browse_sftp_repo(yazi, 2)
    calls = local_sftp.read_text().splitlines()
    assert len(calls) >= 3, calls  # snapshots + listings: not only the call made while opening the repository
    assert all("BatchMode=yes" in call for call in calls), calls


def test_batch_mode_off_is_honoured_by_every_call_not_only_the_first(local_sftp, yazi):
    browse_sftp_repo(yazi, 3)
    calls = local_sftp.read_text().splitlines()
    assert len(calls) >= 3, calls
    assert not any("BatchMode" in call for call in calls), calls
