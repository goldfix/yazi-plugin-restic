# restic.yazi

**Browse and restore [restic](https://restic.net/) backups from inside [Yazi](https://yazi-rs.github.io/) — as if the
snapshots were ordinary folders.**

Looking *inside* a restic backup normally means typing commands or mounting the repository with FUSE (awkward on macOS,
often unavailable). Point Yazi at a small `.restic` file, type the repository password, and every snapshot shows up as
a folder you can walk through with the keys you already know.

- **Browse snapshots like folders**, plus a `latest` shortcut. Folders are read from the backup only when you look at
  them, so it starts instantly even on huge repositories.
- **See what the backup knows** about the highlighted entry (size, dates, permissions, owner, original path, local
  copy). `Tab` shows more: folder contents, snapshot details, repository statistics.
- **Open a file straight from the backup** with `Enter`: it is fetched, then opened with your usual program.
- **Restore** one or many files and folders to any directory. It runs as a Yazi task, with its progress in the status
  bar and in the task manager (`w`), and can be stopped with a key.
- **No FUSE, nothing mounted**, no daemon. The password is asked once per session and lives only in memory.
- Repository locations: local disks, SFTP, REST server and S3 (or S3-compatible) are tried; B2, Azure, Google Cloud,
  rclone… are handled by restic itself and should work the same, but are untried.

> **Status:** works end to end and is covered by unit, integration and real-Yazi end-to-end tests. Known gaps:
> [Development](https://github.com/goldfix/yazi-plugin-restic/blob/main/docs/DEVELOPMENT.md#known-limitations-and-open-points).
> How it works inside: [How it works](https://github.com/goldfix/yazi-plugin-restic/blob/main/docs/HOW_IT_WORKS.md).

---

## TL;DR

**Requirements:** Yazi 26.9+, `restic` 0.17.0+, macOS (developed and tested here) or Linux. Windows is untested.

### 1. Install

```sh
ya pkg add goldfix/yazi-plugin-restic:restic
```

Without `ya pkg` (offline, or to test a local build), clone the repository, build the package (needs only `git` and
`python3`) and run its script:

```sh
git clone https://github.com/goldfix/yazi-plugin-restic && cd yazi-plugin-restic
python3 .agents/skills/plugin-release/scripts/release.py build --skip-checks
dist/latest/install.sh          # copies the plugin into ~/.config/yazi/plugins/restic.yazi
```

> **Pick one method per machine.** `ya pkg` refuses to touch a plugin folder that no longer matches the hash it
> recorded, so mixing the two makes later `ya pkg` commands fail. To switch, remove the plugin first. See
> [Installing](#installing).

### 2. Tell Yazi about it

Add these snippets to your Yazi configuration folder (`~/.config/yazi/`); [Configuring Yazi](#configuring-yazi) explains them.

```lua
-- init.lua
require("restic"):setup()
```

```toml
# yazi.toml
[plugin]
prepend_previewers = [ { url = "/tmp/yazi-restic-*/**", run = "restic" } ]
prepend_spotters = [
  { url = "/tmp/yazi-restic-*/**",  run = "restic" },   # files in the browsing tree
  { url = "/tmp/yazi-restic-*/**/", run = "restic" },   # folders in the browsing tree
  { url = "*.restic",               run = "restic" },   # repository statistics
]
```

```toml
# keymap.toml
[[mgr.prepend_keymap]]
on  = "<Enter>"
run = "plugin restic -- enter"      # open a repository / fetch+open a backed-up file / otherwise behave as usual

[[mgr.prepend_keymap]]
on  = "<Left>"
run = "plugin restic -- leave"      # like "up one level"; from the top of a backup it returns to the .restic file

[[mgr.prepend_keymap]]
on  = "h"
run = "plugin restic -- leave"      # the same for the vim key (two entries: a list in `on` would be a key sequence)

[[mgr.prepend_keymap]]
on  = [ "b", "b" ]
run = "plugin restic -- back"       # jump to the .restic file of the open repository, from anywhere

[[mgr.prepend_keymap]]
on  = [ "b", "r" ]
run = "plugin restic -- restore"    # restore the selected (or hovered) entries

[[mgr.prepend_keymap]]
on  = [ "b", "x" ]
run = "plugin restic -- cancel"     # stop the restore in progress

[[mgr.prepend_keymap]]
on  = [ "b", "v" ]
run = "plugin restic -- version"    # show the installed version
```

### 3. Create a `.restic` file

A tiny text file that says where a repository lives. Put it anywhere; the name is up to you, only the `.restic`
extension matters.

```ini
# ~/backups/laptop.restic: a local or external disk (a relative path is relative to this file)
repository = /Volumes/BackupDisk/restic-repo
```

```ini
# ~/backups/nas.restic: another machine over SFTP
repository = sftp:backupuser@192.168.1.100:/srv/restic-repo
```

More kinds (REST, S3, B2…) in [The `.restic` file](#the-restic-file), or copy the annotated template
[`sample_backup.restic`](https://github.com/goldfix/yazi-plugin-restic/blob/main/sample_backup.restic) (it is also next
to `install.sh` in every build).

### 4. Use it

| You want to… | Do this |
|---|---|
| Open a repository | highlight the `.restic` file, press `Enter`, type the password |
| Browse | `h` `j` `k` `l` as always: one folder per snapshot, plus `latest` |
| See details | highlight a file or folder; `Tab` for more (also on a snapshot or a `.restic` file) |
| Open a backed-up file | `Enter` on it |
| Restore / stop | select entries (or highlight one), `b` `r`, type the destination / `b` `x` |

---

## Configuration

Three places are involved: Yazi's own configuration (once), the `.restic` file (one per repository), and a few
environment variables for some backends.

### Installing

Both ways put the plugin into `plugins/restic.yazi/` and never edit your configuration files.

**With `ya pkg`** (recommended). `ya` ships with Yazi (same version as `yazi`) and only talks to GitHub:

```sh
ya pkg add goldfix/yazi-plugin-restic:restic   # install
ya pkg upgrade                                 # move every package to the newest commit of its default branch
ya pkg install                                 # on a new machine: install exactly what package.toml records
ya pkg delete goldfix/yazi-plugin-restic:restic
```

- `ya pkg` follows the **default branch**, never tags. To stay on a release, edit `~/.config/yazi/package.toml` and put
  an `=` before the reference (`rev = "=v0.8.0"`), then run `ya pkg install`; `upgrade` skips pinned packages.
- The version shown by `b` `v` is the last *released* version; the exact commit you run is the `rev` in `package.toml`.
- Do not edit the installed files: `ya pkg` stores a hash and aborts on changes (`--discard` overrides it).

**With the install script**, for offline use or a local build. `release.py build` also writes a reproducible
`dist/restic.yazi-<version>.tar.gz` and its `.sha256`: unpack it anywhere and run the `install.sh` inside. The script
copies the plugin into `$YAZI_CONFIG_HOME/plugins` (default `~/.config/yazi/plugins`), replacing its previous
installation, and prints where `sample_backup.restic` is. It refuses to replace a symlinked folder (a development
checkout is safe) and warns if `package.toml` already lists the plugin. Update by building again and re-running it.

### Configuring Yazi

Everything lives in Yazi's configuration folder: `~/.config/yazi/` (or `$YAZI_CONFIG_HOME`; on Windows
`%AppData%\yazi\config\`). The snippets are in the [TL;DR](#2-tell-yazi-about-it).

- **`init.lua`** registers the hooks that list folders lazily as you move around. Required.
- **`yazi.toml`** has the previewer that shows the backup details of the highlighted entry (required for the details
  pane) and the spotter behind `Tab` (optional: without it `Tab` keeps doing what Yazi does). The pattern is where the
  plugin keeps its temporary tree on macOS/Linux. Yazi matches files and folders with separate rules (a trailing `/`
  means "folders"), hence two spotter rules for the tree; the third one makes `Tab` work on `.restic` files.
- **`keymap.toml`** binds the keys. The plugin has six actions, bind them to whatever you like:

| Action | What it does |
|---|---|
| `plugin restic -- enter` | "Smart enter": on a `.restic` file opens the repository; on a backed-up file fetches and opens it; anywhere else behaves like Yazi's own `Enter`. |
| `plugin restic -- leave` | "Smart leave": from the top of a browsing tree (the folder listing the snapshots) goes back to the `.restic` file, highlighted; anywhere else behaves like Yazi's own `leave`. |
| `plugin restic -- back` | Jumps to the `.restic` file of the open repository from anywhere. |
| `plugin restic -- restore` | Restores the selected entries (or the highlighted one) to a folder you type. Entries of one snapshot go into a single `restic restore`. A second restore while one runs is refused. |
| `plugin restic -- cancel` | Stops the restore in progress: restic is killed at once. Files already written stay and the selection is kept. |
| `plugin restic -- version` | Shows the installed plugin version (dev builds read `X.Y.Z-dev.<sha>`). |

If you do not want to change `Enter`, `h` or `←`, bind `plugin restic -- enter` to another key (for example
`on = "o"`); the rest works the same. Pick keys that are free in your keymap: the `b` prefix used here is unbound in
Yazi's default keymap and leaves `r` (rename) alone; if you use `b` already, pick another free prefix (`e`, `u`, `B`…).

### The `.restic` file

A plain text file, **one `key = value` per line**:

- Lines starting with `#` or `;` are comments, **on their own line**: never after a value, because values are taken
  exactly as written (`#` can be part of a path).
- Keys are case-insensitive, unknown keys are ignored, the last of a repeated key wins.
- Quotes around a value are optional (`repository = "/Volumes/My Disk/repo"`); `~` means your home directory.
- The password is **not** stored in the file (see [Password](#password)).

| Key | Required | Default | Meaning |
|---|---|---|---|
| `repository` | yes | — | Where the repository is: anything `restic -r` accepts. |
| `restic_exec` | no | `restic` from `$PATH` | Path of the restic binary (0.17.0 or newer). Needed when Yazi cannot find `restic` on its `PATH` (apps started from a launcher) or to pick a specific version. |
| `ssh_batch_mode` | no | `yes` | SFTP only, see [SFTP repositories](#sftp-repositories). Accepts `yes`/`no`, `true`/`false`, `on`/`off`, `1`/`0`. |

The binary is probed with `restic version` every time a repository is opened; a missing or too old restic is reported
with a clear message.

```ini
# ~/backups/nas.restic
repository     = sftp:backupuser@nas.local:/srv/restic-repo
restic_exec    = /opt/homebrew/bin/restic
ssh_batch_mode = yes
```

#### `repository` examples

A relative local path is relative to the folder containing the `.restic` file, so a repository next to its file keeps
working if you move both.

```ini
# local disks
repository = /Volumes/BackupDisk/restic-repo
repository = ~/backups/restic-repo
repository = ./repo
repository = C:\Backups\restic-repo

# SFTP: user@host:/absolute/path (no leading "/" = relative to the remote home)
repository = sftp:backupuser@192.168.1.100:/srv/restic-repo
# URL form, for a port or an IPv6 address: note the DOUBLE slash before an absolute path
repository = sftp://backupuser@nas.local:2222//srv/restic-repo
# an alias from ~/.ssh/config (user, port, key… are defined there)
repository = sftp:nas:/srv/restic-repo

# other backends, see "Credentials for other backends"
repository = rest:https://backup.example.org:8000/myrepo/       # restic REST server
repository = s3:s3.amazonaws.com/my-bucket/restic               # Amazon S3
repository = s3:https://minio.example.org:9000/my-bucket/restic # S3-compatible (MinIO, Wasabi…)
repository = b2:my-bucket:restic                                # Backblaze B2
repository = azure:my-container:/restic                         # Azure Blob Storage
repository = gs:my-bucket:/restic                               # Google Cloud Storage
repository = rclone:mydrive:backups/restic                      # anything rclone knows (rclone must be installed)
```

> The trailing `#` comments are only here for the README: in a real `.restic` file put them on their own line. The
> annotated [`sample_backup.restic`](https://github.com/goldfix/yazi-plugin-restic/blob/main/sample_backup.restic)
> contains all these examples; copy it, keep one `repository` line and edit it.

### Password

Yazi shows a masked prompt when you open a repository. The password is kept **in memory only** for the rest of the Yazi
session: never written to disk, never put on a command line (it reaches restic through `RESTIC_PASSWORD`). One
repository is open at a time; opening another replaces it. For that reason the plugin ignores `RESTIC_PASSWORD_FILE`,
`RESTIC_PASSWORD_COMMAND` and `RESTIC_REPOSITORY_FILE` if they are set: they would override the password you type or
conflict with the `.restic` file.

### SFTP repositories

restic starts `ssh` for `sftp:` repositories. If ssh had to ask something (a key passphrase, a password, "do you trust
this host?") it would write onto the terminal Yazi is drawing on. So, by default, the plugin tells ssh never to ask
(`-o BatchMode=yes`): it fails at once and Yazi shows ssh's own message plus a hint. For you this means:

- use a **key without passphrase**, or one loaded in **`ssh-agent`**;
- connect once from a normal terminal (`ssh backupuser@nas.local`) to accept the host key;
- password logins do not work in this mode.

If you know that ssh can safely prompt in your setup, turn the protection off in that repository's file with
`ssh_batch_mode = no`.

### Credentials for other backends

REST, S3, B2, Azure, Google Cloud and rclone get their credentials from **environment variables**, read from the
environment Yazi was started with (for example `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for S3, `B2_ACCOUNT_ID`
and `B2_ACCOUNT_KEY` for B2, `RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD` for REST). See
[restic's documentation](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html) for each backend. Never
put secrets in the `.restic` file.

### Where things go

| What | Where |
|---|---|
| The browsing tree (placeholders and files you opened) | `/tmp/yazi-restic-<uid>/<repository id>/` (`%TEMP%\yazi-restic` on Windows), private (mode `700`). The operating system clears `/tmp` eventually; there is no explicit cleanup. |
| Restored files (`b` `r`) | The folder you type in the prompt (suggested: `~/restic-restore`), absolute (`~` is fine) and outside the browsing tree. The backed-up path is kept below it (restoring `/home/me/docs` into `~/out` gives `~/out/home/me/docs`) and existing files are overwritten. |
| Your configuration | untouched: the plugin writes nothing there. |

---

## Troubleshooting

| Message | Meaning |
|---|---|
| `wrong password` | The typed password does not open the repository. Nothing was created. |
| `cannot execute restic binary '…'` | restic not found: install it or set `restic_exec`. |
| `restic X.Y.Z found, 0.17.0 or newer is required` | Upgrade restic. |
| `ssh: … — ssh cannot ask questions inside Yazi` | See [SFTP repositories](#sftp-repositories). |
| `Fatal: repository does not exist` | Wrong `repository` value (relative paths start at the `.restic` file). |
| `The repository has no snapshots` | The repository opened but is empty. |
| `Nothing to restore here` | The highlighted entries are not inside a snapshot. |
| `N selected item(s) are not in the backup and will be skipped` | The selection (Yazi keeps it across folders) also holds files outside the snapshots; the rest is restored. |
| `… is already being restored` | The same file is being fetched; wait for it. |
| A file called `(not listed yet)` | The folder is being read from the backup and it disappears when done. If it stays, the listing failed (an error was shown): leave the folder and enter it again. |
| `h` / `←` at the top of a backup does not go back to the `.restic` file | The key is not bound to `plugin restic -- leave` (see [Configuring Yazi](#configuring-yazi)); `b` `b` works from anywhere. |
| `Error: Lua runtime failed … Failed to load plugin from …/restic.yazi/main.lua` when Yazi starts | `init.lua` calls `require("restic")` but the plugin is not in `~/.config/yazi/plugins/restic.yazi`. Install it again, see [Installing](#installing). |
| Nothing happens on `Enter` / `b r` | The keymap is missing, or the plugin is not in `plugins/restic.yazi`. Press `b` `v` to check. |
| A restore takes longer than the notification | Press `w`: Yazi's task manager lists it with its progress. A failed restore stays there and `<Enter>` shows the reason (the log). |
| I want to stop a restore | Press `b` `x`: restic is killed and `Restore cancelled` confirms it. `x` in the task manager is not enough: it only removes the entry, and Yazi 26.9 tells plugins nothing about it, so restic would go on unseen (`b` `x` still stops it, and a new restore is refused until it ends). |
| After stopping a restore, `restic` complains about a lock, or `prune` waits | Stopping kills restic abruptly, so it cannot remove the (shared) lock it took. A local repository detects the dead process by itself; a remote one goes stale after 30 minutes, or run `restic unlock -r <repository>`. It never blocks browsing or restoring. |

---

## More

- [How it works](https://github.com/goldfix/yazi-plugin-restic/blob/main/docs/HOW_IT_WORKS.md): the ghost filesystem,
  what each action runs, privacy and safety.
- [Development](https://github.com/goldfix/yazi-plugin-restic/blob/main/docs/DEVELOPMENT.md): building, tests, project
  structure, releases, known limitations and open points.
- [CHANGELOG.md](https://github.com/goldfix/yazi-plugin-restic/blob/main/CHANGELOG.md) and
  [AGENTS.md](https://github.com/goldfix/yazi-plugin-restic/blob/main/AGENTS.md) (notes for contributors and agents).

## License

MIT — see [LICENSE](https://github.com/goldfix/yazi-plugin-restic/blob/main/LICENSE) (a copy is shipped inside the
plugin folder).
