--- Text shown in the preview pane for a ghost entry, built from the `restic ls --json` node.
local util = require(".util")

local M = {}

--- "2026-10-19T20:21:21.93+02:00" -> "2026-10-19 20:21:21 +02:00".
---@param iso? string
---@return string?
local function timestamp(iso)
  if not iso then
    return nil
  end
  local date, time, zone = iso:match("^(%d+%-%d+%-%d+)T(%d+:%d+:%d+)%S-([Z+-][%d:]*)$")
  if not date then
    return iso
  end
  return string.format("%s %s %s", date, time, zone == "Z" and "UTC" or zone)
end

---@param node table
---@return string
local function owner(node)
  local user, group = node.user or node.uid, node.group or node.gid
  return (user and group) and string.format("%s:%s", user, group) or ""
end

---@class PreviewRow
---@field label string
---@field value string

--- Labelled rows describing a node; empty/unknown fields are omitted.
---@param node table  `restic ls --json` node record.
---@param cached boolean  Whether the content is already present locally.
---@return PreviewRow[]
function M.rows(node, cached)
  local kind = node.type
  if node.linktarget then
    kind = string.format("%s -> %s", kind, node.linktarget)
  end

  local candidates = {
    { "Type", kind },
    { "Size", node.size and string.format("%s (%d bytes)", util.human_size(node.size), node.size) },
    { "Permissions", node.permissions },
    { "Owner", owner(node) },
    { "Modified", timestamp(node.mtime) },
    { "Accessed", timestamp(node.atime) },
    { "Changed", timestamp(node.ctime) },
    { "Backup path", node.path },
  }
  if node.type == "file" and (node.size or 0) > 0 then
    candidates[#candidates + 1] = { "Local copy", cached and "yes" or "no - press Enter to restore and open" }
  end

  local rows = {}
  for _, candidate in ipairs(candidates) do
    if candidate[2] and candidate[2] ~= "" then
      rows[#rows + 1] = { label = candidate[1], value = candidate[2] }
    end
  end
  return rows
end

return M
