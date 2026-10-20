--- Naming and ordering of restic snapshots as directories of the ghost filesystem.
---
--- A snapshot directory is called `<timestamp>__<short_id>__<hostname>__[<tags>]`,
--- e.g. `2026-10-19_20-21-21__e3e4a9ff__myhost__[daily,home]`.
local util = require(".util")

local M = {}

---@class ResticSnapshot  Subset of the records returned by `restic snapshots --json`.
---@field id string
---@field short_id? string
---@field time string  ISO-8601, e.g. "2026-10-19T20:21:21.93+02:00".
---@field hostname string
---@field paths string[]
---@field tags? string[]

---@param snapshot ResticSnapshot
---@return string
local function short_id(snapshot) return snapshot.short_id or snapshot.id:sub(1, 8) end

--- Directory name of a snapshot.
---@param snapshot ResticSnapshot
---@return string
function M.dirname(snapshot)
  local stamp = snapshot.time:sub(1, 19):gsub("T", "_"):gsub(":", "-")
  local tags = {}
  for i, tag in ipairs(snapshot.tags or {}) do
    tags[i] = util.sanitize(tag)
  end
  return string.format(
    "%s__%s__%s__[%s]",
    stamp,
    short_id(snapshot),
    util.sanitize(snapshot.hostname),
    table.concat(tags, ",")
  )
end

--- Extract the short snapshot id from a directory name produced by `dirname`.
---@param name string
---@return string? short_id
function M.parse_dirname(name) return name:match("^[%d%-_]+__(%x+)__.-__%[.*%]$") end

--- Seconds since the Unix epoch (UTC) of a restic timestamp. restic keeps the time zone of the host that made
--- the snapshot ("…+09:00", "…-04:00", "…Z"), so the text alone does not sort: 10:00+09:00 is before 05:00+02:00.
---@param iso string  e.g. "2026-10-19T20:21:21.932104+02:00".
---@return number? seconds  Fractional; `nil` if `iso` is not a timestamp.
function M.epoch(iso)
  local y, mo, d, h, mi, s, frac, zone = iso:match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)(%.?%d*)(.*)$")
  if not y then
    return nil
  end
  y, mo = tonumber(y), tonumber(mo)
  -- days from civil (H. Hinnant): proleptic Gregorian calendar, no dependency on the local time zone
  y = mo <= 2 and y - 1 or y
  local era = y // 400
  local yoe = y - era * 400
  local doy = (153 * (mo + (mo > 2 and -3 or 9)) + 2) // 5 + tonumber(d) - 1
  local days = era * 146097 + yoe * 365 + yoe // 4 - yoe // 100 + doy - 719468
  local sign, zh, zm = zone:match("^([+-])(%d%d):?(%d%d)$")
  local offset = sign and (tonumber(zh) * 3600 + tonumber(zm) * 60) * (sign == "-" and -1 or 1) or 0
  return days * 86400
    + tonumber(h) * 3600
    + tonumber(mi) * 60
    + tonumber(s)
    + (tonumber("0" .. frac) or 0)
    - offset
end

--- Snapshots sorted from oldest to newest by their actual instant (see `epoch`); the input is not modified.
---@param snapshots ResticSnapshot[]
---@return ResticSnapshot[]
function M.sorted(snapshots)
  local copy = table.move(snapshots, 1, #snapshots, 1, {})
  local function key(snapshot) return M.epoch(snapshot.time) or 0 end
  table.sort(copy, function(a, b) return key(a) < key(b) end)
  return copy
end

return M
