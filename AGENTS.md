# AGENTS.md — Instructions for AI agents

Read `MEMORY.md` first (living diary: status, decisions, next steps). Keep **this file** for directives and
vital facts; keep **MEMORY.md** as the work diary. `README.md` (root: the ONLY README: overview, TL;DR, configuration, internals, build notes, known gaps) is end-user
documentation: keep it in sync with user-visible changes (the build copies it, like `LICENSE`, into the package's plugin
folder, so its links must be absolute URLs). User-visible changes also go under `## [Unreleased]` in `CHANGELOG.md`;
`sample_backup.restic` must follow any change to the `.restic` format.
Everything (files, comments, commit messages) is written in **English**.

## 1. Project overview

A **Yazi** plugin (`restic.yazi`) to browse and restore **Restic** snapshots without FUSE.

It uses the **Ghost Filesystem** pattern: a temporary tree of real directories and **0-byte files** is created under
the OS temp dir. Yazi's native three-column engine navigates it. Real data is fetched from restic only on demand
(restore + open). Metadata (type, size, dates, permissions…) of the hovered ghost entry is shown in the preview pane,
read from the backup (not from the 0-byte file).

## 2. Constraints

1. **Runtime:** Yazi 26.9.x embeds **Lua 5.5**. Write plain Lua ≥ 5.4 (no LuaJIT-only code). Note that in Lua 5.5
   `for` loop variables are `const`. Yazi globals: `ya`, `ps`, `ui`, `fs`, `cx`, `rt`, `Command`, `Url`, `Err`.
2. **Restic access:** CLI only (`restic --json`): `snapshots`, `ls`, `restore` (`dump` is not used: too slow through Lua).
   **Minimum restic 0.17.0** (`restore <id>:<subfolder>`), checked by `config.resolve_binary` via `restic version`.
3. **Password:** asked via `ya.input{ obscure = true }` once per session; kept **only in memory** (plugin `state`);
   passed to restic via the `RESTIC_PASSWORD` environment variable (never on the command line, never on disk).
   `RESTIC_PASSWORD_FILE`, `RESTIC_PASSWORD_COMMAND`, `RESTIC_REPOSITORY_FILE` are cleared on every call (they
   would override the typed password / conflict with `-r`). One repository / one password active at a time.
4. **`.restic` config file** (key = value, `#` comments):
   ```ini
   repository = sftp:backupuser@192.168.1.100:/srv/restic-repo
   restic_exec = /usr/local/bin/restic
   # optional, sftp only, default yes (comments must be on their own line)
   ssh_batch_mode = yes
   ```
   If `restic_exec` is missing/empty, `restic` is searched in `$PATH` (probe: `<exec> version`); if unresolved or
   too old → `ya.notify{ level = "error" }`. `~` is expanded in both keys; a relative local repository path is
   relative to the `.restic` file; values are verbatim (no inline comments), quotes optional, UTF-8 BOM tolerated.
5. **Lazy navigation:** no global parsing at start. Entering a folder expands only that level (+ direct children,
   1-level lookahead).
6. **No blocking work in sync context** (`ps.sub` callbacks, `ya.sync` blocks): delegate to `ya.async`.
7. **No interactive ssh inside the TUI:** for `sftp:` repositories every call adds `-o "sftp.args=-o BatchMode=yes"`,
   so ssh fails fast instead of prompting on Yazi's terminal (passphrase, password, unknown host key). Failures show
   ssh's own message (`subprocess ssh: …` lines) plus a hint. `ssh_batch_mode = no` in the `.restic` file disables it.
8. **Privacy/safety of the ghost tree:** per-user dir `/tmp/yazi-restic-<uid>` must be a real dir owned by the user
   (checked, refuse otherwise — /tmp squatting), then `chmod 700`; root `chmod 700`. Backup names that are empty,
   `.`, `..`, contain `/`, `\`, NUL or equal a marker (`ghost.is_marker`: `(not listed yet)`, or the legacy `.unfetched` of
   ≤ 0.5.0, still reserved so that `reflag` can delete old markers of a reused tree safely) are skipped; backup symlinks become empty regular files.
9. Code must be **clean, minimal (DRY) and documented** (LuaLS annotations `---@param/---@return`, short module header).
   Pure logic (parsing, naming, path mapping, record filtering) lives in side-effect-free functions; I/O is injected
   or isolated in thin wrappers so that everything is unit-testable without Yazi.

## 3. Verified Yazi API facts (differences vs. older docs/drafts)

| Old/draft            | Reality (26.9.x)                                                                       |
|----------------------|----------------------------------------------------------------------------------------|
| `ya.manager_emit`    | `ya.emit("cd", { path, raw = true })`                                                  |
| `[[manager.…]]`      | `[[mgr.prepend_keymap]]`                                                               |
| opener runs a plugin | `opener.run` is a *shell* command → cannot call plugins. Use a keymap: `plugin restic -- enter` |
| plugin entry `init.lua` | `main.lua` (`init.lua` is the user's global config, where `require("restic"):setup()` goes) |
| `ya.input` → string  | returns `(value, event)`; event 1 = submit, 2 = cancel, 3 = typing                     |
| `require("x")`       | custom loader: `require(".config")` loads `restic.yazi/config.lua`; module functions are called with `.` (module fields that are functions are wrapped as async). **A module must return a table** (a string fails at startup: "error converting Lua string to table") |

**`source_app/yazi` is the NIGHTLY source, the installed binary is 26.9.1.** They differ. The docs MCP
(version 26.9.1) is the contract; confirm anything doubtful with the e2e harness. Known differences: in 26.9.1
`Child:read(n)` returns the data as a **table of byte values** (nightly: a string) → avoid it for bulk data;
`File.cha` (26.9.1) vs `File.stat` (nightly) → prefer `fs.cha(url)`.
Unexpected Lua errors in an `entry`/`ya.async` body are **silent** in Yazi → wrap them in `guarded()` (notifies).
Values crossing `ya.sync` are deep-copied: never return big tables (e.g. all `entries`) from a sync block; the
session (small, flat) is stored whole in `state.session`, the big tables in `state.entries` / `state.busy`.
`ya.notify{content}` needs a string → `notify()` applies `tostring` (fs errors are `Error` userdata).

Other facts: `Command`/`fs.*` are async-context only; `Command` cannot redirect stdout to a file (so streaming `dump` would go through
`child:read`, which is slow in 26.9.1: avoid, use `restore`); `io`/`os` std libs are available; `ps.sub("cd")` runs in sync context;
`ya.sync` blocks give access to `cx` and plugin `state`; previewers are plugins exposing `peek`/`seek`
(`ya.preview_widget(job, widget)`); spotters expose `spot`.
Spotter facts (NOT in the 26.9.1 docs; read from the nightly source and proven by the e2e tests): `prepend_spotters` rules
use the same `url`/`mime` selectors as previewers, and **a `url` pattern ending in `/` matches directories only, one
without it files only** (so ghost files and folders need two rules); `spot(job)` runs async like `peek`
(`job.file`, `job.mime`, `job.skip`, `job.id`) and draws with `ya.spot_table(job, ui.Table(rows):area(ui.Pos{…})…)`,
which may be called again with the same `job` to refresh (progressive results); `ui.Row({a, {l1, l2}}):height(2)` makes a
multi-line cell (Yazi also measures cell heights itself; the explicit height is harmless); `ya.input` works inside `spot`; when the user moves on Yazi aborts the Lua with the error
"Spot task cancelled" (`guarded` swallows it); `Tab`/`Esc` close the spot, `h`/`l` swipe to the neighbours (re-run `spot`).

Restic facts: `ls <snap> <dir> --json` (no `-R`) → JSONL: one `snapshot` record, then the dir itself, then its
direct children (`name,type,path,size,mode,permissions,mtime,…`). Paths are as printed by `ls` (e.g. `/data/a.txt`).
`snapshots --json` times keep the creating host's zone
(`…+09:00`, `…-04:00`): never compare them as text (`snapshots.epoch`); snapshot dir names use the viewer's LOCAL
time (`snapshots.format_time`, pinned to UTC in `spec/helpers/setup.lua` so unit tests ignore the machine's zone). Fatal errors: stderr, as JSON `{"message_type":"exit_error","code","message"}` for `--json` commands, plain text
otherwise (`Client:failure` handles both). Wrong password → exit 12 (0.17+; message match for older); missing
repo → 10. `restore --include <p>` keeps the full path under `--target` and restores ancestor dirs with their
backed-up permissions; restore exits 0 when the include matches nothing. Empty `RESTIC_PASSWORD` → error, no prompt.

## 4. Architecture

```
.restic file ──(smart-enter key)──> main.lua  (dispatch: enter | leave | back | restore | version | peek | spot | setup)
                                       │
        ┌──────────────┬───────────────┼───────────────┬─────────────────┐
     config.lua    client.lua     snapshots.lua     ghost.lua        restore.lua
   parse/resolve   restic CLI     naming/sorting    ghost tree,      restore to a
   binary, paths   wrapper        of snapshots      reuse/expansion, user-chosen dir
                   (+JSON/JSONL,                    path mapping     (+ preview.lua:
                    fetch, sftp)                    (metadata cache  metadata rows)
                                                     lives in state)
```

Flow:
1. **Open** (`<Enter>` on `*.restic`): parse config → resolve binary → ask password → `snapshots --json` →
   create the session root `/tmp/yazi-restic-<uid>/<repo_id>/` (per-user dir, mode 700; Windows: `%TEMP%\yazi-restic\<repo_id>`) with one dir per snapshot
   (`<local-time timestamp>__<short_id>__<hostname>__[<tags>]`, each holding the marker) + relative `latest` symlink → `cd`.
   `session.file` remembers the `.restic` file: `plugin restic -- back` (`ya.emit("reveal", { file, raw = true,
   no_dummy = true })`) returns to it from anywhere, and `leave` does so when the cwd is the session root (else it
   emits Yazi's own `leave`); both are optional keymap entries.
   Yazi keeps the logical path when entering `latest`, so `ghost.locate(root, path, latest)` resolves the alias
   (session field `latest`); every caller must pass it. The in-memory tables (`state.entries`, `state.busy`) are keyed
   by `ghost.canonical` (the `latest/…` spelling rewritten to `<snapshot dir>/…`, done by `key()` inside the sync
   accessors), so both spellings share metadata and busy flags.
   **An existing root is reused**, not wiped: snapshots are immutable, so folders and fetched files stay valid;
   vanished snapshots are removed, new ones added, every folder is re-flagged with the marker (metadata lives in
   memory only, so each folder is listed again once per session) and `<root>/.staging` is wiped.
2. **Expand** (`ps.sub("cd")` → `ya.async`; `ps.sub("hover")` → after 0.4 s on the same entry, so the preview pane
   shows a hovered folder's content): if the folder is inside the session and contains the marker `ghost.MARKER` = `(not listed yet)` (VISIBLE on purpose: a hidden
   dot file made loading folders look empty, "No items"):
   `ls <snap> <path> --json`, keep direct children, create dirs (+marker) and 0-byte files, store each node's
   metadata in the plugin `state` (memory only), remove the marker; finally `peek --force` if the hovered entry
   was just listed (it may have been previewed before its metadata arrived).
3. **Preview** (previewer on ghost paths): show metadata of the hovered entry from the in-memory cache.
4. **Open file** (`<Enter>` on a 0-byte ghost file): `Client:fetch` = `restic restore <id>:<dir> --include /<name>`
   into a unique `<root>/.staging/<hash>` dir (outside the backup namespace, same filesystem), then renamed over the
   placeholder; then normal `open`. The subfolder syntax avoids restoring ancestor dirs, whose (possibly read-only)
   permissions would forbid moving the file out. A path being fetched/listed is `claim`ed (no double work).
   Entering inside the ghost tree takes precedence over `.restic` detection (a backed-up `.restic` is just a file);
   if the folder of a reused tree is not listed yet, `enter` lists it first.
   `restore` is ~5x faster than streaming `dump` through Lua (256 MB: 0.8 s vs 4.6 s). Files with size > 0 are
   already cached and just opened.
5. **Spot** (`Tab`, `M:spot`): ghost entry → `info.node` (+ `ensure_listed` and `info.tally` for folders, counted inside a
   sync block); snapshot dir / `latest` → `info.snapshot` from `state.snapshots` (kept at open, keyed by short id);
   ghost root or `*.restic` outside the ghost tree → `info.repository`: `snapshots --json` then `stats --mode raw-data`
   (reads each distinct tree once, never file contents; `restore-size` revisits every entry of every snapshot and is
   NOT used), drawn progressively; `Command` children are `kill_on_drop`, so closing the spot kills restic. A `.restic` file reuses the
   open session's password when `session.repository` matches, otherwise asks (`ya.input`) and does not keep it.
   With a selection Yazi passes mime `multi/unknown`, but our url rules still win: we describe the hovered entry.
6. **Restore** (`plugin restic -- restore`): `ya.input` for the destination (`restore.destination`: `~` expanded,
   must be absolute and outside the ghost tree). `restore.plan` turns the selection (or the hovered entry; note
   `cx.active.selected` yields `File`s: `.url`) into one group per snapshot (duplicates, entries below another selected
   entry and non-backup paths such as the marker dropped; the skipped ones are counted and reported), then ONE
   `restore <snap> --target <dest> --include <p1> --include <p2>…` per snapshot (`Client:restore(id, includes, dest)`;
   a `/` include = whole snapshot). Progress notification per group, summary with elapsed time; on success the
   selection is cleared (`ya.emit("escape", { select = true })`), on failure it is kept.

## 5. Repository layout

```
restic.yazi/          the plugin (symlink/copy into ~/.config/yazi/plugins/)
  main.lua            entry point only: dispatch (+ `spot` for the Tab spotter), no business logic
  config.lua          .restic parser, binary resolution + min version, paths (~, absolute), repo id
  client.lua          restic CLI wrapper (env, sftp BatchMode, JSON/JSONL, errors, fetch, restore)
  snapshots.lua       snapshot dir naming (local time) / parsing / ordering by real instant (`epoch`)
  ghost.lua           ghost tree create/reuse/expand, path mapping (+ `latest` alias), staging, per-user dir
  restore.lua         restore planning (ghost paths -> per-snapshot groups), progress texts, destination validation
  preview.lua         rows of the metadata preview (pure)
  info.lua            sections of the `Tab` spotter: entry / snapshot / repository (pure)
  util.lua            small pure helpers
  version.lua         `return { version = "X.Y.Z" }`: last released version, single source of truth (bumped by the release skill)
  README.md, LICENSE  git SYMLINKS to `../README.md` / `../LICENSE` (single copies live in the root). `ya pkg`
                      requires both in the plugin folder and materialises git symlinks into real files when it
                      deploys; `release.py` (`ROOT_COPIES`) validates the links and copies the root files into the
                      package. Never replace them with regular copies (`validate_sources` and the tests fail)
spec/                 busted unit tests (+ spec/helpers: yazi mock, localfs GhostFs, restic repo fixture)
tests/integration/    busted tests against a real restic repo built in a temp dir (+ fake ssh for sftp)
tests/tooling/        pytest for the release script (+ install.sh, release flow in a temp git repo) and `ya pkg add` of
                      the real plugin folder against a local git repo standing in for GitHub (`test_ya_pkg.py`)
tests/e2e/            pytest + pyte: a real Yazi in a pty, isolated YAZI_CONFIG_HOME, real restic repo
.agents/skills/plugin-release/   build / version / release skill (scripts/release.py, assets/install.sh)
dist/                 builds ready to install (gitignored): restic.yazi-<version>/, .tar.gz, .sha256, `latest` link
sample_backup.restic  annotated `.restic` template for users (shipped next to install.sh; every example is tested by `spec/unit/sample_spec.lua`: keep it in sync with `config.lua`)
CHANGELOG.md          Keep a Changelog; `[Unreleased]` is moved to a version section by `release`
source_app/yazi/      upstream yazi sources, REFERENCE ONLY (gitignored, never edit)
tmp/                  scratch space for experiments (gitignored)
.lua/                 local Lua 5.5 + luarocks + busted + luacheck + stylua (gitignored; see lua_env.sh)
.venv/, py_env.sh, pyproject.toml, ruff.toml   Python tooling kept for skills/helper scripts
```

## 6. Essential commands

```bash
source lua_env.sh init      # one-off: build the local Lua toolchain into ./.lua
source lua_env.sh active    # per shell: put ./.lua/bin on PATH
busted                      # unit (spec/) + integration (tests/integration/) tests, config in .busted
uv run --no-sync pytest tests/e2e   # end-to-end tests against the installed yazi/restic (~4 min: run in background)
uv run --no-sync pytest tests/tooling   # release tooling tests (fast)
python3 .agents/skills/plugin-release/scripts/release.py check    # lint + busted + ruff + tooling tests (--e2e adds the e2e)
python3 .agents/skills/plugin-release/scripts/release.py build    # gates + installable build in dist/ (see the skill)
luacheck restic.yazi spec   # lint
stylua restic.yazi spec     # format (stylua --check to verify)
```

## 7. Yazi configuration for users (target)

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on  = "<Enter>"
run = "plugin restic -- enter"       # smart enter: ghost file → fetch+open; .restic → open repo; dir → enter; else → open
desc = "Open (restic aware)"

[[mgr.prepend_keymap]]
on  = [ "b", "r" ]
run = "plugin restic -- restore"
desc = "Restore selected file/folder from the restic backup"

[[mgr.prepend_keymap]]
on  = "h"
run = "plugin restic -- leave"       # from the top of the ghost tree → the .restic file; elsewhere Yazi's leave
desc = "Leave (restic aware)"

[[mgr.prepend_keymap]]
on  = "<Left>"                       # same action for the arrow key (`on = [ "h", "<Left>" ]` would be a key SEQUENCE)
run = "plugin restic -- leave"
desc = "Leave (restic aware)"

[[mgr.prepend_keymap]]
on  = [ "b", "b" ]
run = "plugin restic -- back"        # jump to the .restic file of the open repository
desc = "Back to the .restic file"

[[mgr.prepend_keymap]]
on  = [ "b", "v" ]
run = "plugin restic -- version"     # notifies the installed plugin version (dev builds: <version>-dev.<sha>[.dirty])
desc = "Show the restic.yazi version"
```
```toml
# yazi.toml
[plugin]
prepend_previewers = [ { url = "/tmp/yazi-restic-*/**", run = "restic" } ]
prepend_spotters = [        # Tab; optional. A trailing `/` in `url` means "directories only": files and folders need their own rule
  { url = "/tmp/yazi-restic-*/**",  run = "restic" },
  { url = "/tmp/yazi-restic-*/**/", run = "restic" },
  { url = "*.restic",               run = "restic" },
]
```
(`init.lua`: `require("restic"):setup()` registers the `cd`/`hover` hooks. The plugin dir must be reachable as
`~/.config/yazi/plugins/restic.yazi`; the e2e tests symlink `restic.yazi/` there.)

## 8. Acceptance tests

| Case                  | Procedure                                    | Expected                                                   |
|-----------------------|----------------------------------------------|------------------------------------------------------------|
| Config                | open `.restic` without `restic_exec`         | binary found in `$PATH`, or a clear error notification     |
| Credentials           | select the repository                        | masked password prompt                                     |
| Reopen                | open the same repo twice                     | tree reused: fetched files still cached, metadata listed again |
| Ghost root            | correct password                             | per-user session root created, snapshot dirs listed, Yazi `cd`s in |
| On-demand expansion   | enter a folder holding the marker            | children appear at once, the marker disappears; while loading it shows `(not listed yet)`, not "No items" |
| Metadata preview      | hover a ghost entry                          | type/size/dates/perms from the backup are shown            |
| Spot a file/folder    | `Tab` on a ghost file / folder               | table with the entry's details (+ contents for a folder)   |
| Spot a snapshot       | `Tab` on a snapshot dir or `latest`          | snapshot record + backup run (ID, host, paths, tags, files…) |
| Spot a repository     | `Tab` on a `.restic` file / the ghost root   | snapshots, hosts, stored size, compression; password reused if that repo is open, else asked |
| Fetch on demand       | `<Enter>` on a 0-byte file                   | file is restored locally, then opened                      |
| Restore               | restore a complex folder                     | whole folder written to the chosen destination             |
| Multi-restore         | select several entries with Space, `b r`     | all restored with one restic call per snapshot, selection cleared |
| Local-time names      | run Yazi with another `TZ`                   | snapshot folder names show that zone's local time          |
| Leave the backup      | `leave` at the top of the tree / `back` anywhere | back in the folder of the `.restic` file, file highlighted |
| Installed version     | `plugin restic -- version`                   | notification with the build label (`0.1.0` or `0.1.0-dev.…`) |
| Browse via `latest`   | enter `latest` and navigate                  | same behaviour as the snapshot directory                   |
| Wrong password        | wrong password                               | error notification, no session created                     |
| sftp without agent    | sftp repo needing a passphrase / new host key | immediate error with ssh's message and a hint, no prompt   |
| sftp batch mode       | browse an sftp repo (fake ssh → local sftp-server) | every restic call carries `BatchMode=yes`; with `ssh_batch_mode = no` none does |

## 9. Working rules (learned the hard way)

- **Backends tested**: local and sftp (automated: sftp through a fake `ssh` that execs the local `sftp-server`); S3,
  S3-compatible buckets and a REST server by hand (user, OK). Untried: B2, Azure, Google Cloud, rclone, real sftp server, Linux,
  Windows. Say so in docs; do not claim more.
- **Delivery** (verified, details in MEMORY.md "Yazi delivery system"): two routes. `ya pkg add
  goldfix/yazi-plugin-restic:restic` (GitHub-only, default branch, needs the repo public; works thanks to the
  `restic.yazi/README.md|LICENSE` git symlinks) and `dist/…/install.sh` (hand-made/offline/internal; does NOT register
  in `package.toml`, so `ya pkg list` never shows it; warns if `ya pkg` already manages the plugin). Never mix them on
  one machine: `ya pkg` hash-checks the deployed folder.

- **Release state**: last release `v0.6.0`; `v0.7.0` (minor: `b` key prefix, docs) is being prepared, see MEMORY.md "Next steps".
- **Ask before** committing, tagging/releasing (`release.py release`) or pushing; never push. Releases need the user's
  go-ahead on the bump level. `MEMORY.md` is git-ignored by the inherited `.gitignore`: ask before changing that.
- **Scripted edits must assert**: when patching files from Python, `assert text.count(old) == 1` before `replace` (a
  silent no-op once left `ssh_batch_mode` out of the session and nothing failed until a dedicated e2e test existed).
  `stylua` reformats code, so patterns copied from an earlier version may not match anymore.
- **Anything Yazi-facing needs an e2e test**: Lua unit tests passed while Yazi refused to start (module returning a
  string), while a `ya.sync` accessor dropped a field, and while selection restore read `cx.active.selected` wrongly
  (it yields `File` objects: use `.url`). Prove new tests can fail (revert the fix once).
- **e2e timeouts**: `tests/e2e/driver.py` `TIMEOUT = 10` s for every wait (user decision after trying 5 s; measured over a
  full run: a restic call through Yazi takes ≤ 1.5 s, the slowest ordinary wait 3 s); the deliberately slow tests pass an
  explicit longer one. Re-measure before lowering it again: the suite's ~4 min are mostly the 0.3 s `settle` of each `send`, not the waits (76 s in total).
- **e2e alone**: run the e2e suite without other heavy jobs in parallel; on macOS a killed `yazi` can hang in exit until
  the pty is drained (`driver.close()` pumps it; a stalled run usually shows a `(yazi)` zombie).
- **Long commands** (`pytest tests/e2e` ≈4 min, `release.py build --e2e` ≈5 min): run them in the background with a
  log file or give an explicit timeout; a long foreground call gets aborted.
- After every work block update `MEMORY.md` (status, decisions, session log), this file (facts/layout) and run the
  markdown fence check of the `memory-updater` skill.
