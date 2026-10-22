# How it works

Internals of [restic.yazi](../README.md): the ghost filesystem, what each action runs and why. For installing and configuring, see the [README](../README.md).

## The "ghost filesystem"

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
 Yazi ── b r ──────────────────────>   `restic restore <id> --target <dest> --include <path>`   (b x kills it)
 Yazi ── hover ──> previewer           shows the metadata of the entry (from memory, not from the 0-byte file)
 Yazi ── Tab ────> spotter             entry / snapshot details from memory; repository: `restic snapshots` + `restic stats`
```

The flow in words:

1. **Open.** `Enter` on a `.restic` file: parse it, find and version-check restic, ask for the password, run
   `restic snapshots --json`. Under `/tmp/yazi-restic-<uid>/<repository id>/` create one folder per snapshot, named
   `<date>__<id>__<host>__[<tags>]` (date and time in **your** local time zone, newest last, each carrying a marker
   file called `(not listed yet)`) and the `latest` link, then `cd` there. If the tree already exists from an
   earlier session it is **reused**: snapshots are immutable, so folders and fetched files stay valid; vanished
   snapshots are removed, new ones added, and every folder is re-marked so it is listed again once.
2. **Expand lazily.** Whenever Yazi enters a folder (`cd` hook) or the cursor rests on one for 0.4 s (`hover` hook, so
   the preview pane can show its content), and the folder carries the marker, the plugin runs
   `restic ls <snapshot> <path> --json` (one level, no recursion), creates the children (directories with a marker of
   their own, files as 0-byte placeholders), stores each child's metadata **in memory only**, and removes the marker. The marker is a normal, visible file on
   purpose: a folder that is still being read shows `(not listed yet)` (and "Reading this folder from the backup..." in the preview) instead of Yazi's "No items", which
   is left for folders that really are empty.
3. **Preview and spot.** A previewer plugin renders the stored metadata for the highlighted entry (type, size,
   permissions, owner, dates, original path, local copy yes/no). The spotter (`Tab`) shows the same plus the snapshot record
   kept in memory when the repository was opened, the folder contents counted from the listed entries, or, for a
   repository, `restic snapshots` and `restic stats --mode raw-data` (run
   when you press `Tab`, never at startup). Paths through `latest` are stored under the real snapshot folder, so
   what was listed through one spelling is known through the other.
4. **Open a file.** On a 0-byte placeholder with a non-zero size in the backup, run
   `restic restore <id>:<parent dir> --include /<name>` into a private folder under `.staging/`, then rename the result
   over the placeholder. Using the `<id>:<folder>` form restores the file directly, without recreating its parent
   directories (whose possibly read-only permissions would otherwise prevent moving it). A file larger than 0 bytes is
   already cached and simply opened.
5. **Restore.** Ask for a destination, validate it, group the selected entries by snapshot (dropping the ones below
   another selected entry), then run one `restic restore … --include <path> --include <path>…` per snapshot: restic
   opens the repository once instead of once per entry. The whole run is a Yazi **task** (`task.lua`): the status bar
   gauge and the task manager (`w`) show how far it is, and a failed restore leaves its entry in that list with
   restic's error in the log. While restic works the plugin reads its output with a 200 ms timeout so it can honour a
   cancellation: the `cancel` action (`b` `x`) sets a flag (in the plugin state, shared by all its invocations) and
   the waiting call kills the process. That is the only way to stop it: Yazi 26.9 tells a plugin nothing when the
   user presses `x` on its task. A second `restore` while one runs is refused. Files already written stay in the
   destination, and the selection is kept so the restore can be retried.

## Design decisions worth knowing

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

## Privacy and safety

- The browsing tree is created with mode `700`, and the plugin refuses to use `/tmp/yazi-restic-<uid>` if it is not a
  real folder owned by you (protection against another user pre-creating it).
- Names in a backup that cannot exist safely on disk (empty, `.`, `..`, containing `/`, `\` or NUL) are skipped, and so
  are the two names the plugin reserves for its markers: `(not listed yet)` and `.unfetched` (used up to 0.5.0).
  Symbolic links in a backup appear as empty regular files — they are never created as real links, so a malicious
  backup cannot make the plugin touch files outside the tree.
- Restores never write into the browsing tree.
