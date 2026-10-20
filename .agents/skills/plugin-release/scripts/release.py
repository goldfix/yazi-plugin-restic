#!/usr/bin/env python3
"""Check, build, version and release the restic.yazi plugin package (standard library only).

    release.py version                          print the current version
    release.py check   [--e2e]                  run the quality gates
    release.py build   [--e2e] [--skip-checks]  assemble dist/restic.yazi-<version>/ (+ .tar.gz + .sha256)
    release.py release <major|minor|patch|X.Y.Z> [--e2e] [--skip-checks] [--dry-run]
                                                bump version.lua + CHANGELOG.md, commit, tag vX.Y.Z, build

The version lives only in `restic.yazi/version.lua` (the last *released* version). A build made from anything
but a clean checkout of the tag `v<version>` is labelled `<version>-dev.<sha>[.dirty]`, so a tester can always tell
what is installed (`plugin restic -- version`). Nothing is ever pushed: `release` prints the command to run.
"""

from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
INSTALLER = Path(__file__).resolve().parents[1] / "assets" / "install.sh"
PLUGIN = "restic.yazi"
SEMVER = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
VERSION_LITERAL = re.compile(r'(version\s*=\s*")([^"]*)(")')
UNRELEASED = "## [Unreleased]"
# Kept only in the root. `restic.yazi/<name>` is a committed git symlink to `../<name>` (so `ya pkg add` finds them
# in the plugin folder and copies their content), and `stage` copies them into the package as regular files.
ROOT_COPIES = ("README.md", "LICENSE")
SAMPLE = "sample_backup.restic"  # annotated `.restic` example, shipped next to install.sh


class ReleaseError(Exception):
    """A problem the user can fix; reported without a traceback."""


# --- Pure helpers ---------------------------------------------------------------------------------------------


def parse_semver(text: str) -> tuple[int, int, int]:
    match = SEMVER.match(text.strip())
    if not match:
        raise ReleaseError(f"not a MAJOR.MINOR.PATCH version: {text!r}")
    return int(match[1]), int(match[2]), int(match[3])


def bump(current: str, spec: str) -> str:
    """New version for `spec`: major | minor | patch | an explicit version greater than `current`."""
    major, minor, patch = parse_semver(current)
    if spec == "major":
        return f"{major + 1}.0.0"
    if spec == "minor":
        return f"{major}.{minor + 1}.0"
    if spec == "patch":
        return f"{major}.{minor}.{patch + 1}"
    if parse_semver(spec) <= (major, minor, patch):
        raise ReleaseError(f"new version {spec} must be greater than the current {current}")
    return spec


def read_version(version_lua: str) -> str:
    match = VERSION_LITERAL.search(version_lua)
    if not match:
        raise ReleaseError('version.lua must contain: return { version = "1.2.3" }')
    parse_semver(match[2])
    return match[2]


def set_version(version_lua: str, version: str) -> str:
    read_version(version_lua)
    return VERSION_LITERAL.sub(lambda m: f"{m[1]}{version}{m[3]}", version_lua, count=1)


def build_version(version: str, sha: str | None, dirty: bool, tagged: bool) -> str:
    """`version` for a clean checkout of its tag, otherwise `version-dev.<sha>[.dirty]`."""
    if tagged and not dirty:
        return version
    label = f"{version}-dev" + (f".{sha}" if sha else "")
    return label + (".dirty" if dirty else "")


def release_changelog(text: str, version: str, day: str) -> str:
    """Move the `[Unreleased]` notes into a new `[version] - day` section (and leave `[Unreleased]` empty)."""
    head, found, rest = text.partition(UNRELEASED)
    if not found:
        raise ReleaseError(f"CHANGELOG.md has no '{UNRELEASED}' section")
    following = re.search(r"^## \[", rest, re.MULTILINE)
    notes, older = (rest[: following.start()], rest[following.start() :]) if following else (rest, "")
    if not notes.strip():
        raise ReleaseError(f"nothing to release: '{UNRELEASED}' in CHANGELOG.md is empty")
    return f"{head}{UNRELEASED}\n\n## [{version}] - {day}\n\n{notes.strip()}\n\n{older}".rstrip() + "\n"


def changelog_notes(text: str, version: str) -> str:
    """Body of the `## [version]` section."""
    match = re.search(rf"^## \[{re.escape(version)}\][^\n]*\n(.*?)(?=^## \[|\Z)", text, re.MULTILINE | re.DOTALL)
    return match[1].strip() if match else ""


# --- Package assembly -----------------------------------------------------------------------------------------


def validate_sources(root: Path) -> str:
    """Check what Yazi requires of a plugin (main.lua, README.md, LICENSE) and return the current version.

    README.md and LICENSE exist once, in the root; `restic.yazi/` holds symlinks to them (see `ROOT_COPIES`)."""
    plugin = root / PLUGIN
    for name in ("main.lua", "version.lua"):
        if not (plugin / name).is_file():
            raise ReleaseError(f"{PLUGIN}/{name} is missing")
    for name in ROOT_COPIES:
        if not (root / name).is_file():
            raise ReleaseError(f"{name} is missing (it is shipped as the plugin's {name})")
        link = plugin / name
        if not link.is_symlink() or str(link.readlink()) != f"../{name}":
            raise ReleaseError(f"{PLUGIN}/{name} must be a symlink to ../{name}: ln -sf ../{name} {PLUGIN}/{name}")
    if not (root / SAMPLE).is_file():
        raise ReleaseError(f"{SAMPLE} is missing")
    return read_version((plugin / "version.lua").read_text())


def package_files(root: Path) -> list[Path]:
    """Plugin sources copied as they are into the plugin folder (whitelist). `version.lua` is stamped and the
    `ROOT_COPIES` come from the repository root: `stage` handles both."""
    return [p for p in sorted((root / PLUGIN).glob("*.lua")) if p.name != "version.lua"]


def stage(root: Path, out_dir: Path, version: str) -> Path:
    """Create `out_dir/restic.yazi-<version>/{restic.yazi/, install.sh, sample_backup.restic}` and return its path."""
    package = out_dir / f"{PLUGIN}-{version}"
    shutil.rmtree(package, ignore_errors=True)
    plugin = package / PLUGIN
    plugin.mkdir(parents=True)
    for source in package_files(root):
        shutil.copy2(source, plugin / source.name)
    for name in ROOT_COPIES:  # the single root README / LICENSE double as the plugin's own
        shutil.copy2(root / name, plugin / name)
    stamped = set_version((root / PLUGIN / "version.lua").read_text(), version)
    (plugin / "version.lua").write_text(stamped)
    shutil.copy2(INSTALLER, package / "install.sh")
    shutil.copy2(root / SAMPLE, package / SAMPLE)
    return package


def make_archive(package: Path) -> Path:
    """Reproducible `<package>.tar.gz` (sorted members, fixed timestamps and owners)."""
    archive = package.parent / f"{package.name}.tar.gz"

    def normalise(info: tarfile.TarInfo) -> tarfile.TarInfo:
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        return info

    with (
        archive.open("wb") as raw,
        gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as zipped,
        tarfile.open(fileobj=zipped, mode="w") as tar,
    ):
        tar.add(package, arcname=package.name, recursive=False, filter=normalise)
        for path in sorted(package.rglob("*")):
            tar.add(path, arcname=str(path.relative_to(package.parent)), recursive=False, filter=normalise)
    return archive


def write_checksum(archive: Path) -> Path:
    """`<archive>.sha256` in the format understood by `shasum -a 256 -c`."""
    checksum = archive.with_name(archive.name + ".sha256")
    checksum.write_text(f"{hashlib.sha256(archive.read_bytes()).hexdigest()}  {archive.name}\n")
    return checksum


def link_latest(package: Path) -> None:
    link = package.parent / "latest"
    if link.is_symlink() or link.exists():
        link.unlink()
    link.symlink_to(package.name)


# --- git and external tools -----------------------------------------------------------------------------------


def git(root: Path, *args: str, check: bool = True) -> str:
    result = subprocess.run(["git", *args], cwd=root, capture_output=True, text=True)
    if check and result.returncode != 0:
        raise ReleaseError(f"git {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def git_state(root: Path, version: str) -> tuple[str | None, bool, bool]:
    """(short sha, working tree dirty, HEAD carries the tag v<version>); a non-repo gives (None, True, False)."""
    if git(root, "rev-parse", "--git-dir", check=False) == "":
        return None, True, False
    sha = git(root, "rev-parse", "--short", "HEAD", check=False) or None
    dirty = bool(git(root, "status", "--porcelain"))
    tagged = f"v{version}" in git(root, "tag", "--points-at", "HEAD", check=False).split()
    return sha, dirty, tagged


def run_checks(root: Path, e2e: bool) -> None:
    """Quality gates; the first failure aborts. Lua tools come from the project-local `.lua/bin`."""
    env = dict(os.environ, PATH=f"{root / '.lua' / 'bin'}{os.pathsep}{os.environ['PATH']}")
    gates = [
        ["stylua", "--check", PLUGIN, "spec", "tests"],
        ["luacheck", PLUGIN, "spec", "tests"],
        ["busted"],
        ["uvx", "ruff", "check", "tests", str(Path(__file__).parent)],
        ["uv", "run", "--no-sync", "pytest", "tests/tooling", "-q"],
    ]
    if e2e:
        gates.append(["uv", "run", "--no-sync", "pytest", "tests/e2e", "-q"])
    for command in gates:
        print(f"==> {' '.join(command)}", flush=True)
        try:
            ok = subprocess.run(command, cwd=root, env=env).returncode == 0
        except FileNotFoundError:
            raise ReleaseError(f"{command[0]} not found (run: source lua_env.sh init)") from None
        if not ok:
            raise ReleaseError(f"check failed: {' '.join(command)}")


# --- Commands -------------------------------------------------------------------------------------------------


def cmd_build(root: Path, dist: Path, skip_checks: bool, e2e: bool) -> Path:
    version = validate_sources(root)
    if not skip_checks:
        run_checks(root, e2e)
    sha, dirty, tagged = git_state(root, version)
    label = build_version(version, sha, dirty, tagged)
    package = stage(root, dist, label)
    archive = make_archive(package)
    write_checksum(archive)
    link_latest(package)
    print(f"\nBuilt {PLUGIN} {label}")
    print(f"  folder   {package}  (run {package / 'install.sh'})")
    print(f"  archive  {archive}")
    return package


def ensure_clean(root: Path) -> None:
    if git(root, "status", "--porcelain"):
        raise ReleaseError("the working tree has uncommitted changes: commit or stash them before releasing")


def cmd_release(root: Path, dist: Path, spec: str, skip_checks: bool, e2e: bool, dry_run: bool) -> None:
    current = validate_sources(root)
    ensure_clean(root)
    new = bump(current, spec)
    if f"v{new}" in git(root, "tag", "--list").split():
        raise ReleaseError(f"tag v{new} already exists")
    changelog = (root / "CHANGELOG.md").read_text()
    updated = release_changelog(changelog, new, datetime.date.today().isoformat())
    print(f"Release {current} -> {new}")
    if dry_run:
        print("(dry run: nothing changed)\n\nRelease notes:\n" + changelog_notes(updated, new))
        return
    if not skip_checks:
        run_checks(root, e2e)

    version_file = root / PLUGIN / "version.lua"
    version_file.write_text(set_version(version_file.read_text(), new))
    (root / "CHANGELOG.md").write_text(updated)
    git(root, "add", f"{PLUGIN}/version.lua", "CHANGELOG.md")
    git(root, "commit", "-m", f"Release v{new}")
    git(root, "tag", "-a", f"v{new}", "-m", f"{PLUGIN} {new}\n\n{changelog_notes(updated, new)}")
    cmd_build(root, dist, skip_checks=True, e2e=False)
    print(f"\nTagged v{new}. Publish with:  git push origin HEAD v{new}")


def main(argv: list[str] | None = None, root: Path = ROOT) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("version")
    for name in ("check", "build", "release"):
        command = sub.add_parser(name)
        command.add_argument("--e2e", action="store_true", help="also run the (slow) end-to-end tests")
        if name != "check":
            command.add_argument("--skip-checks", action="store_true")
            command.add_argument("--dist", type=Path, default=None, help="output folder (default: <repo>/dist)")
        if name == "release":
            command.add_argument("bump", help="major | minor | patch | X.Y.Z")
            command.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "version":
            print(validate_sources(root))
        elif args.command == "check":
            validate_sources(root)
            run_checks(root, args.e2e)
        elif args.command == "build":
            cmd_build(root, args.dist or root / "dist", args.skip_checks, args.e2e)
        else:
            cmd_release(root, args.dist or root / "dist", args.bump, args.skip_checks, args.e2e, args.dry_run)
    except ReleaseError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
