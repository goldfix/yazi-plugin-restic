# restic.yazi

**Browse and restore [restic](https://restic.net/) backups from inside [Yazi](https://yazi-rs.github.io/) — as if the
snapshots were ordinary folders.**

[restic](https://restic.net/) is a popular backup tool, but looking *inside* a backup normally means typing commands or
mounting the repository with FUSE (which is awkward on macOS and often unavailable). `restic.yazi` removes that
friction. Point Yazi at a small `.restic` file, type the repository password, and every snapshot shows up as a folder
you can walk through with the keys you already know.

What you get:

- **Browse snapshots like folders**, with Yazi's three-column view, including a `latest` shortcut to the newest one.
- **Instant start, even on huge repositories.** Folders are read from the backup only when you look at them.
- **See what the backup knows** about the highlighted file or folder: size, dates, permissions, owner, original path,
  and whether you already have a local copy. Press `Tab` for more: what a folder contains, the details of a snapshot
  (host, paths, tags, how long the backup took, how many files changed…) and the statistics of the whole repository
  (number of snapshots, space used, compression).
- **Open a file straight from the backup.** Press `Enter` and the file is fetched and opened with your usual program.
- **Restore** one or many files and folders to any directory.
- **No FUSE, nothing mounted**, no daemon, nothing to clean up by hand.
- Works with restic's repository locations: local disks, SFTP, REST server and S3 (or S3-compatible) are tried;
  B2, Azure, Google Cloud, rclone… are handled by restic itself and should work the same, but are untried.

The password is asked once per session and lives only in memory.

> **Status:** works end to end and is covered by unit, integration and real-Yazi end-to-end tests. See
> [Open points](#open-points-and-ideas) for the known gaps.

---

## TL;DR

**Requirements:** Yazi 26.9+, `restic` 0.17.0+, macOS (developed and tested here) or Linux. Windows is untested.

### 1. Install

**Option A — Yazi's package manager (recommended).** One command, and `ya pkg upgrade` keeps it current:

```sh
ya pkg add goldfix/yazi-plugin-restic:restic
```

**Option B — the install script**, for when you do not want `ya pkg`, work offline, or want to test a local build.
Clone the repository, build the package (needs only `git` and `python3`) and run the script that comes with it:

```sh
git clone https://github.com/goldfix/yazi-plugin-restic && cd yazi-plugin-restic
python3 .agents/skills/plugin-release/scripts/release.py build --skip-checks
dist/latest/install.sh          # copies the plugin into ~/.config/yazi/plugins/restic.yazi
```

> **Pick one method per machine.** `ya pkg` records a hash of the files it installed and refuses to touch a plugin
> folder that no longer matches. So if you install with the script over a plugin managed by `ya pkg` (or the other way
> round), later `ya pkg add/upgrade/install` stop with *"You have modified the contents of the `restic.yazi`
> plugin"*. The script prints a warning when it sees this. To switch method, remove the plugin first
> (`ya pkg delete goldfix/yazi-plugin-restic:restic`, or delete `plugins/restic.yazi`). Details in
> [Installing](#installing).

### 2. Tell Yazi about it

Add these three snippets to your Yazi configuration folder (`~/.config/yazi/`). Details in
[Configuring Yazi](#configuring-yazi).

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
on  = [ "b", "v" ]
run = "plugin restic -- version"    # show the installed version
```

### 3. Create a `.restic` file

A `.restic` file is a tiny text file that says where a repository lives. Put it anywhere (a good place is a folder of
yours called `backups`). The file name is up to you, only the `.restic` extension matters.

A repository on a local or external disk (`~` works; a relative path is relative to the `.restic` file itself):

```ini
# ~/backups/laptop.restic
repository = /Volumes/BackupDisk/restic-repo
```

A repository on another machine over SFTP:

```ini
# ~/backups/nas.restic
repository = sftp:backupuser@192.168.1.100:/srv/restic-repo
```

There are many more kinds (REST, S3, B2…), see [The `.restic` file](#the-restic-file), or copy the annotated template
[`sample_backup.restic`](https://github.com/goldfix/yazi-plugin-restic/blob/main/sample_backup.restic) (it is also next
to `install.sh` in every build).

### 4. Use it

| You want to… | Do this |
|---|---|
| Open a repository | highlight the `.restic` file, press `Enter`, type the password |
| Browse | `h` `j` `k` `l` as always — one folder per snapshot, plus `latest` |
| See backup details | just highlight a file or folder |
| See more details | `Tab` on a file, folder or snapshot; `Tab` on a `.restic` file for the repository statistics |
| Open a backed-up file | `Enter` on it (it is fetched, then opened) |
| Restore | select entries (or highlight one), press `b` `r`, type the destination folder |

For all options and the full list of keys, read on: [Configuration](#configuration).

---

## Configuration

Three places are involved: Yazi's own configuration (once), the `.restic` file (one per repository), and a few
environment variables for some backends.

### Installing

There are two supported ways to get the plugin into `plugins/restic.yazi/`. Both need the three configuration
snippets of [Configuring Yazi](#configuring-yazi) afterwards.

#### With `ya pkg` (recommended)

`ya` ships with Yazi and must be the same version as `yazi`. It only talks to GitHub: it clones the repository, copies
the plugin folder (`restic.yazi/`) into `plugins/` and records the commit in `~/.config/yazi/package.toml`:

```sh
ya pkg add goldfix/yazi-plugin-restic:restic   # install
ya pkg list                                    # what ya manages
ya pkg upgrade                                 # move every package to the newest commit of its default branch
ya pkg install                                 # on a new machine: install exactly what package.toml records
ya pkg delete goldfix/yazi-plugin-restic:restic
```

Things worth knowing:

- `ya pkg` follows the **default branch**, never tags or releases. To stay on a release, edit `package.toml` and put
  an `=` before the reference — `rev = "=v0.7.0"` (a tag or commit) — then run `ya pkg install`; `upgrade` skips
  pinned packages.
- The version shown by `b` `v` is the last *released* version written in the plugin; the exact commit you run is the
  `rev` in `package.toml`.
- Do not edit the installed files: `ya pkg` stores a hash and aborts on changes (`--discard` overrides it).

#### With the install script

For offline use, for testing a local build, or if you prefer not to use `ya pkg`. In a clone of the repository:

```sh
python3 .agents/skills/plugin-release/scripts/release.py build --skip-checks   # creates dist/
dist/latest/install.sh                                                         # or: YAZI_CONFIG_HOME=… dist/latest/install.sh
```

`dist/` also holds a reproducible `restic.yazi-<version>.tar.gz` and its `.sha256`: unpack it anywhere (on another
machine too) and run the `install.sh` inside. The script copies the plugin into `$YAZI_CONFIG_HOME/plugins` (default
`~/.config/yazi/plugins`), replacing a previous installation of itself, prints where `sample_backup.restic` is, and
leaves your configuration files alone. It refuses to replace a symlinked folder, so a development checkout linked
into `plugins/` is safe. Update by building again and re-running it.

> The script is meant for local, hand-made installs. If `package.toml` lists the plugin it prints a warning, because
> replacing a plugin that `ya pkg` manages breaks the next `ya pkg` operation on it (see the note in the TL;DR).

### Configuring Yazi

Everything lives in Yazi's configuration folder: `~/.config/yazi/` (or `$YAZI_CONFIG_HOME`; on Windows
`%AppData%\yazi\config\`). The plugin itself sits in `plugins/restic.yazi/` there — `ya pkg` or `install.sh` puts it in
place (see [Installing](#installing)); neither ever edits your configuration files.

**`init.lua`** — registers the hooks that list folders lazily as you move around. Required.

```lua
require("restic"):setup()
```

**`yazi.toml`** — the previewer that shows the backup details of the highlighted entry (required for the details
pane) and the spotter behind `Tab` (optional: without it `Tab` keeps doing what Yazi does, showing the mime type). The
pattern is where the plugin keeps its temporary tree on macOS/Linux (on Windows the temporary folder is different;
Windows is untested). Yazi matches files and folders with separate rules (a trailing `/` means "folders"), hence the
two spotter rules for the tree; the third one makes `Tab` work on `.restic` files.

```toml
[plugin]
prepend_previewers = [
  { url = "/tmp/yazi-restic-*/**", run = "restic" },
]
prepend_spotters = [
  { url = "/tmp/yazi-restic-*/**",  run = "restic" },   # files in the browsing tree
  { url = "/tmp/yazi-restic-*/**/", run = "restic" },   # folders in the browsing tree
  { url = "*.restic",               run = "restic" },   # repository statistics
]
```

**`keymap.toml`** — the keys. The plugin has five actions, bind them to whatever you like:

| Action | What it does |
|---|---|
| `plugin restic -- enter` | "Smart enter": on a `.restic` file opens the repository; on a backed-up file fetches it and opens it; anywhere else behaves exactly like Yazi's own `Enter`. |
| `plugin restic -- leave` | "Smart leave": from the top of a browsing tree (the folder that lists the snapshots) it goes back to the folder of the `.restic` file you opened, with the file highlighted; anywhere else it behaves exactly like Yazi's own `leave` (`h`). |
| `plugin restic -- back` | Jumps to the `.restic` file of the open repository from anywhere, even deep inside a snapshot. |
| `plugin restic -- restore` | Restores the selected entries (or the highlighted one) to a folder you type. |
| `plugin restic -- version` | Shows the installed plugin version in a notification (dev builds read `X.Y.Z-dev.<sha>`). |

```toml
[[mgr.prepend_keymap]]
on   = "<Enter>"
run  = "plugin restic -- enter"
desc = "Open (restic aware)"

[[mgr.prepend_keymap]]
on   = "<Left>"
run  = "plugin restic -- leave"
desc = "Leave (back to the .restic file from the top of a backup)"

[[mgr.prepend_keymap]]
on   = "h"
run  = "plugin restic -- leave"
desc = "Leave (back to the .restic file from the top of a backup)"

[[mgr.prepend_keymap]]
on   = [ "b", "b" ]
run  = "plugin restic -- back"
desc = "Back to the .restic file of the open repository"

[[mgr.prepend_keymap]]
on   = [ "b", "r" ]
run  = "plugin restic -- restore"
desc = "Restore the selected files/folders from the restic backup"

[[mgr.prepend_keymap]]
on   = [ "b", "v" ]
run  = "plugin restic -- version"
desc = "Show the restic.yazi version"
```

If you do not want to change `Enter`, `h` or `←`, bind `plugin restic -- enter` to another key, for example `on = "o"`; the rest
works the same. Pick keys that are free in your own keymap: the `b` prefix ("backup") used here is
unbound in Yazi's default keymap, which leaves `r` (rename) alone; if you already use `b` for something else, pick
another free prefix (`e`, `u`, `B`, `R`…) for the restore/back/version keys.

### The `.restic` file

A plain text file, **one `key = value` per line**. Rules:

- Lines starting with `#` or `;` are comments. A comment must be **on its own line**: never write one after a value,
  because values are taken exactly as written (`#` can be part of a path).
- Keys are case-insensitive. Unknown keys are ignored. If a key appears twice, the last one wins.
- Quotes around a value are optional (`repository = "/Volumes/My Disk/repo"`).
- `~` at the start of a path means your home directory.
- The password is **not** stored in the file (see [Password](#password)).

| Key | Required | Default | Meaning |
|---|---|---|---|
| `repository` | yes | — | Where the repository is: anything `restic -r` accepts. |
| `restic_exec` | no | `restic` from `$PATH` | Path of the restic binary to use. Needs restic 0.17.0 or newer. |
| `ssh_batch_mode` | no | `yes` | SFTP only. See [SFTP repositories](#sftp-repositories). Accepts `yes`/`no`, `true`/`false`, `on`/`off`, `1`/`0`. |

#### `repository` examples

**Local disks.** A relative path is relative to the folder that contains the `.restic` file, so a repository placed
next to its `.restic` file keeps working if you move both.

```ini
repository = /srv/restic-repo
repository = /Volumes/BackupDisk/restic-repo
repository = ~/backups/restic-repo
repository = ./repo
repository = "/Volumes/My Backup Disk/restic repo"
repository = C:\Backups\restic-repo
repository = \\nas\backups\restic-repo
```

**SFTP.**

```ini
# user@host:/absolute/path
repository = sftp:backupuser@192.168.1.100:/srv/restic-repo

# no leading "/": relative to the remote user's home directory
repository = sftp:backupuser@nas.local:restic-repo

# URL form, needed for a port or an IPv6 address. Note the DOUBLE slash before an absolute path:
# the first "/" ends the connection part, the second starts the path.
repository = sftp://backupuser@nas.local:2222//srv/restic-repo
repository = sftp://backupuser@[::1]:2222//srv/restic-repo

# an alias from ~/.ssh/config (user, port, key… are defined there)
repository = sftp:nas:/srv/restic-repo
```

**Other backends** — see [Credentials for other backends](#credentials-for-other-backends):

```ini
repository = rest:https://backup.example.org:8000/myrepo/       # restic REST server
repository = s3:s3.amazonaws.com/my-bucket/restic               # Amazon S3
repository = s3:https://minio.example.org:9000/my-bucket/restic # S3-compatible (MinIO, Wasabi…)
repository = b2:my-bucket:restic                                # Backblaze B2
repository = azure:my-container:/restic                         # Azure Blob Storage
repository = gs:my-bucket:/restic                               # Google Cloud Storage
repository = rclone:mydrive:backups/restic                      # anything rclone knows (rclone must be installed)
```

> The `#` comments above are only here for the README: in a real `.restic` file put them on their own line.

#### `restic_exec`

Needed only when Yazi cannot find `restic` on its `PATH` (typical for apps started from a launcher), or to pick a
specific version:

```ini
restic_exec = /opt/homebrew/bin/restic
restic_exec = ~/bin/restic
restic_exec = C:\Tools\restic\restic.exe
```

The binary is probed with `restic version` every time a repository is opened; a missing or too old (< 0.17.0) restic
is reported with a clear message.

#### A complete example

```ini
# ~/backups/nas.restic
repository     = sftp:backupuser@nas.local:/srv/restic-repo
restic_exec    = /opt/homebrew/bin/restic
ssh_batch_mode = yes
```

The annotated template
[`sample_backup.restic`](https://github.com/goldfix/yazi-plugin-restic/blob/main/sample_backup.restic) contains all the
examples above with explanations. Copy it, keep one `repository` line and edit it.

### Password

When you open a repository, Yazi shows a masked prompt. The password is kept **in memory only** for the rest of the
Yazi session — never written to disk and never put on a command line (it reaches restic through the
`RESTIC_PASSWORD` environment variable). Only one repository is open at a time; opening another replaces it.

Because of that, the plugin deliberately ignores `RESTIC_PASSWORD_FILE`, `RESTIC_PASSWORD_COMMAND` and
`RESTIC_REPOSITORY_FILE` if they are set in your environment: they would silently override the password you type or
conflict with the `.restic` file.

### SFTP repositories

For `sftp:` repositories restic starts `ssh`. If ssh needed to ask something — a key passphrase, a password, "do you
trust this host?" — it would write the question onto the terminal Yazi is drawing on, garbling the screen or leaving
the plugin waiting for an answer you cannot see. So, by default, the plugin tells ssh never to ask
(`-o BatchMode=yes`): it fails immediately and Yazi shows ssh's own message plus a hint.

What this means for you:

- Use a **key without passphrase**, or one loaded in **`ssh-agent`**.
- Connect to the server **once from a normal terminal** (`ssh backupuser@nas.local`) to accept its host key.
- Password logins do not work in this mode.

If you really want ssh to be able to prompt (you know it is safe in your setup), turn the protection off in that
repository's file:

```ini
ssh_batch_mode = no
```

### Credentials for other backends

REST, S3, B2, Azure, Google Cloud and rclone repositories get their credentials from **environment variables**, which
restic reads from the environment Yazi was started with (for example `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` for
S3, `B2_ACCOUNT_ID` and `B2_ACCOUNT_KEY` for B2, `RESTIC_REST_USERNAME`/`RESTIC_REST_PASSWORD` for a REST server).
See [restic's documentation](https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html) for the variables
of each backend. Do not put secrets in the `.restic` file. (Amazon S3, S3-compatible buckets and a REST server have been
tried by hand and work. B2, Azure, Google Cloud and rclone have not been tried; the automated tests cover only local and
SFTP-over-local-`sftp-server` repositories.)

### Where things go

| What | Where |
|---|---|
| The browsing tree (placeholders and files you opened) | `/tmp/yazi-restic-<uid>/<repository id>/` (`%TEMP%\yazi-restic` on Windows). Private (mode `700`) and owned by you. The operating system clears `/tmp` eventually; there is no explicit cleanup. |
| Restored files (`b` `r`) | The folder you type in the prompt; the suggestion is `~/restic-restore`. It must be an absolute path (`~` is fine) outside the browsing tree. The backed-up path is kept below it (restoring `/home/me/docs` into `~/out` gives `~/out/home/me/docs`) and existing files are overwritten. |
| Your configuration | untouched; the plugin writes nothing there. |

---

## Using it

| Action | How |
|---|---|
| Open a repository | highlight a `.restic` file, `Enter`, type the password. Yazi jumps to the browsing tree: one folder per snapshot, named `<date>__<id>__<host>__[<tags>]` (date and time in **your** local time zone, as `restic snapshots` prints them), newest last, plus `latest`. |
| Browse | the usual `h`/`j`/`k`/`l`. A folder is listed the first time you enter it *or rest the cursor on it* (so the preview column shows its content). |
| See backup details | highlight any entry: type, size, permissions, owner, modified/accessed/changed dates, original path, local copy yes/no. |
| More details | `Tab` opens Yazi's "spot" table (by default `Tab` or `Esc` closes it, `j`/`k` scroll, `h`/`l` jump to the previous/next entry, `c` `c` copies the selected cell). On a **file or folder** of a snapshot it repeats the preview and, for a folder, adds what it directly contains (items and the size of its files). On a **snapshot** folder (or `latest`) it shows the snapshot: id, time, host, user, paths, tags, excludes, tree and parent ids, restic version and, when restic recorded it (0.17+), the backup run: duration, files and folders new/changed/unmodified, data processed and added. On the **session root** or on a **`.restic` file** it shows the repository: number of snapshots, first and last, hosts, the latest snapshot's size, and the storage statistics (stored size, size without compression, compression ratio, blobs). The snapshot part appears at once and the storage figures a moment later: restic reads the folder structure of every snapshot (not the file contents; each distinct folder once, usually from its local cache), which takes a few seconds on a large or remote repository. Closing the table stops it. On a `.restic` file the password of the repository you have open is reused; otherwise you are asked for it (and, as always, it is not kept). With entries selected, `Tab` in the browsing tree still describes the highlighted entry (Yazi's own multi-selection summary would add up the sizes of the empty placeholders). |
| Open a file | `Enter`. Files appear as empty placeholders; the real content is fetched from the backup, then opened with whatever program Yazi's `open` rules choose. Later `Enter`s on the same file open the local copy at once. |
| Restore | select entries with `Space` (or just highlight one), `b` `r`, confirm or edit the destination. Several entries from several snapshots can be restored at once; entries of the same snapshot go into a single `restic restore` call, a notification shows `Restoring 5 item(s) from snapshot e3e4a9ff` (with `(1/2)` when several snapshots are involved), and a final one the elapsed time. On success the selection is cleared; on failure it is kept, so you can retry. |
| Leave the backup | `h` or `←` as usual; at the top (the list of snapshots) one more press returns to the `.restic` file (needs the `leave` binding). `b` `b` jumps there from anywhere. |
| Installed version | `b` `v` |
| Reopen a repository | same as opening. Files you already fetched are still there; every folder is simply listed again once, so new snapshots appear. |

### Troubleshooting

| Message | Meaning |
|---|---|
| `wrong password` | The typed password does not open the repository. Nothing was created. |
| `cannot execute restic binary '…'` | restic not found: install it or set `restic_exec`. |
| `restic X.Y.Z found, 0.17.0 or newer is required` | Upgrade restic. |
| `ssh: … — ssh cannot ask questions inside Yazi` | See [SFTP repositories](#sftp-repositories). |
| `Fatal: repository does not exist` | Wrong `repository` value (remember relative paths start at the `.restic` file). |
| `The repository has no snapshots` | The repository opened but is empty. |
| `Nothing to restore here` | The highlighted entries are not inside a snapshot. |
| `N selected item(s) are not in the backup and will be skipped` | The selection (Yazi keeps it across folders) also holds files outside the snapshots; the rest is restored. |
| `… is already being restored` | The same file is being fetched; wait for it. |
| A file called `(not listed yet)` | The folder is being read from the backup; it disappears when the listing is done. If it stays, the listing failed (an error was shown): leave the folder and enter it again to retry. |
| `h` / `←` at the top of a backup does not go back to the `.restic` file | The key is not bound to `plugin restic -- leave` (see [Configuring Yazi](#configuring-yazi)); `b` `b` (`back`) works from anywhere. |
| `Error: Lua runtime failed … Failed to load plugin from …/restic.yazi/main.lua` when Yazi starts | `init.lua` calls `require("restic")` but the plugin is not in `~/.config/yazi/plugins/restic.yazi` (never installed, or the folder was deleted). Install it again, see [Installing](#installing). |
| Nothing happens on `Enter` / `b r` | The keymap is missing, or the plugin is not in `plugins/restic.yazi`. Press `b` `v` to check. |

### Privacy and safety

- The browsing tree is created with mode `700`, and the plugin refuses to use `/tmp/yazi-restic-<uid>` if it is not a
  real folder owned by you (protection against another user pre-creating it).
- Names in a backup that cannot exist safely on disk (empty, `.`, `..`, containing `/`, `\` or NUL) are skipped, and so
  are the two names the plugin reserves for its markers: `(not listed yet)` and `.unfetched` (used up to 0.5.0).
  Symbolic links in a backup appear as empty regular files — they are never created as real links, so a malicious
  backup cannot make the plugin touch files outside the tree.
- Restores never write into the browsing tree.

### Known limitations

- On case-insensitive filesystems (macOS default, Windows) backup entries whose names differ only by case collapse
  into one entry.
- On Windows, names that Windows forbids (`a:b`, `con`…) make their folder fail to list; Windows is otherwise untested.
- Restoring selections from several snapshots into one destination lets later snapshots overwrite earlier ones where
  paths overlap. If one path of a snapshot cannot be restored, that snapshot's whole group fails (the selection is kept).
- When a browsing tree is reused after the snapshot folder naming changed (e.g. you moved to another time zone), the
  affected snapshots are rebuilt and their already-fetched files are downloaded again.
- The browsing tree can only follow one repository at a time.

---

## How it works

### The "ghost filesystem"

Yazi can only browse real files, and mounting a repository needs FUSE. So the plugin builds a **ghost filesystem**:
a temporary tree of *real directories* and *0-byte placeholder files* that mirrors the backup, one level at a time.
Yazi's own engine then does all the navigating, sorting and previewing; the plugin only has to keep the tree filled in
and answer "what is this entry?".

```
 .restic file ──(Enter)──> main.lua ──> config.lua      read the file, find restic, check its version
                              │
                              ├──> client.lua           restic CLI: snapshots / ls / restore  (JSON in, errors out)
                              │
                              └──> ghost.lua            /tmp/yazi-restic-<uid>/<repo id>/
                                      │                   ├─ 2026-10-19_20-21-21__e3e4a9ff__host__[tag]/   one dir per snapshot
                                      │                   │    └─ data/  (+ a visible marker file while "not listed yet")
                                      │                   │         ├─ docs/        ← real directory
                                      │                   │         └─ a.txt        ← 0 bytes until opened
                                      │                   ├─ latest -> <newest snapshot dir>   (relative symlink)
                                      │                   └─ .staging/              scratch space for downloads
                                      │
 Yazi ── cd / hover ──> lazy listing   `restic ls <snapshot> <dir> --json`  → create children, keep metadata in memory
 Yazi ── Enter on a file ──────────>   `restic restore <id>:<dir> --include /<name>` → into .staging, rename into place
 Yazi ── b r ──────────────────────>   `restic restore <id> --target <dest> --include <path>`
 Yazi ── hover ──> previewer           shows the metadata of the entry (from memory, not from the 0-byte file)
 Yazi ── Tab ────> spotter             entry / snapshot details from memory; repository: `restic snapshots` + `restic stats`
```

The flow in words:

1. **Open.** `Enter` on a `.restic` file: parse it, find and version-check restic, ask for the password, run
   `restic snapshots --json`. Under `/tmp/yazi-restic-<uid>/<repository id>/` create one folder per snapshot (each
   carrying a marker file called `(not listed yet)`) and the `latest` link, then `cd` there. If the tree already exists from an
   earlier session it is **reused**: snapshots are immutable, so folders and fetched files stay valid; vanished
   snapshots are removed, new ones added, and every folder is re-marked so it is listed again once.
2. **Expand lazily.** Whenever Yazi enters a folder (`cd` hook) or the cursor rests on one for 0.4 s (`hover` hook, so
   the preview pane can show its content), and the folder carries the marker, the plugin runs
   `restic ls <snapshot> <path> --json` (one level, no recursion), creates the children (directories with a marker of
   their own, files as 0-byte placeholders), stores each child's metadata **in memory only**, and removes the marker. The marker is a normal, visible file on purpose: a folder that is still being read shows
   `(not listed yet)` (and "Reading this folder from the backup..." in the preview) instead of Yazi's "No items", which
   is left for folders that really are empty.
3. **Preview and spot.** A previewer plugin renders the stored metadata for the highlighted entry. The spotter
   (`Tab`) shows the same plus the snapshot record kept in memory when the repository was opened, the folder contents
   counted from the listed entries, or, for a repository, `restic snapshots` and `restic stats --mode raw-data` (run
   when you press `Tab`, never at startup). Paths through `latest` are stored under the real snapshot folder, so
   what was listed through one spelling is known through the other.
4. **Open a file.** On a 0-byte placeholder with a non-zero size in the backup, run
   `restic restore <id>:<parent dir> --include /<name>` into a private folder under `.staging/`, then rename the result
   over the placeholder. Using the `<id>:<folder>` form restores the file directly, without recreating its parent
   directories (whose possibly read-only permissions would otherwise prevent moving it). A file larger than 0 bytes is
   already cached and simply opened.
5. **Restore.** Ask for a destination, validate it, group the selected entries by snapshot (dropping the ones below another selected entry), then run one `restic restore … --include <path> --include <path>…` per snapshot: restic opens the repository once instead of once per entry.

Design decisions worth knowing:

- **No global parsing**, ever: cost is proportional to what you look at, not to the repository size.
- **`restore`, not `dump`**: streaming `restic dump` through Lua is about 5× slower in Yazi 26.9 (a 256 MB file: 0.8 s
  vs 4.6 s) because of how process output is exposed to plugins.
- **CLI only.** No restic library, no REST calls: every interaction is `restic --json …`, with `--no-lock` for reads.
- **Blocking work never runs in the UI thread.** Hooks only schedule async tasks; a per-path "busy" claim prevents the
  same folder or file from being worked on twice.
- **Unexpected errors are reported**, not swallowed: Yazi hides Lua errors raised in plugin tasks, so every task body is
  wrapped and turned into a notification.
- **The environment is controlled**: the three restic variables that could override the typed password are cleared on
  every call, and for SFTP the ssh batch option is added to every call.

### Project structure

```
restic.yazi/               the plugin (this is what gets installed)
  main.lua                   entry point only: wiring to Yazi (hooks, actions, previewer, spotter), no business logic
  config.lua                 .restic parser, restic binary resolution + minimum version, paths (~, relative, absolute)
  client.lua                 restic CLI wrapper: environment, SFTP batch mode, JSON/JSONL parsing, error messages
  snapshots.lua              snapshot folder naming, parsing and ordering
  ghost.lua                  ghost tree: create / reuse / lazily expand, path mapping (+ `latest`), staging, user dir
  restore.lua                restore planning (ghost paths → snapshot paths) and destination validation
  preview.lua                the rows of the metadata preview (pure)
  info.lua                   the sections of the `Tab` spotter: entry, snapshot, repository (pure)
  util.lua                   small pure helpers
  version.lua                the plugin version (single source of truth)
  README.md, LICENSE         git symlinks to the root files (single copies; see "Building and development")
spec/                      busted unit tests (+ helpers: a Yazi mock, a local-filesystem stand-in, a restic fixture)
tests/integration/         busted tests against a real restic repository built in a temp dir (+ a fake ssh)
tests/e2e/                 pytest + pyte: a real Yazi in a pseudo-terminal, isolated config, real repository
tests/tooling/             pytest for the release script and install.sh
.agents/skills/            agent skills: plugin-release (build/version/release), memory-updater, kroki-diagrams
sample_backup.restic       annotated `.restic` template
CHANGELOG.md               release notes (Keep a Changelog)
AGENTS.md                  directives, verified Yazi/restic facts and architecture for contributors and AI agents
dist/                      builds (gitignored)
```

Code conventions: plain Lua 5.4+ (Yazi embeds Lua 5.5), LuaLS annotations, pure logic (parsing, naming, path mapping)
kept in side-effect-free functions, and I/O injected or confined to thin wrappers so that nearly everything is
unit-testable without Yazi.

### Tests

| Layer | What it checks | Run |
|---|---|---|
| Unit (`spec/`) | parsing, naming, path mapping, error handling, argument building — with a Yazi mock | `busted` |
| Integration (`tests/integration/`) | `client` and `ghost` against a real restic repository, and the ssh options against a fake `ssh` | `busted` |
| End to end (`tests/e2e/`) | the whole plugin inside a real Yazi (browse, preview, `Tab` details, open, restore of folders and of multiple selections, reopen, `latest`, local-time folder names, wrong password, SFTP through a local `sftp-server`) | `uv run --no-sync pytest tests/e2e` (~4 min) |
| Tooling (`tests/tooling/`) | version bumping, changelog, packaging, `install.sh`, the release flow in a throw-away git repo | `uv run --no-sync pytest tests/tooling` |

---

## Building and development

This `README.md` and the root `LICENSE` are the **only** copies in the repository. Yazi (and `ya pkg`) require both
inside the plugin folder, so `restic.yazi/README.md` and `restic.yazi/LICENSE` are committed **git symlinks** to
`../README.md` and `../LICENSE`: `ya pkg add` replaces them with copies of their targets, and the build does the same
for the package. Links in the README must therefore be absolute URLs. The build checks the symlinks (and
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

More: [AGENTS.md](https://github.com/goldfix/yazi-plugin-restic/blob/main/AGENTS.md) (contributor and agent notes),
[CHANGELOG.md](https://github.com/goldfix/yazi-plugin-restic/blob/main/CHANGELOG.md).

---

## Open points and ideas

Known gaps of the current version. The roadmap lives in the project notes, not here.

- [ ] Windows is untested (temp folder, `chmod`, path syntax); Linux is untested too, though nothing in the code is
      macOS-specific
- [ ] Case-insensitive filesystems merge names that differ only by case
- [ ] Snapshots are addressed by their 8-character id: restic would report an ambiguity if two ids shared the prefix
      (a full-id map would fix it)
- [ ] Two Yazi instances of the same user opening the same repository share one browsing tree; the second open clears
      the first one's in-flight downloads
- [ ] Backends other than local and SFTP are not covered by automated tests (S3, S3-compatible and REST were tried by
      hand and work; B2, Azure, Google Cloud and rclone are untried)

---

## License

MIT — see [LICENSE](https://github.com/goldfix/yazi-plugin-restic/blob/main/LICENSE) (a copy is shipped inside the
plugin folder).
