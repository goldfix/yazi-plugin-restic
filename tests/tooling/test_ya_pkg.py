"""`ya pkg add` against the real plugin folder, with a local git repository standing in for GitHub.

`ya pkg` hardcodes `https://github.com/<owner>/<repo>.git`; a throw-away gitconfig (`url.<dir>.insteadOf`) redirects
that to a bare repository in a temp dir, so the real `ya` and `git` run the real code path without any network.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
USE = "goldfix/yazi-plugin-restic:restic"

pytestmark = pytest.mark.skipif(not (shutil.which("ya") and shutil.which("git")), reason="needs ya and git")


def sh(*command, cwd, env):
    return subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True, check=False)


@pytest.fixture
def world(tmp_path):
    """(source repo dir, environment, config dir): `source` mirrors the shipped files of the real repository."""
    gitconfig = tmp_path / "gitconfig"
    gitconfig.write_text(
        f'[url "file://{tmp_path}/remote/"]\n\tinsteadOf = https://github.com/\n[user]\n\tname = t\n\temail = t@example.org\n[init]\n\tdefaultBranch = main\n'
    )
    config = tmp_path / "config"
    env = dict(
        os.environ,
        GIT_CONFIG_GLOBAL=str(gitconfig),
        GIT_CONFIG_NOSYSTEM="1",
        YAZI_CONFIG_HOME=str(config),
        XDG_CACHE_HOME=str(tmp_path / "cache"),
    )
    bare = tmp_path / "remote" / "goldfix" / "yazi-plugin-restic.git"
    bare.mkdir(parents=True)
    assert sh("git", "init", "-q", "--bare", "-b", "main", str(bare), cwd=tmp_path, env=env).returncode == 0
    source = tmp_path / "source"
    source.mkdir()
    shutil.copytree(ROOT / "restic.yazi", source / "restic.yazi", symlinks=True)  # symlinks stay symlinks
    shutil.copy2(ROOT / "README.md", source / "README.md")
    shutil.copy2(ROOT / "LICENSE", source / "LICENSE")
    return source, env, config


def publish(source, env):
    for command in (
        ("git", "init", "-q"),
        ("git", "add", "-A"),
        ("git", "commit", "-qm", "publish"),
        ("git", "push", "-q", str(Path(env["GIT_CONFIG_GLOBAL"]).parent / "remote/goldfix/yazi-plugin-restic.git"), "main"),
    ):
        result = sh(*command, cwd=source, env=env)
        assert result.returncode == 0, result.stderr


def test_ya_pkg_add_deploys_the_plugin_with_the_root_readme_and_license(world):
    source, env, config = world
    publish(source, env)
    result = sh("ya", "pkg", "add", USE, cwd=source, env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    deployed = config / "plugins" / "restic.yazi"
    assert (deployed / "main.lua").read_bytes() == (ROOT / "restic.yazi" / "main.lua").read_bytes()
    for name in ("README.md", "LICENSE"):
        assert not (deployed / name).is_symlink()  # materialised into regular files...
        assert (deployed / name).read_bytes() == (ROOT / name).read_bytes()  # ...with the root content
    assert f'use = "{USE}"' in (config / "package.toml").read_text()


def test_ya_pkg_add_fails_when_readme_and_license_are_not_in_the_plugin_folder(world):
    """The failure this layout exists to prevent (proves the test above can fail)."""
    source, env, config = world
    for name in ("README.md", "LICENSE"):
        (source / "restic.yazi" / name).unlink()
    publish(source, env)
    result = sh("ya", "pkg", "add", USE, cwd=source, env=env)
    assert result.returncode != 0
    assert "LICENSE" in result.stdout + result.stderr
    assert not (config / "plugins" / "restic.yazi" / "main.lua").exists()
