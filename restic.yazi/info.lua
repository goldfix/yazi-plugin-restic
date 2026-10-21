--- Information tables of the spotter (`Tab`): what is known about a ghost entry, a snapshot or a repository.
---
--- Everything here is pure: it turns restic's JSON (nodes, snapshots, stats) into "sections", which `main.lua`
--- draws as a Yazi table. A section is `{ title, rows }`, a row `{ label, value }` where `value` is a string or a
--- list of strings (one per line).
local preview = require(".preview")
local snapshots = require(".snapshots")
local util = require(".util")

local M = {}

---@class InfoSection
---@field title string
---@field rows PreviewRow[]

--- "1 file", "3 files".
---@param n integer
---@param noun string
---@return string
local function count(n, noun) return string.format("%d %s%s", n, noun, n == 1 and "" or "s") end

--- "4.2K (4300 bytes)".
---@param bytes integer?
---@return string?
local function size(bytes)
  return bytes and string.format("%s (%d bytes)", util.human_size(bytes), bytes) or nil
end

--- "3 new, 1 changed, 10 unmodified".
---@param new integer?
---@param changed integer?
---@param unmodified integer?
---@return string?
local function changes(new, changed, unmodified)
  if not (new and changed and unmodified) then
    return nil
  end
  return string.format("%d new, %d changed, %d unmodified", new, changed, unmodified)
end

---@class DirTally
---@field dirs integer
---@field files integer
---@field links integer
---@field others integer
---@field bytes integer  Total size of the direct child files.

--- Count what a folder directly contains, from the listed nodes (keyed by ghost path).
---@param entries table<string, table>
---@param dir string  Ghost path of the folder.
---@return DirTally
function M.tally(entries, dir)
  local tally = { dirs = 0, files = 0, links = 0, others = 0, bytes = 0 }
  for path, node in pairs(entries) do
    if util.parent(path) == dir then
      if node.type == "dir" then
        tally.dirs = tally.dirs + 1
      elseif node.type == "file" then
        tally.files, tally.bytes = tally.files + 1, tally.bytes + (node.size or 0)
      elseif node.type == "symlink" then
        tally.links = tally.links + 1
      else
        tally.others = tally.others + 1
      end
    end
  end
  return tally
end

--- A file, folder or link inside a snapshot.
---@param node table  `restic ls --json` node.
---@param cached boolean  Whether the content is already present locally.
---@param tally? DirTally  Content of the folder (folders only).
---@return InfoSection[]
function M.node(node, cached, tally)
  local sections = { { title = "Backup entry", rows = preview.rows(node, cached) } }
  if tally then
    local parts = {}
    for _, item in ipairs {
      { tally.dirs, "folder" },
      { tally.files, "file" },
      { tally.links, "link" },
      { tally.others, "other" },
    } do
      if item[1] > 0 then
        parts[#parts + 1] = count(item[1], item[2])
      end
    end
    sections[2] = {
      title = "Contents",
      rows = preview.compact {
        { "Items", #parts > 0 and table.concat(parts, ", ") or "empty" },
        { "Files size", tally.files > 0 and size(tally.bytes) or nil },
      },
    }
  end
  return sections
end

--- One snapshot.
---@param snapshot ResticSnapshot
---@param alias? boolean  The snapshot was reached through the `latest` link.
---@return InfoSection[]
function M.snapshot(snapshot, alias)
  local owner = snapshot.username or ""
  if snapshot.uid and snapshot.gid then
    owner = string.format("%s (%d:%d)", owner, snapshot.uid, snapshot.gid)
  end

  local sections = {
    {
      title = "Snapshot",
      rows = preview.compact {
        { "ID", snapshot.id },
        { "Time", (preview.timestamp(snapshot.time) or "") .. (alias and "  (latest)" or "") },
        { "Host", snapshot.hostname },
        { "User", util.trim(owner) },
        { "Paths", snapshot.paths },
        { "Tags", snapshot.tags },
        { "Excludes", snapshot.excludes },
        { "Tree", snapshot.tree },
        { "Parent", snapshot.parent },
        { "Created by", snapshot.program_version },
      },
    },
  }

  local run = snapshot.summary
  if run then
    local started, finished = snapshots.epoch(run.backup_start or ""), snapshots.epoch(run.backup_end or "")
    local packed = run.data_added_packed
      and string.format(" (%s compressed)", util.human_size(run.data_added_packed))
    sections[2] = {
      title = "Backup run",
      rows = preview.compact {
        { "Started", preview.timestamp(run.backup_start) },
        { "Finished", preview.timestamp(run.backup_end) },
        { "Duration", started and finished and util.duration(math.floor(finished - started + 0.5)) or nil },
        { "Files", changes(run.files_new, run.files_changed, run.files_unmodified) },
        { "Folders", changes(run.dirs_new, run.dirs_changed, run.dirs_unmodified) },
        {
          "Processed",
          run.total_bytes_processed and string.format(
            "%s, %s",
            count(run.total_files_processed or 0, "file"),
            util.human_size(run.total_bytes_processed)
          ),
        },
        { "Added", run.data_added and (util.human_size(run.data_added) .. (packed or "")) or nil },
      },
    }
  end
  return sections
end

--- Rows describing the space used by the repository, or the reason why it is not known (yet).
---@param stats? table  `restic stats --mode raw-data --json`.
---@param note? string  Shown instead of the figures when `stats` is nil.
---@return PreviewRow[]
local function storage_rows(stats, note)
  if not stats then
    return { { label = "Status", value = note or "not available" } }
  end
  local compression
  if stats.compression_ratio and stats.compression_space_saving then
    compression =
      string.format("%.2fx (%.0f%% saved)", stats.compression_ratio, stats.compression_space_saving)
  end
  return preview.compact {
    { "Stored size", size(stats.total_size) },
    { "Uncompressed", size(stats.total_uncompressed_size) },
    { "Compression", compression },
    { "Blobs", stats.total_blob_count and tostring(stats.total_blob_count) or nil },
  }
end

---@class RepositoryInfo
---@field details PreviewRow[]  Rows of the "Repository" section (location, restic binary…).
---@field snapshots? ResticSnapshot[]
---@field stats? table  `restic stats --mode raw-data --json`.
---@field note? string  What to say instead of `stats` (error, "calculating…").

--- The whole repository.
---@param info RepositoryInfo
---@return InfoSection[]
function M.repository(info)
  local sections = { { title = "Repository", rows = info.details } }
  local list = info.snapshots
  if list and #list > 0 then
    local sorted, hosts, seen = snapshots.sorted(list), {}, {}
    for _, snapshot in ipairs(sorted) do
      if not seen[snapshot.hostname] then
        seen[snapshot.hostname], hosts[#hosts + 1] = true, snapshot.hostname
      end
    end
    local first, last = sorted[1], sorted[#sorted]
    sections[#sections + 1] = {
      title = "Snapshots",
      rows = preview.compact {
        { "Count", tostring(#list) },
        { "First", preview.timestamp(first.time) },
        { "Last", string.format("%s  (%s)", preview.timestamp(last.time), snapshots.short_id(last)) },
        { "Hosts", hosts },
      },
    }
    local run = last.summary
    if run and run.total_bytes_processed then
      sections[#sections + 1] = {
        title = "Latest snapshot",
        rows = preview.compact {
          { "Files", run.total_files_processed and tostring(run.total_files_processed) or nil },
          { "Size", size(run.total_bytes_processed) },
        },
      }
    end
  elseif list then
    sections[#sections + 1] = { title = "Snapshots", rows = { { label = "Count", value = "0" } } }
  end
  sections[#sections + 1] = { title = "Storage", rows = storage_rows(info.stats, info.note) }
  return sections
end

--- A single message (nothing to show but a reason).
---@param title string
---@param message string
---@return InfoSection[]
function M.message(title, message)
  return { { title = title, rows = { { label = "Info", value = message } } } }
end

return M
