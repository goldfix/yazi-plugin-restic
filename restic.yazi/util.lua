--- Small, side-effect-free helpers shared by the plugin modules.
local M = {}

--- Strip leading/trailing whitespace.
---@param s string
---@return string
function M.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Parent of a POSIX-style path ("/a/b" -> "/a", "/a" -> "/", "/" -> "/").
---@param path string
---@return string
function M.parent(path)
  local parent = path:match("^(.*)/[^/]*$")
  if parent == nil then
    return "."
  end
  return parent == "" and "/" or parent
end

--- Last component of a POSIX-style path ("/a/b" -> "b").
---@param path string
---@return string
function M.basename(path) return path:match("[^/]*$") end

--- Join path segments with a single "/" (no normalisation of "." or "..").
---@param ... string
---@return string
function M.join(...)
  local joined = table.concat({ ... }, "/"):gsub("/+", "/")
  return joined
end

--- Replace anything outside `[A-Za-z0-9._-]` with "_", collapsing runs, so the result is safe as a file name.
---@param s string
---@return string
function M.sanitize(s) return (s:gsub("[^%w%.%-]+", "_"):gsub("_+", "_")) end

--- 32-bit FNV-1a hash as 8 hex digits; a stable, dependency-free short identifier.
---@param s string
---@return string
function M.hash(s)
  local h = 0x811c9dc5
  for i = 1, #s do
    h = ((h ~ s:byte(i)) * 0x01000193) & 0xffffffff
  end
  return string.format("%08x", h)
end

--- Human readable size ("1.5K", "3M", ...).
---@param bytes integer
---@return string
function M.human_size(bytes)
  local units = { "B", "K", "M", "G", "T", "P" }
  local size, i = bytes, 1
  while size >= 1024 and i < #units do
    size, i = size / 1024, i + 1
  end
  return i == 1 and string.format("%dB", size) or string.format("%.1f%s", size, units[i])
end

--- Whether the list `list` contains `value`.
---@param list any[]
---@param value any
---@return boolean
function M.contains(list, value)
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

--- Elapsed whole seconds as text: "5s", "2m05s", "1h02m".
---@param seconds integer
---@return string
function M.duration(seconds)
  if seconds < 60 then
    return string.format("%ds", seconds)
  elseif seconds < 3600 then
    return string.format("%dm%02ds", seconds // 60, seconds % 60)
  end
  return string.format("%dh%02dm", seconds // 3600, seconds % 3600 // 60)
end

return M
