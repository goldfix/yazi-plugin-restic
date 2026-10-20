"""Tests of the plugin-release skill: pure helpers, package assembly, install.sh and the release flow."""

import importlib.util
import os
import re
import subprocess
import tarfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SKILL = ROOT / ".agents" / "skills" / "plugin-release"

spec = importlib.util.spec_from_file_location("release", SKILL / "scripts" / "release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

CHANGELOG = """# Changelog

## [Unreleased]

### Added
- something new

## [0.1.0] - 2026-01-01

### Added
- first
"""


def run(*command, cwd, env=None):
    return subprocess.run(command, cwd=cwd, capture_output=True, text=True, check=True, env=env).stdout


@pytest.fixture
def project(tmp_path, monkeypatch):
    """A tiny git repository laid out like the real one (version 0.1.0, one commit)."""
    for key, value in {"NAME": "Test", "EMAIL": "t@example.org"}.items():
        monkeypatch.setenv(f"GIT_AUTHOR_{key}", value)
        monkeypatch.setenv(f"GIT_COMMITTER_{key}", value)
    plugin = tmp_path / "restic.yazi"
    plugin.mkdir()
    (plugin / "main.lua").write_text("return {}\n")
    (plugin / "util.lua").write_text("return {}\n")
    (plugin / "notes.txt").write_text("never shipped\n")
    (plugin / "version.lua").write_text('-- header\nreturn { version = "0.1.0" }\n')
    (tmp_path / "LICENSE").write_text("MIT\n")
    (tmp_path / "README.md").write_text("# the one README\n")
    for name in release.ROOT_COPIES:  # like the real repository: committed symlinks to the root files
        (plugin / name).symlink_to(f"../{name}")
    (tmp_path / "sample_backup.restic").write_text("repository = ./repo\n")
    (tmp_path / "CHANGELOG.md").write_text(CHANGELOG)
    (tmp_path / ".gitignore").write_text("dist/\n")
    run("git", "init", "-q", "-b", "main", cwd=tmp_path)
    run("git", "add", "-A", cwd=tmp_path)
    run("git", "commit", "-qm", "init", cwd=tmp_path)
    return tmp_path


# --- pure helpers ---------------------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("current", "spec_", "expected"),
    [("1.2.3", "patch", "1.2.4"), ("1.2.3", "minor", "1.3.0"), ("1.2.3", "major", "2.0.0"), ("1.2.3", "1.4.0", "1.4.0")],
)
def test_bump(current, spec_, expected):
    assert release.bump(current, spec_) == expected


@pytest.mark.parametrize("bad", ["1.2.3", "1.2.2", "1.0.0", "v2.0.0", "2.0", "latest"])
def test_bump_rejects_non_increasing_or_invalid_versions(bad):
    with pytest.raises(release.ReleaseError):
        release.bump("1.2.3", bad)


def test_read_and_set_version_keep_the_rest_of_the_file():
    text = '-- header\nreturn { version = "0.1.0" }\n'
    assert release.read_version(text) == "0.1.0"
    assert release.set_version(text, "0.2.0") == '-- header\nreturn { version = "0.2.0" }\n'
    with pytest.raises(release.ReleaseError):
        release.read_version("return {}\n")
    with pytest.raises(release.ReleaseError):
        release.read_version('return { version = "banana" }\n')


@pytest.mark.parametrize(
    ("sha", "dirty", "tagged", "expected"),
    [
        ("abc1234", False, True, "1.0.0"),
        ("abc1234", False, False, "1.0.0-dev.abc1234"),
        ("abc1234", True, True, "1.0.0-dev.abc1234.dirty"),
        ("abc1234", True, False, "1.0.0-dev.abc1234.dirty"),
        (None, True, False, "1.0.0-dev.dirty"),
        (None, False, False, "1.0.0-dev"),
    ],
)
def test_build_version(sha, dirty, tagged, expected):
    assert release.build_version("1.0.0", sha, dirty, tagged) == expected


def test_release_changelog_moves_unreleased_notes_and_keeps_history():
    result = release.release_changelog(CHANGELOG, "0.2.0", "2026-02-02")
    assert "## [Unreleased]\n\n## [0.2.0] - 2026-02-02\n\n### Added\n- something new\n\n## [0.1.0] - 2026-01-01" in result
    assert result.endswith("- first\n")
    assert release.changelog_notes(result, "0.2.0") == "### Added\n- something new"
    assert release.changelog_notes(result, "0.1.0") == "### Added\n- first"
    assert release.changelog_notes(result, "9.9.9") == ""


def test_release_changelog_needs_something_to_release():
    once = release.release_changelog(CHANGELOG, "0.2.0", "2026-02-02")
    with pytest.raises(release.ReleaseError, match="empty"):
        release.release_changelog(once, "0.3.0", "2026-03-03")
    with pytest.raises(release.ReleaseError, match="Unreleased"):
        release.release_changelog("# Changelog\n", "0.3.0", "2026-03-03")


def test_release_changelog_works_with_a_single_section():
    result = release.release_changelog("# C\n\n## [Unreleased]\n\n- x\n", "1.0.0", "2026-01-01")
    assert result == "# C\n\n## [Unreleased]\n\n## [1.0.0] - 2026-01-01\n\n- x\n"


# --- package assembly -----------------------------------------------------------------------------------------


def test_validate_sources_requires_what_yazi_requires(project):
    assert release.validate_sources(project) == "0.1.0"
    (project / "LICENSE").unlink()
    with pytest.raises(release.ReleaseError, match=r"LICENSE is missing"):
        release.validate_sources(project)
    (project / "LICENSE").write_text("MIT\n")
    (project / "README.md").unlink()
    with pytest.raises(release.ReleaseError, match=r"README\.md is missing"):
        release.validate_sources(project)
    (project / "README.md").write_text("# the one README\n")
    (project / "restic.yazi" / "LICENSE").unlink()  # a missing or wrong link would break `ya pkg add`
    with pytest.raises(release.ReleaseError, match=r"restic\.yazi/LICENSE must be a symlink to \.\./LICENSE"):
        release.validate_sources(project)
    (project / "restic.yazi" / "LICENSE").write_text("MIT\n")  # a regular copy is wrong too
    with pytest.raises(release.ReleaseError, match="must be a symlink"):
        release.validate_sources(project)
    (project / "restic.yazi" / "LICENSE").unlink()
    (project / "restic.yazi" / "LICENSE").symlink_to("../LICENSE")
    (project / "restic.yazi" / "main.lua").unlink()
    with pytest.raises(release.ReleaseError, match=r"main\.lua is missing"):
        release.validate_sources(project)
    (project / "restic.yazi" / "main.lua").write_text("return {}\n")
    (project / "sample_backup.restic").unlink()
    with pytest.raises(release.ReleaseError, match=r"sample_backup\.restic is missing"):
        release.validate_sources(project)


def test_stage_ships_only_the_whitelisted_files_with_the_stamped_version(project, tmp_path):
    package = release.stage(project, tmp_path / "out", "0.1.0-dev.abc1234")
    assert package.name == "restic.yazi-0.1.0-dev.abc1234"
    shipped = sorted(p.name for p in (package / "restic.yazi").iterdir())
    assert shipped == ["LICENSE", "README.md", "main.lua", "util.lua", "version.lua"]
    assert (package / "restic.yazi" / "README.md").read_text() == "# the one README\n"  # copy of the root README
    assert (package / "restic.yazi" / "LICENSE").read_text() == "MIT\n"  # copy of the root LICENSE
    for name in ("README.md", "LICENSE"):
        assert not (package / "restic.yazi" / name).is_symlink()  # the package holds real files
    assert (package / "restic.yazi" / "version.lua").read_text() == '-- header\nreturn { version = "0.1.0-dev.abc1234" }\n'
    assert (project / "restic.yazi" / "version.lua").read_text() == '-- header\nreturn { version = "0.1.0" }\n'  # source untouched
    assert os.access(package / "install.sh", os.X_OK)
    assert (package / "sample_backup.restic").read_text() == "repository = ./repo\n"


def test_archive_is_reproducible_and_checksummed(project, tmp_path):
    package = release.stage(project, tmp_path / "out", "0.1.0")
    first = release.make_archive(package)
    digest = first.read_bytes()
    release.stage(project, tmp_path / "out", "0.1.0")  # rebuilt later, new mtimes
    assert release.make_archive(package).read_bytes() == digest

    with tarfile.open(first) as tar:
        names = tar.getnames()
    assert names[0] == "restic.yazi-0.1.0"
    assert "restic.yazi-0.1.0/restic.yazi/main.lua" in names
    assert "restic.yazi-0.1.0/install.sh" in names
    assert "restic.yazi-0.1.0/sample_backup.restic" in names

    checksum = release.write_checksum(first)
    out = run("shasum", "-a", "256", "-c", checksum.name, cwd=first.parent)
    assert "OK" in out


def test_latest_link_follows_the_newest_build(project, tmp_path):
    for version in ("0.1.0", "0.2.0"):
        release.link_latest(release.stage(project, tmp_path / "out", version))
    assert (tmp_path / "out" / "latest").readlink().as_posix() == "restic.yazi-0.2.0"


# --- install.sh -----------------------------------------------------------------------------------------------


def test_install_script_installs_replaces_and_respects_symlinks(project, tmp_path):
    package = release.stage(project, tmp_path / "out", "0.1.0")
    config = tmp_path / "yazi-config"
    env = dict(os.environ, YAZI_CONFIG_HOME=str(config))
    target = config / "plugins" / "restic.yazi"

    out = run("sh", str(package / "install.sh"), cwd=tmp_path, env=env)
    assert "Installed restic.yazi 0.1.0" in out
    assert str(package / "sample_backup.restic") in out
    assert (target / "main.lua").is_file()

    (target / "stale.lua").write_text("old\n")
    run("sh", str(package / "install.sh"), cwd=tmp_path, env=env)
    assert not (target / "stale.lua").exists()

    run("rm", "-rf", str(target), cwd=tmp_path)
    target.symlink_to(project / "restic.yazi")
    result = subprocess.run(["sh", str(package / "install.sh")], capture_output=True, text=True, env=env, check=False)
    assert result.returncode == 1
    assert "symlink" in result.stderr
    assert (project / "restic.yazi" / "main.lua").is_file()  # the checkout behind the link is intact


def test_install_script_warns_when_ya_pkg_manages_the_plugin(project, tmp_path):
    package = release.stage(project, tmp_path / "out", "0.1.0")
    config = tmp_path / "yazi-config"
    config.mkdir()
    env = dict(os.environ, YAZI_CONFIG_HOME=str(config))

    def install():
        return subprocess.run(["sh", str(package / "install.sh")], capture_output=True, text=True, env=env, check=False)

    assert "warning" not in install().stderr  # nothing managed: silent
    (config / "package.toml").write_text('[[plugin.deps]]\nuse = "other/plugins:git"\nrev = "abc"\n')
    assert "warning" not in install().stderr  # other packages do not matter
    (config / "package.toml").write_text('[[plugin.deps]]\nuse = "goldfix/yazi-plugin-restic:restic"\nrev = "abc"\n')
    result = install()
    assert result.returncode == 0  # a warning, not a refusal
    assert "managed by 'ya pkg'" in result.stderr
    assert (config / "plugins" / "restic.yazi" / "main.lua").is_file()


def test_install_script_refuses_to_run_outside_a_build(tmp_path):
    script = tmp_path / "install.sh"
    script.write_text((SKILL / "assets" / "install.sh").read_text())
    result = subprocess.run(["sh", str(script)], capture_output=True, text=True, env=dict(os.environ, YAZI_CONFIG_HOME=str(tmp_path / "c")), check=False)
    assert result.returncode == 1
    assert "not found" in result.stderr


# --- commands -------------------------------------------------------------------------------------------------


def test_build_labels_untagged_and_dirty_trees_as_dev(project):
    assert release.main(["build", "--skip-checks"], root=project) == 0
    sha = run("git", "rev-parse", "--short", "HEAD", cwd=project).strip()
    assert (project / "dist" / f"restic.yazi-0.1.0-dev.{sha}" / "restic.yazi" / "main.lua").is_file()

    (project / "restic.yazi" / "main.lua").write_text("return { changed = true }\n")
    release.main(["build", "--skip-checks"], root=project)
    assert (project / "dist" / f"restic.yazi-0.1.0-dev.{sha}.dirty").is_dir()
    assert (project / "dist" / "latest").readlink().as_posix() == f"restic.yazi-0.1.0-dev.{sha}.dirty"


def test_release_dry_run_changes_nothing(project, capsys):
    assert release.main(["release", "minor", "--dry-run"], root=project) == 0
    assert "0.1.0 -> 0.2.0" in capsys.readouterr().out
    assert run("git", "status", "--porcelain", cwd=project) == ""
    assert run("git", "tag", cwd=project) == ""
    assert not (project / "dist").exists()


def test_release_bumps_commits_tags_and_builds_a_clean_version(project):
    assert release.main(["release", "minor", "--skip-checks"], root=project) == 0
    assert release.validate_sources(project) == "0.2.0"
    assert "## [0.2.0] -" in (project / "CHANGELOG.md").read_text()
    assert run("git", "log", "-1", "--format=%s", cwd=project).strip() == "Release v0.2.0"
    assert run("git", "tag", cwd=project).split() == ["v0.2.0"]
    assert "something new" in run("git", "tag", "-n20", "-l", "v0.2.0", cwd=project)
    assert run("git", "status", "--porcelain", cwd=project) == ""

    built = project / "dist" / "restic.yazi-0.2.0"  # tagged + clean => no -dev suffix
    assert (built / "restic.yazi" / "version.lua").read_text() == '-- header\nreturn { version = "0.2.0" }\n'
    assert (project / "dist" / "restic.yazi-0.2.0.tar.gz.sha256").is_file()


def test_release_refuses_dirty_trees_empty_changelogs_and_repeated_versions(project, capsys):
    (project / "restic.yazi" / "main.lua").write_text("return { dirty = true }\n")
    assert release.main(["release", "patch", "--skip-checks"], root=project) == 1
    assert "uncommitted" in capsys.readouterr().err
    run("git", "checkout", "restic.yazi/main.lua", cwd=project)

    assert release.main(["release", "patch", "--skip-checks"], root=project) == 0
    assert release.main(["release", "patch", "--skip-checks"], root=project) == 1
    assert "empty" in capsys.readouterr().err

    assert release.main(["release", "0.0.9", "--skip-checks"], root=project) == 1
    assert "greater" in capsys.readouterr().err
    assert run("git", "tag", cwd=project).split() == ["v0.1.1"]


def test_a_failing_check_stops_the_release_before_anything_is_modified(project, monkeypatch, capsys):
    def failing(*_):
        raise release.ReleaseError("check failed: busted")

    monkeypatch.setattr(release, "run_checks", failing)
    assert release.main(["release", "patch"], root=project) == 1
    assert "check failed" in capsys.readouterr().err
    assert run("git", "status", "--porcelain", cwd=project) == ""
    assert run("git", "tag", cwd=project) == ""


# --- the real repository --------------------------------------------------------------------------------------


def test_the_real_plugin_is_packageable():
    """Guards the repository itself: Yazi's required files (README/LICENSE as symlinks to the root), a valid version."""
    version = release.validate_sources(ROOT)
    assert re.fullmatch(r"\d+\.\d+\.\d+", version)
    assert "## [Unreleased]" in (ROOT / "CHANGELOG.md").read_text()
    assert "main.lua" in {p.name for p in release.package_files(ROOT)}
    for name in release.ROOT_COPIES:
        assert (ROOT / name).is_file()
        assert str((ROOT / "restic.yazi" / name).readlink()) == f"../{name}"
        tracked = run("git", "ls-files", "-s", f"restic.yazi/{name}", cwd=ROOT)
        assert not tracked or tracked.startswith("120000 ")  # committed as a git symlink (mode 120000), never a copy
