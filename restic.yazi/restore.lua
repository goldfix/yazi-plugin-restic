--- Planning of restore operations: which snapshot paths must be handed to `restic restore`, and where to.
local config = require(".config")
local ghost = require(".ghost")
local util = require(".util")

local M = {}

---@class RestoreGroup
---@field short_id string
---@field paths string[]  Absolute paths inside the snapshot, none below another one ("/" = the whole snapshot).

--- Whether `path` is `ancestor` itself or lies below it (snapshot paths, "/" = the root).
---@param ancestor string
---@param path string
---@return boolean
local function covered_by(ancestor, path)
  return ancestor == "/" or path == ancestor or path:sub(1, #ancestor + 1) == ancestor .. "/"
end

--- Translate ghost paths (selection or hovered entry) to one group per snapshot, so that each snapshot needs a
--- single `restic restore` call. Duplicates (also those reached through `latest`) are dropped, and so is an entry
--- whose ancestor is selected too (restic restores it anyway). Groups and paths keep the order of the input.
--- Paths that are not backup entries (outside the snapshot directories, or the plugin's `.unfetched` markers)
--- are skipped and counted, so that the caller can tell the user.
---@param root string
---@param ghost_paths string[]
---@param latest? string  See `ghost.locate`.
---@return RestoreGroup[] groups
---@return integer skipped
function M.plan(root, ghost_paths, latest)
  local groups, by_id, skipped = {}, {}, 0
  for _, ghost_path in ipairs(ghost_paths) do
    local location = ghost.locate(root, ghost_path, latest)
    if not location or util.basename(location.path) == ghost.MARKER then
      skipped = skipped + 1
    else
      local group = by_id[location.short_id]
      if not group then
        group = { short_id = location.short_id, paths = {} }
        by_id[location.short_id] = group
        groups[#groups + 1] = group
      end
      group.paths[#group.paths + 1] = location.path
    end
  end
  for _, group in ipairs(groups) do
    local kept = {}
    for i, path in ipairs(group.paths) do
      local redundant = false
      for j, other in ipairs(group.paths) do
        -- identical paths: keep the first one only
        if i ~= j and covered_by(other, path) and (other ~= path or j < i) then
          redundant = true
          break
        end
      end
      if not redundant then
        kept[#kept + 1] = path
      end
    end
    group.paths = kept
  end
  return groups, skipped
end

--- Number of entries to restore in `groups`.
---@param groups RestoreGroup[]
---@return integer
function M.count(groups)
  local total = 0
  for _, group in ipairs(groups) do
    total = total + #group.paths
  end
  return total
end

--- Progress line shown before restoring group `index` of `total`.
---@param index integer
---@param total integer
---@param group RestoreGroup
---@return string
function M.progress(index, total, group)
  local text = string.format("Restoring %d item(s) from snapshot %s", #group.paths, group.short_id)
  return total > 1 and string.format("%s (%d/%d)", text, index, total) or text
end

--- Final message of a successful restore.
---@param total integer  Entries restored.
---@param dest string
---@param seconds integer  Elapsed wall time.
---@return string
function M.summary(total, dest, seconds)
  return string.format("Restored %d item(s) to %s in %s", total, dest, util.duration(seconds))
end

--- Validate the destination typed by the user: `~` is expanded, the path must be absolute (a relative one
--- would depend on Yazi's process directory) and must not lie inside the ghost tree.
---@param input string
---@param root string  Ghost root of the session.
---@return string? dest
---@return string? err
function M.destination(input, root)
  local dest = config.expand_home(util.trim(input)):gsub("(.)[/\\]+$", "%1")
  if dest == "" then
    return nil, "no destination given"
  elseif not config.is_absolute(dest) then
    return nil, "the destination must be an absolute path: " .. dest
  elseif ghost.is_inside(root, dest) then
    return nil, "the destination must be outside the backup browser: " .. dest
  end
  return dest
end

return M
