--- busted helper (loaded before every spec, see `.busted`).
--- Emulates the parts of the Yazi runtime the plugin relies on, so modules run under plain Lua:
---   * Yazi's relative `require(".module")`  -> `restic.yazi/module.lua`
---   * `Command`, `ya` (see yazi_mock.lua)
local PLUGIN_DIR = "restic.yazi"

local plain_require = require
local loaded = {}

---@param name string
function _G.require(name)
  local relative = name:match("^%.(.+)$")
  if not relative then
    return plain_require(name)
  end
  if not loaded[relative] then
    loaded[relative] = assert(loadfile(string.format("%s/%s.lua", PLUGIN_DIR, relative)))()
  end
  return loaded[relative]
end

require("spec.helpers.yazi_mock").install()
