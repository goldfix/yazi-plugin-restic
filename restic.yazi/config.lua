--- Parsing of `.restic` repository files and discovery of the restic binary.
---
--- A `.restic` file holds `key = value` lines; `#` and `;` start comment lines:
---   repository     = sftp:user@host:/srv/restic-repo
---   restic_exec    = /usr/local/bin/restic   (optional, defaults to `restic` from $PATH)
---   ssh_batch_mode = no                      (optional, sftp only, defaults to yes; see `client.lua`)
--- Values are taken verbatim (no inline comments, since `#` may be part of a path); quotes are optional.
local util = require(".util")

local M = {}

--- Oldest supported restic: `restore <id>:<subfolder>` (used to fetch single files) appeared in 0.17.0.
M.MIN_VERSION = { 0, 17, 0 }

---@class ResticConfig
---@field repository string  Repository location as understood by `restic -r`.
---@field restic_exec? string  Path of the restic binary; empty/absent means "look it up in $PATH".
---@field ssh_batch_mode boolean  Forbid ssh prompts for sftp repositories (default true).

local BOOLEANS = {
  yes = true,
  ["true"] = true,
  on = true,
  ["1"] = true,
  no = false,
  ["false"] = false,
  off = false,
  ["0"] = false,
}

--- Parse the text of a `.restic` file.
---@param text string
---@return ResticConfig? config
---@return string? err
function M.parse(text)
  local config = {}
  for raw in text:gsub("^\239\187\191", ""):gmatch("[^\r\n]+") do -- tolerate a UTF-8 BOM
    local line = util.trim(raw)
    local key, value = line:match("^([%w_]+)%s*=%s*(.-)$")
    if key and not line:find("^[#;]") then
      config[key:lower()] = value:match('^"(.*)"$') or value:match("^'(.*)'$") or value
    end
  end

  if not config.repository or config.repository == "" then
    return nil, "missing 'repository' in .restic file"
  end

  local batch = true
  if config.ssh_batch_mode and config.ssh_batch_mode ~= "" then
    batch = BOOLEANS[config.ssh_batch_mode:lower()]
    if batch == nil then
      return nil,
        string.format("invalid 'ssh_batch_mode' value '%s' (expected yes or no)", config.ssh_batch_mode)
    end
  end
  return { repository = config.repository, restic_exec = config.restic_exec, ssh_batch_mode = batch }
end

--- Read and parse a `.restic` file from disk.
---@param path string
---@return ResticConfig? config
---@return string? err
function M.read(path)
  local file, err = io.open(path, "r")
  if not file then
    return nil, err
  end
  local text = file:read("a")
  file:close()
  return M.parse(text)
end

--- Expand a leading `~` to the home directory (restic, run without a shell, would not do it).
---@param path string
---@return string
function M.expand_home(path)
  local home = os.getenv("HOME") or os.getenv("USERPROFILE")
  if home and (path == "~" or path:find("^~[/\\]")) then
    return home .. path:sub(2)
  end
  return path
end

--- Whether a local path is absolute (POSIX `/…`, Windows `C:\…`, `C:/…` or `\\server\…`).
---@param path string
---@return boolean
function M.is_absolute(path)
  return path:find("^/") ~= nil or path:find("^%a:[/\\]") ~= nil or path:find("^\\\\") ~= nil
end

--- Make a local repository path absolute: `~` is expanded, relative paths are anchored to the directory
--- of the `.restic` file. Backend URLs (`sftp:`, `s3:`, `rest:`, `local:`, ...) are returned unchanged.
---@param repository string
---@param base_dir string
---@return string
function M.resolve_repository(repository, base_dir)
  local has_backend = repository:find("^%a[%w+.-]+:") ~= nil -- two or more letters, so `C:\` is a path
  local path = M.expand_home(repository)
  if has_backend or M.is_absolute(path) then
    return path
  end
  return util.join(base_dir, (path:gsub("^%./", "")))
end

--- Stable short identifier of a repository, used to name the ghost root directory.
---@param repository string
---@return string
function M.repo_id(repository) return util.hash(repository) end

--- Parse the output of `restic version` ("restic 0.19.1 compiled with ...").
---@param text string
---@return integer[]? version  { major, minor, patch }
function M.parse_version(text)
  local major, minor, patch = text:match("restic (%d+)%.(%d+)%.?(%d*)")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) or 0 }
end

--- Whether `version` is at least `min`.
---@param version integer[]
---@param min integer[]
---@return boolean
function M.at_least(version, min)
  for i = 1, 3 do
    if version[i] ~= min[i] then
      return version[i] > min[i]
    end
  end
  return true
end

--- Run `<candidate> version`; this validates an explicit path and a `$PATH` lookup alike, on every platform.
---@param candidate string
---@return string? stdout  `nil` when the binary cannot be run.
local function version_of(candidate)
  local output = Command(candidate):arg("version"):output()
  return (output and output.status.success) and output.stdout or nil
end

--- Resolve the restic binary: `restic_exec` if given (with `~` expanded), otherwise `restic` from `$PATH`,
--- and check that it is recent enough.
---@param restic_exec? string
---@param probe? fun(candidate: string): string?  Returns the `restic version` output (injectable for tests).
---@return string? binary
---@return string? err
function M.resolve_binary(restic_exec, probe)
  local candidate = (restic_exec and restic_exec ~= "") and M.expand_home(restic_exec) or "restic"
  local output = (probe or version_of)(candidate)
  if not output then
    return nil, string.format("cannot execute restic binary '%s'", candidate)
  end

  local version = M.parse_version(output)
  if version and not M.at_least(version, M.MIN_VERSION) then
    return nil,
      string.format(
        "restic %s found, %s or newer is required",
        table.concat(version, "."),
        table.concat(M.MIN_VERSION, ".")
      )
  end
  return candidate
end

return M
