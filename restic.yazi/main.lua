--- restic.yazi — browse and restore restic snapshots from Yazi through a "ghost" filesystem.
---
--- This file only wires Yazi to the other modules; the logic lives in config/client/snapshots/ghost/restore/preview.
---
--- Setup (`~/.config/yazi/init.lua`):  require("restic"):setup()
--- Commands (`keymap.toml`):           plugin restic -- enter | leave | back | restore | version
--- Previewer (`yazi.toml`):            { url = "/tmp/yazi-restic-*/**", run = "restic" }
--- Spotter (`yazi.toml`, optional):     the same, plus `/tmp/yazi-restic-*/**/` (folders) and `*.restic`
local Client = require(".client")
local config = require(".config")
local ghost = require(".ghost")
local info = require(".info")
local preview = require(".preview")
local restore = require(".restore")
local snapshots = require(".snapshots")
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
---@field file string  The `.restic` file the session was opened from (`back` returns to it).

-- The bulky per-session tables live next to the session in the plugin `state`, not inside it, so that the
-- session itself stays small and can be handed across `ya.sync` (which copies) as a whole:
--   state.entries: table<string, table>  `restic ls` node per ghost path (metadata for the preview)
--   state.snapshots: table<string, table>  `restic snapshots` record per short id (details for the spotter)
--   state.busy:    table<string, true>   paths being listed or fetched right now

-- Synchronous accessors of the plugin state (must be created at the top level). Data crossing a `ya.sync`
-- boundary is copied, so the (possibly large) `entries` table is never handed out as a whole. Paths are keyed by
-- their canonical spelling (`key`), so `latest/…` and `<snapshot dir>/…` share metadata and busy flags.

--- Key of a ghost path in `state.entries` / `state.busy` (sync context only).
---@param state table
---@param path string
---@return string
local function key(state, path)
  local session = state.session
  return session and ghost.canonical(session.root, path, session.latest) or path
end

--- The session, or nil when no repository is open.
local get_session = ya.sync(function(state) return state.session end)

--- Start a session (replacing any previous one) with empty entry and busy tables.
---@param session ResticSession
---@param by_id table<string, ResticSnapshot>  The repository's snapshots keyed by short id.
local set_session = ya.sync(function(state, session, by_id)
  state.session, state.snapshots, state.entries, state.busy = session, by_id, {}, {}
end)

local add_entries = ya.sync(function(state, entries)
  for path, node in pairs(entries) do
    state.entries[key(state, path)] = node
  end
end)

local get_entry = ya.sync(function(state, path) return state.entries and state.entries[key(state, path)] end)

local get_snapshot = ya.sync(
  function(state, short_id) return state.snapshots and state.snapshots[short_id] end
)

--- What a listed folder directly contains (counted inside the sync block: the entries are never copied out).
local tally_of = ya.sync(function(state, dir) return info.tally(state.entries or {}, key(state, dir)) end)

--- Mark a path as busy; false if another task is already working on it (or no session is open).
local claim = ya.sync(function(state, path)
  if not state.session or state.busy[key(state, path)] then
    return false
  end
  state.busy[key(state, path)] = true
  return true
end)

local release = ya.sync(function(state, path)
  if state.busy then
    state.busy[key(state, path)] = nil
  end
end)

local current_dir = ya.sync(function() return tostring(cx.active.current.cwd) end)

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
  -- Yazi aborts a spot the user moved away from by raising this error inside the plugin: not a failure
  if not ok and not tostring(err):find("Spot task cancelled", 1, true) then
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

--- Folder holding a file (relative repository paths in a `.restic` file are relative to it).
---@param file string
---@return string
local function folder_of(file) return file:match("^(.*)[/\\][^/\\]*$") or "." end

--- Ask the repository password (masked).
---@return string? password  nil if the user cancelled.
local function ask_password()
  local password, event =
    ya.input { title = "Repository password:", obscure = true, pos = { "center", w = 60 } }
  return event == 1 and password or nil
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

  local password = ask_password()
  if not password then
    return
  end

  local repository = config.resolve_repository(cfg.repository, folder_of(file))
  local session = { root = ghost.root_for(config.repo_id(repository)), exec = exec, repository = repository }
  session.password, session.ssh_batch_mode, session.file = password, cfg.ssh_batch_mode, file

  local list
  list, err = client_for(session):snapshots()
  if not list then
    return notify(err, "error")
  end

  local fsx = ghost.yazi_fs()
  local ok, tree
  ok, err = ghost.ensure_user_dir(fsx)
  if ok then
    tree, err = ghost.init_root(session.root, list, fsx)
  end
  if not tree then
    return notify(err, "error")
  end

  session.latest = tree.latest
  set_session(session, snapshots.index(list))
  ya.emit("cd", { session.root, raw = true })
  if not tree.latest then
    notify("The repository has no snapshots", "warn")
  end
end

--- Expand a ghost directory that still carries the marker (no-op otherwise).
---@param dir string
---@return boolean ok  false if the listing failed (an error was notified).
local function expand(dir)
  local session = get_session()
  local fsx = ghost.yazi_fs()
  if not session or not ghost.locate(session.root, dir, session.latest) then
    return true
  elseif not fsx.exists(util.join(dir, ghost.MARKER)) or not claim(dir) then
    return true
  end

  local listing = { root = session.root, latest = session.latest, client = client_for(session) }
  local entries, err = ghost.expand(listing, dir, fsx)
  release(dir)
  if not entries then
    notify(err, "error")
    return false
  end

  add_entries(entries)
  local hovered = hovered_path()
  local function canonical(path) return ghost.canonical(session.root, path, session.latest) end
  if hovered and canonical(util.parent(hovered)) == canonical(dir) then
    ya.emit("peek", { force = true }) -- the hovered entry was previewed before its metadata arrived
  end
  return true
end

--- Make sure a ghost folder is listed, also when another task (the hover hook) is listing it right now.
---@param dir string
---@return boolean listed
local function ensure_listed(dir)
  if not expand(dir) then
    return false
  end
  local marker, fsx = util.join(dir, ghost.MARKER), ghost.yazi_fs()
  for _ = 1, 100 do
    if not fsx.exists(marker) then
      return true
    end
    ya.sleep(0.1)
  end
  return false
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
  if in_ghost and ghost.is_marker(util.basename(path)) then
    return -- "(not listed yet)" is not a file of the backup: there is nothing to open
  end

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

--- Go back to the `.restic` file the open repository was opened from (its folder, with the file highlighted).
local function back_to_config()
  local session = get_session()
  if not session then
    return notify("No restic repository is open", "warn")
  end
  ya.emit("reveal", { session.file, raw = true, no_dummy = true })
end

--- Smart `leave`: from the top of the browsing tree go back to the `.restic` file, anywhere else go up one level
--- as usual.
local function leave()
  local session = get_session()
  if session and current_dir() == session.root then
    return back_to_config()
  end
  ya.emit("leave", {})
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

--- Plugin command: `plugin restic -- enter|leave|back|restore|version`.
---@param job table
function M:entry(job)
  local action = job.args[1]
  if action == "enter" then
    guarded(enter)
  elseif action == "restore" then
    guarded(restore_selection)
  elseif action == "leave" then
    guarded(leave)
  elseif action == "back" then
    guarded(back_to_config)
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
  elseif ghost.is_marker(util.basename(tostring(job.file.url))) then
    lines = { ui.Line("Reading this folder from the backup...") }
  else
    lines = { ui.Line("No backup information available") }
  end
  ya.preview_widget(job, ui.Text(lines):area(job.area):wrap(ui.Wrap.YES))
end

function M:seek() end

-- Spotter (`Tab`) ---------------------------------------------------------------------------------------------

--- Draw the sections of `info` as the spotter's table (calling it again with the same `job` refreshes it).
---@param job table
---@param sections InfoSection[]
local function show(job, sections)
  local rows, lines = {}, 0
  for i, section in ipairs(sections) do
    if i > 1 then
      rows[#rows + 1] = ui.Row {}
      lines = lines + 1
    end
    rows[#rows + 1] = ui.Row({ section.title }):style(ui.Style():fg("green"))
    lines = lines + 1
    for _, row in ipairs(section.rows) do
      local height = type(row.value) == "table" and #row.value or 1
      rows[#rows + 1] = ui.Row({ "  " .. row.label .. ":", row.value }):height(height)
      lines = lines + height
    end
  end

  -- the box fits its content; Yazi clips it to the screen and the table scrolls
  ya.spot_table(
    job,
    ui.Table(rows)
      :area(ui.Pos { "center", w = 100, h = lines + 2 })
      :row(1)
      :col(1)
      :col_style(th.spot.tbl_col)
      :cell_style(th.spot.tbl_cell)
      :widths { ui.Constraint.Length(16), ui.Constraint.Fill(1) }
  )
end

--- Spot a file, folder or snapshot of the ghost tree.
---@param job table
---@param session ResticSession
---@param path string
---@param location GhostLocation
local function spot_ghost(job, session, path, location)
  if location.path == "/" then -- a snapshot directory (or `latest`)
    local snapshot = get_snapshot(location.short_id)
    local alias = path == util.join(session.root, ghost.LATEST)
    return show(job, snapshot and info.snapshot(snapshot, alias) or info.message("Snapshot", "Not found"))
  end

  if ghost.is_marker(util.basename(path)) then
    return show(job, info.message("Folder", "Still being read from the backup"))
  end

  local node = get_entry(path)
  if not node and ensure_listed(util.parent(path)) then -- reused tree: the folder may not be listed yet
    node = get_entry(path)
  end
  if not node then
    return show(job, info.message("Backup entry", "No backup information available"))
  end

  local tally = node.type == "dir" and ensure_listed(path) and tally_of(path) or nil
  local stat = fs.cha(job.file.url)
  show(job, info.node(node, stat ~= nil and stat.len > 0, tally))
end

--- Spot a repository: its snapshots first, then (slower) the storage statistics.
---@param job table
---@param details PreviewRow[]  Rows of the "Repository" section.
---@param client table
local function spot_repository(job, details, client)
  local info_args = { details = details, note = "Reading the snapshots..." }
  show(job, info.repository(info_args))

  local err
  info_args.snapshots, err = client:snapshots()
  if not info_args.snapshots then
    info_args.note = err
    return show(job, info.repository(info_args))
  end
  info_args.note = "Calculating..."
  show(job, info.repository(info_args))

  info_args.stats, info_args.note = client:stats()
  show(job, info.repository(info_args))
end

--- Spot a `.restic` file: the statistics of the whole repository. The password of the open repository is reused;
--- otherwise it is asked for (and, as always, not kept).
---@param job table
---@param file string
local function spot_config(job, file)
  local cfg, err = config.read(file)
  if not cfg then
    return show(job, info.message("Repository", err))
  end
  local repository = config.resolve_repository(cfg.repository, folder_of(file))
  local exec
  exec, err = config.resolve_binary(cfg.restic_exec)
  local details = preview.compact { { "Location", repository }, { "Config file", file }, { "restic", exec } }
  if not exec then
    return show(job, info.repository { details = details, note = err })
  end

  local session = get_session()
  local password, batch
  if session and session.repository == repository then
    password, batch = session.password, session.ssh_batch_mode
  else
    show(job, info.repository { details = details, note = "Waiting for the password..." })
    password, batch = ask_password(), cfg.ssh_batch_mode
    if not password then
      return show(job, info.repository { details = details, note = "Password not entered" })
    end
  end
  spot_repository(
    job,
    details,
    Client.new { exec = exec, repository = repository, password = password, ssh_batch_mode = batch }
  )
end

--- Spotter (`Tab`): details of the hovered ghost entry or snapshot, or the statistics of a repository
--- (hovering its `.restic` file or the ghost root).
---@param job table
function M:spot(job)
  guarded(function()
    local path = tostring(job.file.url)
    local session = get_session()
    local location = session and ghost.locate(session.root, path, session.latest)
    if location then
      spot_ghost(job, session, path, location)
    elseif session and path == session.root then
      spot_repository(job, { { label = "Location", value = session.repository } }, client_for(session))
    elseif path:lower():match("%.restic$") and not ghost.is_inside(ghost.user_dir(), path) then
      spot_config(job, path)
    else
      local reason = session and "Not part of the open repository"
        or "No repository is open: press Enter on a .restic file"
      show(job, info.message("Restic", reason))
    end
  end)
end

return M
