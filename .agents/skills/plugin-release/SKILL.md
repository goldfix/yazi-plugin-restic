---
name: plugin-release
description: Build, version and release the restic.yazi plugin package. Use to produce an installable build in dist/ for testing, to cut a versioned release (bump version.lua, update CHANGELOG.md, commit, git tag), or to check what is installed. Runs the quality gates first.
---

# Plugin release

Turns the working tree into an installable package and manages its version. Everything is done by
`scripts/release.py` (Python standard library only); this file explains when and how to use it.

```
python3 .agents/skills/plugin-release/scripts/release.py <command>
```

## What a build is

`dist/` (gitignored) receives, for every build:

```
dist/restic.yazi-<version>/            unpacked build: restic.yazi/ (main.lua, modules, README.md, LICENSE, version.lua) + install.sh + sample_backup.restic
dist/restic.yazi-<version>.tar.gz      reproducible archive of that folder
dist/restic.yazi-<version>.tar.gz.sha256   (`shasum -a 256 -c`)
dist/latest -> restic.yazi-<version>   newest build
```

Shipped inside the plugin folder (whitelist): `restic.yazi/*.lua`, and the **root `README.md` and `LICENSE`, copied
in as real files** (`ROOT_COPIES` in the script). There is a single README and a single LICENSE to edit, in the root;
`restic.yazi/README.md` and `restic.yazi/LICENSE` are **committed git symlinks** to them (`ln -s ../README.md
restic.yazi/README.md`), which is what lets `ya pkg add goldfix/yazi-plugin-restic:restic` work from git (ya deploys
exactly `main.lua`, `README.md`, `LICENSE` and the kebab-case `*.lua` of the plugin folder, and materialises symlinks). Next to the plugin folder: `install.sh` and the root `sample_backup.restic`.
Specs, tests and notes are never shipped.
Yazi requires `main.lua`, `README.md` and `LICENSE` in a plugin folder; the script refuses to build without the root
files, `main.lua`, or if the two symlinks are missing/wrong. Links in the README must be absolute URLs: the copy
lives in a different folder.

## Versioning rules

- Semantic Versioning. The only place the version is written is `restic.yazi/version.lua`
  (`return { version = "X.Y.Z" }`) and it always holds the **last released** version (`0.0.0` = nothing released yet).
- `build` labels its output from git: a clean checkout of the tag `v<version>` is `<version>`; anything else is
  `<version>-dev.<short sha>` plus `.dirty` when there are uncommitted changes. The label is stamped into the
  *package's* `version.lua` (the source file is untouched), so `plugin restic -- version` (key `b` `v`) tells the tester
  exactly what Yazi runs.
- Release notes live in `CHANGELOG.md` (Keep a Changelog). Contributors add bullets under `## [Unreleased]` as they
  work; a release moves them into `## [X.Y.Z] - date`. A release with an empty `[Unreleased]` is refused.

## Commands

| Command | Effect |
|---|---|
| `version` | print the version in `version.lua` |
| `check [--e2e]` | gates: `stylua --check`, `luacheck`, `busted`, `ruff`, `pytest tests/tooling` (+ `pytest tests/e2e` with `--e2e`, ~1.5 min) |
| `build [--e2e] [--skip-checks] [--dist DIR]` | run the gates, then assemble `dist/` as above. Does not touch git or any source file |
| `release <major\|minor\|patch\|X.Y.Z> [--e2e] [--skip-checks] [--dry-run]` | requires a clean working tree. Runs the gates, bumps `version.lua`, moves `[Unreleased]` into the new version section, commits `Release vX.Y.Z`, creates the annotated tag `vX.Y.Z` (message = the notes), builds. **Never pushes**: it prints the `git push` command |

Lua tools are taken from `./.lua/bin` (create it with `source lua_env.sh init` if missing).

## Workflows

### A. Build something to test (most common)

1. Make sure the work is described under `[Unreleased]` in `CHANGELOG.md` if it is user visible.
2. `release.py build` (add `--e2e` when the change touches Yazi integration; `--skip-checks` only if the gates were
   just run).
3. Install it: `dist/latest/install.sh` (uses `$YAZI_CONFIG_HOME`, else `~/.config/yazi`; replaces a previous install;
   refuses to overwrite a symlinked development checkout). The user's `init.lua`, `yazi.toml` and `keymap.toml` are
   never modified: the settings to add are in `README.md`; `install.sh` also prints where `sample_backup.restic` is.
4. Confirm in Yazi with `b` `v` (the dev label must match the build that was printed).

To smoke-test the *installed* package against a real Yazi: `E2E_PLUGIN_DIR=<dir>/plugins/restic.yazi uv run --no-sync pytest tests/e2e`.

### B. Cut a release

1. **Ask the user first** — the command commits and tags — and agree on the bump (patch: fixes; minor: features;
   major: breaking changes to the `.restic` file, keymap or behaviour).
2. Bring docs up to date (`memory-updater` skill; `README.md`, `CHANGELOG.md` `[Unreleased]`)
   and commit everything: the tree must be clean.
3. `release.py release minor --dry-run` to see the version change and the notes, then without `--dry-run`
   (add `--e2e` for a release).
4. Report the printed `git push origin HEAD vX.Y.Z` to the user; pushing is theirs to do.

## Troubleshooting

- `the working tree has uncommitted changes` — commit or stash; `build` has no such restriction (it labels `.dirty`).
- `README.md is missing` / `LICENSE is missing` — they must exist in the repository root.
- `restic.yazi/LICENSE must be a symlink to ../LICENSE` — recreate it: `ln -sf ../LICENSE restic.yazi/LICENSE`
  (same for the README). Regular copies are rejected on purpose: there must be a single copy.
- `check failed: <command>` — run that command alone and fix it; nothing was modified before the gates passed.
- `tag vX.Y.Z already exists` — the version was already released; use a higher bump.
- A tag was created wrongly and not pushed: `git tag -d vX.Y.Z && git reset --hard HEAD~1`.

## Tests

`uv run --no-sync pytest tests/tooling` covers the script (bumping, changelog, packaging, reproducible archive,
`install.sh`, and the whole release flow in a throw-away git repository). `tests/tooling/test_ya_pkg.py` runs the real
`ya pkg add` on the real plugin folder, redirecting `https://github.com/` to a local bare repo with git `insteadOf`.

## Two delivery routes

- **`ya pkg add goldfix/yazi-plugin-restic:restic`** (recommended for users): GitHub-only, follows the default
  branch, pins via `rev = "=<tag>"` in `package.toml`. Needs the repository to be public. The release flow only has to
  tag and push; nothing in `dist/` is involved.
- **`dist/…/install.sh`** (this skill's output): for a hand-made install from a clone, offline machines, local test
  builds, internal distribution. It warns when `package.toml` lists the plugin, because overwriting a `ya pkg`-managed
  folder breaks the next `ya pkg` operation (hash mismatch).
