# Development

Building, testing and releasing [restic.yazi](../README.md), and its known gaps.

## Building

This `README.md` and the root `LICENSE` are the **only** copies in the repository. Yazi (and `ya pkg`) require both
inside the plugin folder, so `restic.yazi/README.md` and `restic.yazi/LICENSE` are committed **git symlinks** to
`../README.md` and `../LICENSE`: `ya pkg add` replaces them with copies of their targets, and the build does the same
for the package. Links in the README must therefore be absolute URLs (the documents under `docs/` are not shipped, so they may use relative ones). The build checks the symlinks (and
`tests/tooling/test_ya_pkg.py` runs the real `ya pkg add` against a local stand-in for GitHub; installing from GitHub with
`ya pkg add`, `b` `v` and removing it again were also tried by hand and work).

```sh
source lua_env.sh init          # one-off: builds a local Lua 5.5 toolchain (busted, luacheck, stylua) in ./.lua
source lua_env.sh active        # per shell: puts ./.lua/bin on PATH
busted                          # unit + integration tests (needs restic)
luacheck restic.yazi spec tests && stylua --check restic.yazi spec tests
uv run --no-sync pytest tests/tooling tests/e2e
```

**Packages and versions** are handled by the `plugin-release` skill
(`.agents/skills/plugin-release/SKILL.md`):

```sh
python3 .agents/skills/plugin-release/scripts/release.py build                 # run the checks, build into dist/
python3 .agents/skills/plugin-release/scripts/release.py build --skip-checks   # build only (no Lua toolchain needed)
python3 .agents/skills/plugin-release/scripts/release.py release minor         # bump, changelog, commit, tag, build
```

```
dist/
  restic.yazi-<version>/              restic.yazi/ (the plugin, with README.md and LICENSE) + install.sh + sample_backup.restic
  restic.yazi-<version>.tar.gz        the same, archived (reproducible)
  restic.yazi-<version>.tar.gz.sha256
  latest -> restic.yazi-<version>
```

The version lives only in `restic.yazi/version.lua` (the last *released* version). A build from anything but a clean
checkout of a release tag is labelled `<version>-dev.<sha>[.dirty]`, and `b` `v` in Yazi shows which one is running.
For development you can link the folder instead of installing:
`ln -s "$PWD/restic.yazi" ~/.config/yazi/plugins/restic.yazi`.

More: [AGENTS.md](../AGENTS.md) (contributor and agent notes), [CHANGELOG.md](../CHANGELOG.md).

## Project structure

```
restic.yazi/               the plugin (this is what gets installed)
  main.lua                   entry point only: wiring to Yazi (hooks, actions, previewer, spotter), no business logic
  config.lua                 .restic parser, restic binary resolution + minimum version, paths (~, relative, absolute)
  client.lua                 restic CLI wrapper: environment, SFTP batch mode, JSON/JSONL parsing, error messages, killable runs
  snapshots.lua              snapshot folder naming, parsing and ordering
  ghost.lua                  ghost tree: create / reuse / lazily expand, path mapping (+ `latest`), staging, user dir
  restore.lua                restore planning (ghost paths → snapshot paths) and destination validation
  task.lua                   the Yazi task that keeps a long restore visible (status bar gauge, task manager)
  preview.lua                the rows of the metadata preview (pure)
  info.lua                   the sections of the `Tab` spotter: entry, snapshot, repository (pure)
  util.lua                   small pure helpers
  version.lua                the plugin version (single source of truth)
  README.md, LICENSE         git symlinks to the root files (single copies; see "Building")
spec/                      busted unit tests (+ helpers: a Yazi mock, a local-filesystem stand-in, a restic fixture)
tests/integration/         busted tests against a real restic repository built in a temp dir (+ a fake ssh)
tests/e2e/                 pytest + pyte: a real Yazi in a pseudo-terminal, isolated config, real repository
tests/tooling/             pytest for the release script and install.sh
.agents/skills/            agent skills: plugin-release (build/version/release), memory-updater, kroki-diagrams
docs/                      HOW_IT_WORKS.md (internals), DEVELOPMENT.md (this file)
sample_backup.restic       annotated `.restic` template
CHANGELOG.md               release notes (Keep a Changelog)
AGENTS.md                  directives, verified Yazi/restic facts and architecture for contributors and AI agents
dist/                      builds (gitignored)
```

Code conventions: plain Lua 5.4+ (Yazi embeds Lua 5.5), LuaLS annotations, pure logic (parsing, naming, path mapping)
kept in side-effect-free functions, and I/O injected or confined to thin wrappers so that nearly everything is
unit-testable without Yazi.

## Tests

| Layer | What it checks | Run |
|---|---|---|
| Unit (`spec/`) | parsing, naming, path mapping, error handling, argument building — with a Yazi mock | `busted` |
| Integration (`tests/integration/`) | `client` and `ghost` against a real restic repository, and the ssh options against a fake `ssh` | `busted` |
| End to end (`tests/e2e/`) | the whole plugin inside a real Yazi (browse, preview, `Tab` details, open, restore of folders and of multiple selections, the restore task and its cancellation, reopen, `latest`, local-time folder names, wrong password, SFTP through a local `sftp-server`) | `uv run --no-sync pytest tests/e2e` (~5 min) |
| Tooling (`tests/tooling/`) | version bumping, changelog, packaging, `install.sh`, the release flow in a throw-away git repo | `uv run --no-sync pytest tests/tooling` |

## Known limitations and open points

- On case-insensitive filesystems (macOS default, Windows) backup entries whose names differ only by case collapse
  into one entry.
- On Windows, names that Windows forbids (`a:b`, `con`…) make their folder fail to list; Windows is otherwise untested.
- Restoring selections from several snapshots into one destination lets later snapshots overwrite earlier ones where
  paths overlap. If one path of a snapshot cannot be restored, that snapshot's whole group fails (the selection is kept).
- When a browsing tree is reused after the snapshot folder naming changed (e.g. you moved to another time zone), the
  affected snapshots are rebuilt and their already-fetched files are downloaded again.
- The browsing tree can only follow one repository at a time.
- Snapshots are addressed by their 8-character id: restic would report an ambiguity if two ids shared the prefix (a
  full-id map would fix it).
- Two Yazi instances of the same user opening the same repository share one browsing tree; the second open clears the
  first one's in-flight downloads.
- Linux is untested too, though nothing in the code is macOS-specific.
- Backends other than local and SFTP are not covered by automated tests (S3, S3-compatible and REST were tried by
  hand and work; B2, Azure, Google Cloud and rclone are untried).

The roadmap lives in the project notes, not here.
