--- `GhostFs` implementation on plain Lua + luafilesystem, for specs that run without Yazi.
local lfs = require("lfs")

local M = {}

local function mkdir_p(path)
  local current = path:sub(1, 1) == "/" and "" or "."
  for part in path:gmatch("[^/]+") do
    current = current .. "/" .. part
    if not lfs.attributes(current) then
      local ok, err = lfs.mkdir(current)
      if not ok then
        return nil, err
      end
    end
  end
  return true
end

local function remove_all(path)
  local attr = lfs.symlinkattributes(path)
  if not attr then
    return true
  elseif attr.mode == "directory" then
    for name in lfs.dir(path) do
      if name ~= "." and name ~= ".." then
        remove_all(path .. "/" .. name)
      end
    end
  end
  return os.remove(path)
end

---@type GhostFs
M.fs = {
  mkdir = mkdir_p,
  touch = function(path)
    local file, err = io.open(path, "ab")
    if not file then
      return nil, err
    end
    file:close()
    return true
  end,
  exists = function(path) return lfs.symlinkattributes(path) ~= nil end,
  remove = function(path) return os.remove(path) end,
  remove_all = remove_all,
  symlink = function(target, link)
    os.remove(link)
    return lfs.link(target, link, true)
  end,
  owned = function(path)
    local attr = lfs.symlinkattributes(path)
    return attr ~= nil and attr.mode == "directory" and attr.uid == ya.uid()
  end,
  dirs = function(path)
    local names = {}
    if lfs.attributes(path) then
      for name in lfs.dir(path) do
        local attr = lfs.symlinkattributes(path .. "/" .. name)
        if attr and attr.mode == "directory" and name ~= "." and name ~= ".." then
          names[#names + 1] = name
        end
      end
    end
    table.sort(names)
    return names
  end,
  restrict = function(path) os.execute(string.format("chmod 700 '%s'", path)) end,
}

--- Sorted names in `dir` (without "." and "..").
---@param dir string
---@return string[]
function M.list(dir)
  local names = {}
  for name in lfs.dir(dir) do
    if name ~= "." and name ~= ".." then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

M.mkdir_p = mkdir_p

return M
