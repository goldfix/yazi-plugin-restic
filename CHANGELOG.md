# Changelog

All notable changes to `restic.yazi` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).
The `plugin-release` skill moves the `[Unreleased]` notes into a dated version section when a release is cut.

## [Unreleased]

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
