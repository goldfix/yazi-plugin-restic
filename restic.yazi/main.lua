--- restic.yazi — browse and restore restic snapshots from Yazi through a "ghost" filesystem.
---
--- This file only wires Yazi to the other modules; the logic lives in config/client/snapshots/ghost/restore/preview.
---
--- Setup (`~/.config/yazi/init.lua`):  require("restic"):setup()
--- Commands (`keymap.toml`):           plugin restic -- enter | restore | version
--- Previewer (`yazi.toml`):            { url = "/tmp/yazi-restic-*/**", run = "restic" }
local Client = require(".client")
local config = require(".config")
local ghost = require(".ghost")
local preview = require(".preview")
local restore = require(".restore")
local util = require(".util")
local VERSION = require(".version").version

local M = {}

--- Seconds the cursor must rest on a folder before it is listed for the preview pane, so that scrolling
--- quickly through many folders does not fire one restic call each.
local HOVER_DELAY = 0.4

---@class ResticSession  Lives in the plugin `state` (memory only, never persisted).
---@field root string  Ghost root directory.
---@field latest? string  Snapshot directory the `latest` symlink points to.
---@field exec string
---@field repository string
---@field password string
---@field ssh_batch_mode boolean

-- The bulky per-session tables live next to the session in the plugin `state`, not inside it, so that the
-- session itself stays small and can be handed across `ya.sync` (which copies) as a whole:
--   state.entries: table<string, table>  `restic ls` node per ghost path (metadata for the preview)
--   state.busy:    table<string, true>   paths being listed or fetched right now

-- Synchronous accessors of the plugin state (must be created at the top level). Data crossing a `ya.sync`
-- boundary is copied, so the (possibly large) `entries` table is never handed out as a whole.

--- The session, or nil when no repository is open.
local get_session = ya.sync(function(state) return state.session end)

--- Start a session (replacing any previous one) with empty entry and busy tables.
local set_session = ya.sync(function(state, session)
  state.session, state.entries, state.busy = session, {}, {}
end)

local add_entries = ya.sync(function(state, entries)
  for path, node in pairs(entries) do
    state.entries[path] = node
  end
end)

local get_entry = ya.sync(function(state, path) return state.entries and state.entries[path] end)

--- Mark a path as busy; false if another task is already working on it (or no session is open).
local claim = ya.sync(function(state, path)
  if not state.session or state.busy[path] then
    return false
  end
  state.busy[path] = true
  return true
end)

local release = ya.sync(function(state, path)
  if state.busy then
    state.busy[path] = nil
  end
end)

local hovered_path = ya.sync(function()
  local hovered = cx.active.current.hovered
  return hovered and tostring(hovered.url)
end)

--- Selected files if any, otherwise the hovered one.
local targets = ya.sync(function()
  local paths = {}
  for _, file in pairs(cx.active.selected) do -- `selected` yields File objects, not Urls
    paths[#paths + 1] = tostring(file.url)
  end
  local hovered = cx.active.current.hovered
  if #paths == 0 and hovered then
    paths[1] = tostring(hovered.url)
  end
  return paths
end)

---@param content any  Message (Yazi `Error` values are converted too).
---@param level? "info"|"warn"|"error"
local function notify(content, level)
  ya.notify { title = "Restic", content = tostring(content), timeout = 5, level = level or "info" }
end

--- Run `fn`, turning an unexpected Lua error into a notification (Yazi would swallow it silently).
---@param fn fun()
local function guarded(fn)
  local ok, err = pcall(fn)
  if not ok then
    notify("Unexpected error: " .. tostring(err), "error")
  end
end

---@param session ResticSession
---@return table client
local function client_for(session)
  return Client.new {
    exec = session.exec,
    repository = session.repository,
    password = session.password,
    ssh_batch_mode = session.ssh_batch_mode,
  }
end

--- Open a `.restic` repository: ask the password, list the snapshots, build (or reuse) the ghost root and
--- go there.
---@param file string  Path of the `.restic` file.
local function open_repository(file)
  local cfg, err = config.read(file)
  if not cfg then
    return notify(err, "error")
  end

  local exec
  exec, err = config.resolve_binary(cfg.restic_exec)
  if not exec then
    return notify(err, "error")
  end

  local password, event =
    ya.input { title = "Repository password:", obscure = true, pos = { "center", w = 60 } }
  if event ~= 1 then
    return
  end

  local repository = config.resolve_repository(cfg.repository, file:match("^(.*)[/\\][^/\\]*$") or ".")
  local session = { root = ghost.root_for(config.repo_id(repository)), exec = exec, repository = repository }
  session.password, session.ssh_batch_mode = password, cfg.ssh_batch_mode

  local snapshots
  snapshots, err = client_for(session):snapshots()
  if not snapshots then
    return notify(err, "error")
  end

  local fsx = ghost.yazi_fs()
  local ok, tree
  ok, err = ghost.ensure_user_dir(fsx)
  if ok then
    tree, err = ghost.init_root(session.root, snapshots, fsx)
  end
  if not tree then
    return notify(err, "error")
  end

  session.latest = tree.latest
  set_session(session)
  ya.emit("cd", { session.root, raw = true })
  if not tree.latest then
    notify("The repository has no snapshots", "warn")
  end
end

--- Expand a ghost directory that still carries the `.unfetched` marker (no-op otherwise).
---@param dir string
local function expand(dir)
  local session = get_session()
  local fsx = ghost.yazi_fs()
  if not session or not ghost.locate(session.root, dir, session.latest) then
    return
  elseif not fsx.exists(util.join(dir, ghost.MARKER)) or not claim(dir) then
    return
  end

  local listing = { root = session.root, latest = session.latest, client = client_for(session) }
  local entries, err = ghost.expand(listing, dir, fsx)
  release(dir)
  if not entries then
    return notify(err, "error")
  end

  add_entries(entries)
  if entries[hovered_path()] then
    ya.emit("peek", { force = true }) -- the hovered entry was previewed before its metadata arrived
  end
end

--- Fetch the content of a ghost file into place if it is still a 0-byte placeholder.
---@param session ResticSession
---@param path string
---@param node table
---@return boolean ok  false if the file is not available (an error was notified).
local function fetch_file(session, path, node)
  local stat = fs.cha(Url(path))
  if not stat or stat.len > 0 or (node.size or 0) == 0 then
    return true
  elseif not claim(path) then
    notify(string.format("%s is already being restored", node.name), "warn")
    return false
  end

  notify(string.format("Restoring %s ...", node.name))
  local location = ghost.locate(session.root, path, session.latest)
  local staging = ghost.staging_for(session.root, path)
  local ok, err = client_for(session):fetch(location.short_id, location.path, path, staging)
  release(path)
  if not ok then
    notify(err, "error")
  end
  return ok == true
end

--- Smart <Enter>: fetch-then-open a ghost file, open a `.restic` repository, otherwise enter/open as usual.
local function enter()
  local path = hovered_path()
  local session = get_session()
  local in_ghost = session and path and ghost.locate(session.root, path, session.latest)

  local node = in_ghost and get_entry(path)
  if in_ghost and not node then -- reused tree: the folder may not be listed yet in this session
    expand(util.parent(path))
    node = get_entry(path)
  end

  if node and node.type == "file" then
    if not fetch_file(session, path, node) then
      return
    end
  elseif not in_ghost and path and path:lower():match("%.restic$") then
    return open_repository(path)
  end

  local stat = path and fs.cha(Url(path))
  ya.emit(stat and stat.is_dir and "enter" or "open", { hovered = true })
end

--- Restore the selection (or the hovered entry) to a folder chosen by the user, with one restic call per snapshot.
--- Shows the progress per snapshot and, on success, clears the selection.
local function restore_selection()
  local session = get_session()
  if not session then
    return notify("No restic repository is open", "warn")
  end

  local groups, skipped = restore.plan(session.root, targets(), session.latest)
  if #groups == 0 then
    return notify("Nothing to restore here", "warn")
  elseif skipped > 0 then
    notify(string.format("%d selected item(s) are not in the backup and will be skipped", skipped), "warn")
  end

  local default = (os.getenv("HOME") or os.getenv("USERPROFILE") or ".") .. "/restic-restore"
  local input, event = ya.input { title = "Restore to:", value = default, pos = { "center", w = 70 } }
  if event ~= 1 then
    return
  end
  local dest, err = restore.destination(input, session.root)
  if not dest then
    return notify(err, "error")
  end

  local client = client_for(session)
  local started = os.time()
  for i, group in ipairs(groups) do -- one restic call per snapshot
    notify(restore.progress(i, #groups, group))
    local ok
    ok, err = client:restore(group.short_id, group.paths, dest)
    if not ok then
      return notify(string.format("Snapshot %s: %s", group.short_id, err), "error") -- the selection is kept: retry
    end
  end
  ya.emit("escape", { select = true })
  notify(restore.summary(restore.count(groups), dest, os.time() - started))
end

--- Register the hooks that lazily expand ghost folders. Call from `init.lua`.
--- `cd` lists the folder that was entered; `hover` lists the folder under the cursor so that the preview
--- pane shows its content.
function M:setup()
  ps.sub("cd", function()
    local cwd = tostring(cx.active.current.cwd)
    ya.async(function()
      guarded(function() expand(cwd) end)
    end)
  end)

  ps.sub("hover", function()
    local hovered = cx.active.current.hovered
    local path = hovered and tostring(hovered.url)
    if not path then
      return
    end
    ya.async(function()
      ya.sleep(HOVER_DELAY)
      if hovered_path() == path then
        guarded(function() expand(path) end)
      end
    end)
  end)
end

--- Plugin command: `plugin restic -- enter|restore|version`.
---@param job table
function M:entry(job)
  local action = job.args[1]
  if action == "enter" then
    guarded(enter)
  elseif action == "restore" then
    guarded(restore_selection)
  elseif action == "version" then
    notify("restic.yazi " .. VERSION)
  else
    notify("Unknown action: " .. tostring(action), "error")
  end
end

--- Previewer: show the backup metadata of the hovered ghost entry.
---@param job table
function M:peek(job)
  local node = get_entry(tostring(job.file.url))
  local lines
  if node then
    local stat = fs.cha(job.file.url)
    lines = {}
    for _, row in ipairs(preview.rows(node, stat ~= nil and stat.len > 0)) do
      lines[#lines + 1] = ui.Line { ui.Span(row.label .. ": "):bold(), ui.Span(row.value) }
    end
  else
    lines = { ui.Line("No backup information available") }
  end
  ya.preview_widget(job, ui.Text(lines):area(job.area):wrap(ui.Wrap.YES))
end

function M:seek() end

return M
