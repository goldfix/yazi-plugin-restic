--- The Ghost Filesystem: a throw-away tree of real directories and 0-byte files that mirrors a restic
--- snapshot, so Yazi can browse a backup with its native engine and without FUSE.
---
---   <root>/                                    e.g. /tmp/yazi-restic-501/1a2b3c4d
---     <snapshot dir>/                          see snapshots.dirname()
---       <absolute path of the backed-up tree>  e.g. home/me/docs/report.md (0 bytes until fetched)
---
--- Directories not yet listed hold a visible marker file (`MARKER`, set again on every folder of a reused tree), so
--- that a folder still being read shows "(not listed yet)" rather than Yazi's "No items". Entering one lists a
--- single level from restic (see `expand`), creates the children (directories get their own marker) and removes
--- the marker.
local snapshots = require(".snapshots")
local util = require(".util")

local M = {}

--- Name of the sentinel file that flags a directory whose content has not been fetched yet. It is deliberately
--- NOT a dot file: Yazi hides those, and an unlisted folder would look empty ("No items") while it loads.
M.MARKER = "(not listed yet)"

--- The (hidden) marker of plugin versions up to 0.5.0. Still a reserved name, so that every file called so in a tree
--- is known to be an old marker: reused trees drop them (see `reflag`).
M.LEGACY_MARKER = ".unfetched"

--- Whether a name is one of the plugin's markers (not a backup entry).
---@param name string
---@return boolean
function M.is_marker(name) return name == M.MARKER or name == M.LEGACY_MARKER end

--- Name of the symlink, below the root, to the newest snapshot directory.
M.LATEST = "latest"

--- Directory, below the root, holding the temporary restore targets of `Client:fetch`. Like `latest` it is
--- outside the namespace of snapshot directories, so it can never clash with backed-up content.
M.STAGING = ".staging"

---@class GhostFs  Filesystem operations needed by the ghost tree (injectable; see `M.yazi_fs`).
---@field mkdir fun(path: string): boolean?, string?  Create a directory and its parents (idempotent).
---@field touch fun(path: string): boolean?, string?  Create an empty file; never truncate an existing one.
---@field exists fun(path: string): boolean
---@field remove fun(path: string): boolean?, string?  Remove a file.
---@field remove_all fun(path: string): boolean?, string?  Remove a directory tree (no error if absent).
---@field dirs fun(path: string): string[]  Names of the real subdirectories (symlinks excluded); empty if absent.
---@field symlink fun(target: string, link: string): boolean?, string?  Create or replace a symlink.
---@field restrict fun(path: string)  Make a directory accessible to the current user only (best effort).
---@field owned fun(path: string): boolean  A real directory (not a symlink) owned by the current user.

---@class GhostLocation
---@field snapshot_dir string  Name of the snapshot directory below the root (`latest` resolved).
---@field short_id string
---@field path string  Absolute path inside the snapshot ("/" for the snapshot directory itself).

--- Directory holding the ghost trees of the current user. On Unix it is `<tmp>/yazi-restic-<uid>`, so users
--- sharing a machine (and a repository) never touch each other's trees; Windows' %TEMP% is per-user already.
---@return string
function M.user_dir()
  if ya.target_family() == "windows" then
    return util.join(os.getenv("TEMP") or os.getenv("TMP") or ".", "yazi-restic")
  end
  return util.join("/tmp", "yazi-restic-" .. ya.uid())
end

--- Create the per-user directory (see `user_dir`), readable by its owner only. A directory that already
--- exists must be a real directory owned by the current user: in a shared `/tmp` another user could have
--- created it (or a symlink) in advance to read the fetched files.
---@param fsx GhostFs
---@return boolean? ok
---@return string? err
function M.ensure_user_dir(fsx)
  local dir = M.user_dir()
  local ok, err = fsx.mkdir(dir)
  if not ok then
    return nil, err
  elseif not fsx.owned(dir) then
    return nil, string.format("refusing to use %s: not a directory owned by the current user", dir)
  end
  fsx.restrict(dir)
  return true
end

--- Root of the ghost tree of a repository.
---@param repo_id string
---@return string
function M.root_for(repo_id) return util.join(M.user_dir(), repo_id) end

--- Whether `path` is the root or lies below it.
---@param root string
---@param path string
---@return boolean
function M.is_inside(root, path) return path == root or path:sub(1, #root + 1) == root .. "/" end

--- Map a ghost path to its snapshot and in-backup path. Paths through the `latest` symlink (Yazi keeps the
--- logical path when entering it) are resolved when `latest` is given.
---@param root string
---@param ghost_path string
---@param latest? string  Snapshot directory `latest` points to.
---@return GhostLocation? location  `nil` for the root itself or for paths outside the snapshot directories.
function M.locate(root, ghost_path, latest)
  if not M.is_inside(root, ghost_path) then
    return nil
  end
  local snapshot_dir, rest = ghost_path:sub(#root + 2):match("^([^/]+)(.*)$")
  if snapshot_dir == M.LATEST then
    snapshot_dir = latest
  end
  local short_id = snapshot_dir and snapshots.parse_dirname(snapshot_dir)
  if not short_id then
    return nil
  end
  return { snapshot_dir = snapshot_dir, short_id = short_id, path = rest == "" and "/" or rest }
end

--- The path through the real snapshot directory of a path through the `latest` link (other paths unchanged).
--- Both spellings name the same file, so the in-memory tables (metadata, busy flags) use this one as the key:
--- otherwise a folder listed through one spelling would look unknown through the other.
---@param root string
---@param path string
---@param latest? string  Snapshot directory `latest` points to.
---@return string
function M.canonical(root, path, latest)
  local alias = util.join(root, M.LATEST)
  if latest and (path == alias or path:sub(1, #alias + 1) == alias .. "/") then
    return util.join(root, latest) .. path:sub(#alias + 1)
  end
  return path
end

--- A fresh, unique staging directory for `Client:fetch` (see `STAGING`); not created here.
---@param root string
---@param dest string  File being fetched.
---@return string
function M.staging_for(root, dest)
  local nonce = string.format("%s|%.6f|%d", dest, os.clock(), math.random(1, 0x7fffffff))
  return util.join(root, M.STAGING, util.hash(nonce))
end

--- Whether a node name may safely become a file name: a malicious or odd repository must not be able to
--- escape the ghost tree (`..`, separators) nor clash with the marker.
---@param name string
---@return boolean
function M.safe_name(name)
  return name ~= "" and name ~= "." and name ~= ".." and not M.is_marker(name) and not name:find("[/\\%z]")
end

--- Direct children of `dir` among the records of `restic ls --json` (drops the snapshot header, the
--- directory itself and anything deeper), sorted by name.
---@param records table[]
---@param dir string  Absolute path inside the snapshot.
---@return table[] nodes
function M.children(records, dir)
  local nodes = {}
  for _, record in ipairs(records) do
    if
      record.path
      and record.name
      and record.path ~= dir
      and util.parent(record.path) == dir
      and M.safe_name(record.name)
    then
      nodes[#nodes + 1] = record
    end
  end
  table.sort(nodes, function(a, b) return a.name < b.name end)
  return nodes
end

--- Create an empty file unless the path already exists (so a fetched file is never truncated).
---@param fsx GhostFs
---@param path string
---@return boolean? ok
---@return string? err
local function ensure_file(fsx, path) return fsx.exists(path) or fsx.touch(path) end

--- Create a directory flagged as not yet fetched.
---@param fsx GhostFs
---@param path string
---@return boolean? ok
---@return string? err
local function make_unfetched_dir(fsx, path)
  local ok, err = fsx.mkdir(path)
  if not ok then
    return nil, err
  end
  return ensure_file(fsx, util.join(path, M.MARKER))
end

--- Flag `dir` and every directory below it as not fetched. Used when an existing tree is reused: the files
--- already fetched stay, but the metadata that feeds the preview lives in memory only, so each folder must
--- be listed again once per session (cheap, and idempotent).
---@param fsx GhostFs
---@param dir string
---@return boolean? ok
---@return string? err
local function reflag(fsx, dir)
  fsx.remove(util.join(dir, M.LEGACY_MARKER)) -- tree made by an older version (usually absent: error ignored)
  local ok, err = ensure_file(fsx, util.join(dir, M.MARKER))
  for _, name in ipairs(ok and fsx.dirs(dir) or {}) do
    ok, err = reflag(fsx, util.join(dir, name))
    if not ok then
      break
    end
  end
  return ok, err
end

---@class GhostTree
---@field latest? string  Name of the newest snapshot directory (target of the `latest` symlink).

--- Create the ghost root, or reuse it if it already exists: one directory per snapshot (flagged
--- the marker) and a `latest` symlink to the newest one.
---
--- Snapshots are immutable and their directory name contains their id, so what is already in the tree
--- stays valid, fetched files included. Directories of snapshots that no longer exist are removed, and so
--- are the staging areas left by interrupted fetches.
---@param root string
---@param list ResticSnapshot[]
---@param fsx GhostFs
---@return GhostTree? tree
---@return string? err
function M.init_root(root, list, fsx)
  local ok, err = fsx.mkdir(root)
  if not ok then
    return nil, err
  end
  fsx.restrict(root) -- fetched files are private data: keep other local users out of the tree
  fsx.remove_all(util.join(root, M.STAGING))

  local wanted, ordered = {}, snapshots.sorted(list)
  for _, snapshot in ipairs(ordered) do
    wanted[snapshots.dirname(snapshot)] = snapshot
  end

  for _, name in ipairs(fsx.dirs(root)) do
    if snapshots.parse_dirname(name) and not wanted[name] then
      fsx.remove_all(util.join(root, name))
    end
  end

  local tree = {}
  for _, snapshot in ipairs(ordered) do
    local name = snapshots.dirname(snapshot)
    local dir = util.join(root, name)
    ok, err = fsx.mkdir(dir)
    if ok then
      ok, err = reflag(fsx, dir)
    end
    if not ok then
      return nil, err
    end
    tree.latest = name
  end

  local link = util.join(root, M.LATEST)
  if tree.latest then
    fsx.symlink(tree.latest, link) -- relative target; cosmetic, ignored where symlinks are unavailable
  else
    fsx.remove(link)
  end
  return tree
end

---@class GhostSession
---@field root string
---@field latest? string  See `GhostTree.latest`.
---@field client table  See client.lua.

--- Populate one level of the ghost tree: list `ghost_dir` from restic, create its children (directories
--- carry the marker, files are empty) and finally drop the marker of `ghost_dir`.
--- Idempotent: it never truncates a file that was already fetched.
---@param session GhostSession
---@param ghost_dir string
---@param fsx GhostFs
---@return table<string, table>? entries  restic `ls` nodes keyed by ghost path (for the metadata preview).
---@return string? err
function M.expand(session, ghost_dir, fsx)
  local location = M.locate(session.root, ghost_dir, session.latest)
  if not location then
    return nil, "not inside a snapshot: " .. ghost_dir
  end

  local records, err = session.client:ls(location.short_id, location.path)
  if not records then
    return nil, err
  end

  local entries = {}
  for _, node in ipairs(M.children(records, location.path)) do
    local path = util.join(ghost_dir, node.name)
    local ok
    if node.type == "dir" then
      ok, err = make_unfetched_dir(fsx, path)
    else
      ok, err = ensure_file(fsx, path)
    end
    if not ok then
      return nil, err
    end
    entries[path] = node
  end

  fsx.remove(util.join(ghost_dir, M.MARKER))
  return entries
end

--- `GhostFs` backed by the Yazi `fs` API (async context only).
---@return GhostFs
function M.yazi_fs()
  ---@param command table
  ---@return boolean ok
  local function succeeded(command)
    local status = command:status()
    return status ~= nil and status.success
  end

  local unix = ya.target_family() == "unix"

  return {
    mkdir = function(path) return fs.create("dir_all", Url(path)) end,
    touch = function(path) -- append mode creates the file without ever truncating it
      local file, err = io.open(path, "ab")
      if not file then
        return nil, err
      end
      file:close()
      return true
    end,
    exists = function(path) return fs.cha(Url(path)) ~= nil end,
    remove = function(path) return fs.remove("file", Url(path)) end,
    remove_all = function(path)
      if fs.cha(Url(path)) == nil then
        return true
      end
      return fs.remove("dir_all", Url(path))
    end,
    dirs = function(path)
      local names = {}
      for _, file in ipairs(fs.read_dir(Url(path), {}) or {}) do
        if file.cha.is_dir and not file.cha.is_link then
          names[#names + 1] = file.name
        end
      end
      return names
    end,
    symlink = function(target, link) return succeeded(Command("ln"):arg { "-sfn", target, link }) end,
    restrict = function(path)
      if unix then
        succeeded(Command("chmod"):arg { "700", path })
      end
    end,
    owned = function(path)
      local cha = fs.cha(Url(path))
      return cha ~= nil and cha.is_dir and not cha.is_link and (not unix or cha.uid == ya.uid())
    end,
  }
end

return M
