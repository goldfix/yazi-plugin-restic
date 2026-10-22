# Changelog

All notable changes to `restic.yazi` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).
The `plugin-release` skill moves the `[Unreleased]` notes into a dated version section when a release is cut.

## [Unreleased]

## [0.7.2] - 2026-10-22

No code change since 0.7.0: a documentation-only release (README and AGENTS fixes).

### Fixed
- README: the `ya pkg` pin example named a tag that does not exist (`v0.1.0`); the quick-start keymap lacked the `back`
  key (`b b`); the feature list claimed every restic backend works, while only local, SFTP, REST and S3 were tried.

## [0.7.1] - 2026-10-22

No code change since 0.7.0: a documentation-only release (README fixes).

## [0.7.0] - 2026-10-22

### Changed
- The suggested keys for the plugin actions moved from the `r` prefix to **`b`** ("backup"): `b r` restore, `b b` back,
  `b v` version. `r` alone is Yazi's *rename*, which the old `r e` / `r b` / `r v` suggestion turned into a prefix
  (`b` is unbound in Yazi's default keymap). Only the documented keymap changes, not the actions: an existing
  `keymap.toml` keeps working, and you can switch by editing its `on = [ "r", … ]` lines.

## [0.6.0] - 2026-10-21

### Added
- `Tab` (Yazi's spotter) shows details from the backup: for a file or folder the preview plus, for a folder, what it
  contains; for a snapshot (or `latest`) its record and backup run; for the session root or a `.restic` file the
  repository statistics (snapshots, hosts, stored size, compression). Needs the new `prepend_spotters` rules in
  `yazi.toml` (see the README); `.restic` files reuse the open repository's password or ask for it.
- `plugin restic -- leave` (bind it to `h` and `<Left>`): from the top of a browsing tree it returns to the `.restic` file the
  repository was opened from, highlighted; elsewhere it is Yazi's `leave`. `plugin restic -- back` jumps there from
  anywhere.

### Changed
- A folder that is still being read from the backup now shows a visible `(not listed yet)` file (it used to be a
  hidden `.unfetched` one, so Yazi said "No items"). Reopening a repository browsed with an earlier version removes
  the old hidden markers; `.unfetched` stays a reserved name (a backed-up file with that name is not shown).

### Fixed
- A folder listed through its snapshot folder and then reached through `latest` (or the other way round) showed
  "No backup information available", and `Enter` on one of its files opened the empty placeholder instead of
  fetching the file.

## [0.5.0] - 2026-10-21

### Added
- Browse restic snapshots from Yazi without FUSE: a "ghost" tree of real folders and 0-byte files in the OS temp
  dir, expanded lazily one level at a time; `latest` alias for the newest snapshot.
- Hover preview with the metadata stored in the backup (type, size, dates, permissions, owner).
- `<Enter>` on a ghost file restores it on demand into the ghost tree and opens it.
- `plugin restic -- restore` restores the selection (or hovered entry) to a chosen directory, in one
  `restic restore` call per snapshot (several `--include`), with a progress message, the elapsed time at the end,
  and the selection cleared on success.
- `.restic` configuration file (`repository`, `restic_exec`, `ssh_batch_mode`); the password is asked once per
  session and kept in memory only.
- sftp repositories run ssh in `BatchMode` so it never prompts inside the TUI (`ssh_batch_mode = no` to opt out).
- `plugin restic -- version` shows the installed plugin version.
- Installation with Yazi's package manager: `ya pkg add goldfix/yazi-plugin-restic:restic` (`restic.yazi/README.md`
  and `restic.yazi/LICENSE` are git symlinks to the single root files; covered by a test that runs the real `ya`).
- Packaging for hand-made installs: `plugin-release` skill (checks, versioned builds in `dist/`, `install.sh` with a
  warning when `ya pkg` already manages the plugin, release with tag).
- `sample_backup.restic`: annotated template of the `.restic` file (local, sftp, REST, S3, B2, Azure, GCS, rclone),
  shipped with every build and checked by the test suite.
- Reuse of the ghost tree when a repository is opened again; per-user private (mode 700) temp folder.
- Snapshot folders are named with the date and time in the viewer's local time zone (like `restic snapshots`), and
  `latest` is the newest snapshot by actual instant, also when hosts in different time zones share a repository.
