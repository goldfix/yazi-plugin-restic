--- Minimal, synchronous stand-ins for the Yazi globals used by the plugin.
--- `Command` is backed by `io.popen`, so integration specs can drive a real `restic`.
local json = require("dkjson")

local M = {}

---@param s string
---@return string
local function shell_quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

--- Build the shell line for a command: env vars, program, args, stderr redirected to `errfile`.
local function shell_line(cmd, errfile)
  local parts = {}
  for key, value in pairs(cmd.envs) do
    parts[#parts + 1] = key .. "=" .. shell_quote(value)
  end
  parts[#parts + 1] = shell_quote(cmd.program)
  for _, arg in ipairs(cmd.args) do
    parts[#parts + 1] = shell_quote(arg)
  end
  local line = table.concat(parts, " ") .. " 2>" .. shell_quote(errfile)
  return cmd.dir and ("cd " .. shell_quote(cmd.dir) .. " && " .. line) or line
end

local function read_and_remove(path)
  local file = io.open(path, "rb")
  if not file then
    return ""
  end
  local text = file:read("a")
  file:close()
  os.remove(path)
  return text
end

---@param handle file*
---@param errfile string
local function new_child(handle, errfile)
  local child = {}
  local stderr_sent = false
  --- Mirrors `Child:read(len)`: (data, 0) from stdout, then stderr once as (data, 1), then ("", 2).
  function child:read(len)
    local data = handle:read(len)
    if data and #data > 0 then
      return data, 0
    end
    if not stderr_sent then
      stderr_sent = true
      local text = read_and_remove(errfile)
      if text ~= "" then
        return text, 1
      end
    end
    return "", 2
  end
  local function finish()
    local _, _, code = handle:close()
    return { success = code == 0, code = code }
  end
  function child:wait() return finish() end
  function child:wait_with_output()
    local stdout = handle:read("a")
    local status = finish()
    return { status = status, stdout = stdout, stderr = read_and_remove(errfile) }
  end
  return child
end

local Builder = {}
Builder.__index = Builder

function Builder:arg(arg)
  for _, a in ipairs(type(arg) == "table" and arg or { arg }) do
    self.args[#self.args + 1] = a
  end
  return self
end
function Builder:env(key, value)
  self.envs[key] = value
  return self
end
function Builder:cwd(dir)
  self.dir = dir
  return self
end
for _, name in ipairs { "stdin", "stdout", "stderr" } do
  Builder[name] = function(self) return self end
end

function Builder:spawn()
  local errfile = os.tmpname()
  local handle, err = io.popen(shell_line(self, errfile), "r")
  if not handle then
    return nil, err
  end
  return new_child(handle, errfile)
end
function Builder:output()
  local child, err = self:spawn()
  if not child then
    return nil, err
  end
  return child:wait_with_output()
end

--- Real uid of the test process (so ownership checks against files we create hold).
M.UID = tonumber(io.popen("id -u"):read("l"))

function M.install()
  _G.Command = setmetatable({ NULL = 0, PIPED = 1, INHERIT = 2 }, {
    __call = function(_, program) return setmetatable({ program = program, args = {}, envs = {} }, Builder) end,
  })

  _G.ya = {
    notifications = {},
    json_decode = function(s)
      local value, _, err = json.decode(s)
      if err then
        return nil, err
      end
      return value
    end,
    notify = function(opts) table.insert(_G.ya.notifications, opts) end,
    target_family = function() return "unix" end,
    uid = function() return M.UID end,
  }
end

return M
