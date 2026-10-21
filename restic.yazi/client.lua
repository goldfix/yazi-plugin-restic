--- Thin wrapper around the restic CLI.
---
--- All calls are asynchronous (Yazi `Command`) and must run in an async context. Every method returns
--- `result` or `nil, err` (an error message). The repository password is handed to restic through the
--- `RESTIC_PASSWORD` environment variable only: it never appears on a command line and never touches the disk.
local util = require(".util")

local Client = {}
Client.__index = Client

--- restic exit code for "wrong password or no key found".
local EXIT_WRONG_PASSWORD = 12

--- Environment variables that would override or conflict with the repository and password given here
--- (restic prefers a password file/command over `RESTIC_PASSWORD`, and rejects `-r` together with a
--- repository file). They are cleared for every call, so a user's shell setup cannot interfere.
local CLEARED_ENV = { "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND", "RESTIC_REPOSITORY_FILE" }

--- For sftp repositories restic runs `ssh`, which would ask for passphrases, passwords or host key
--- confirmations on the terminal Yazi is drawing on (garbling the screen, or hanging the plugin).
--- `BatchMode=yes` makes ssh fail immediately instead; the error then tells the user what to do.
local SSH_BATCH_ARGS = { "-o", "sftp.args=-o BatchMode=yes" }
local SSH_HINT = "ssh cannot ask questions inside Yazi: use a key without passphrase or ssh-agent, and connect "
  .. "once from a terminal to accept the host key (or set ssh_batch_mode = no in the .restic file)"

---@class ResticClientOpts
---@field exec string  restic binary.
---@field repository string  Value for `restic -r`.
---@field password string
---@field ssh_batch_mode? boolean  Forbid ssh prompts for sftp repositories (default true).
---@field json_decode? fun(s: string): any?, any?  Defaults to `ya.json_decode`.

---@param opts ResticClientOpts
---@return table client
function Client.new(opts)
  return setmetatable({
    exec = opts.exec,
    repository = opts.repository,
    password = opts.password,
    ssh_batch = opts.ssh_batch_mode ~= false and opts.repository:find("^sftp:") ~= nil,
    json_decode = opts.json_decode or ya.json_decode,
  }, Client)
end

--- Escape the characters restic treats as pattern syntax in `--include`.
---@param path string
---@return string
function Client.escape_pattern(path) return (path:gsub("[\\*?%[]", "\\%0")) end

--- Human readable failure reason. With `--json`, restic reports fatal errors on stderr as a JSON line
--- `{"message_type":"exit_error","code":…,"message":…}`; other commands print plain text. What ssh said
--- (`subprocess ssh: …` lines) is far more telling than restic's own sftp error, so it comes first.
---@param code integer?
---@param stderr string
---@return string
function Client:failure(code, stderr)
  local message, ssh = util.trim(stderr), {}
  for line in stderr:gmatch("[^\r\n]+") do
    local ok, record = pcall(self.json_decode, line)
    if ok and type(record) == "table" and record.message_type == "exit_error" then
      message = util.trim(tostring(record.message))
    end
    ssh[#ssh + 1] = line:match("^subprocess ssh: (.+)$")
  end

  if code == EXIT_WRONG_PASSWORD or message:find("wrong password", 1, true) then
    return "wrong password"
  elseif #ssh > 0 then
    message = "ssh: " .. table.concat(ssh, " ")
    return self.ssh_batch and (message .. " — " .. SSH_HINT) or message
  end
  return message ~= "" and message or string.format("restic exited with code %s", tostring(code))
end

--- Command line for a read-only restic call (`--no-lock`: no lock files, works on read-only repositories).
---@param args string[]
---@return table command
function Client:command(args)
  local command = Command(self.exec):arg { "-r", self.repository, "--no-lock" }
  if self.ssh_batch then
    command:arg(SSH_BATCH_ARGS)
  end
  command:arg(args)
  for _, name in ipairs(CLEARED_ENV) do
    command:env(name, "")
  end
  return command:env("RESTIC_PASSWORD", self.password)
end

--- Run restic to completion and return its stdout.
---@param args string[]
---@return string? stdout
---@return string? err
function Client:run(args)
  local output, err = self:command(args):output()
  if not output then
    return nil, string.format("cannot start restic: %s", tostring(err))
  elseif not output.status.success then
    return nil, self:failure(output.status.code, output.stderr)
  end
  return output.stdout
end

--- Decode a JSON document.
---@param text string
---@return any? value
---@return string? err
function Client:decode(text)
  local value, err = self.json_decode(text)
  if value == nil then
    return nil, string.format("invalid JSON from restic: %s", tostring(err))
  end
  return value
end

--- All snapshots of the repository.
---@return ResticSnapshot[]? snapshots
---@return string? err
function Client:snapshots()
  local stdout, err = self:run { "snapshots", "--json" }
  if not stdout then
    return nil, err
  end
  return self:decode(stdout)
end

--- Repository statistics of all snapshots (`restic stats --json`). `raw-data` (the default here) sums the unique
--- blobs the snapshots use: restic reads each distinct folder tree once (tree blobs are usually in restic's local
--- cache) and never file contents, whereas `restore-size` visits every entry of every snapshot again.
---@param mode? "raw-data"|"restore-size"|"files-by-contents"|"blobs-per-file"
---@return table? stats  `total_size`, `total_blob_count`, `snapshots_count`, compression fields (repository v2)…
---@return string? err
function Client:stats(mode)
  local stdout, err = self:run { "stats", "--json", "--mode", mode or "raw-data" }
  if not stdout then
    return nil, err
  end
  return self:decode(stdout)
end

--- Records of `restic ls --json` for one directory (JSON Lines): the snapshot header, the directory itself
--- and its direct children. Filtering is left to the caller (see `ghost.children`).
---@param snapshot_id string
---@param path string  Absolute path inside the snapshot.
---@return table[]? records
---@return string? err
function Client:ls(snapshot_id, path)
  local stdout, err = self:run { "ls", "--json", snapshot_id, path }
  if not stdout then
    return nil, err
  end

  local records = {}
  for line in stdout:gmatch("[^\r\n]+") do
    local record, decode_err = self:decode(line)
    if not record then
      return nil, decode_err
    end
    records[#records + 1] = record
  end
  return records
end

--- Materialise one file of the snapshot at `dest`, replacing whatever is there (the 0-byte placeholder).
---
--- Uses `restic restore` (restic writes the file itself) instead of streaming `restic dump` through Lua,
--- which is several times slower on large files. The file is restored into `staging` first and moved into
--- place only on success, so an interrupted run never leaves a truncated file that would look like a valid
--- cached copy. `<id>:<parent dir>` makes the parent the restore root: the file lands directly in `staging`,
--- and no ancestor directory (whose restored permissions could forbid moving the file out) is created.
---@param snapshot_id string
---@param path string  Absolute path of the file inside the snapshot.
---@param dest string  Local file to create/overwrite.
---@param staging string  Fresh directory on the same filesystem as `dest` (removed afterwards).
---@return boolean? ok
---@return string? err
function Client:fetch(snapshot_id, path, dest, staging)
  local staged = util.join(staging, util.basename(path))
  local ok, err =
    self:restore(snapshot_id .. ":" .. util.parent(path), { "/" .. util.basename(path) }, staging)

  local file = ok and io.open(staged, "rb") -- restic exits successfully when the path matches nothing
  if file then
    file:close()
    ok, err = os.rename(staged, dest)
    if not ok then -- Windows cannot rename over an existing file
      os.remove(dest)
      ok, err = os.rename(staged, dest)
    end
  elseif ok then
    ok, err = nil, "not found in snapshot: " .. path
  end

  os.remove(staged)
  os.remove(staging)
  return ok, err
end

--- Restore `includes` (files or directories, absolute paths inside the snapshot) below `target` with ONE restic
--- call (opening the repository is the expensive part), keeping their full paths (restic semantics). An empty
--- list, or one containing "/", restores the whole snapshot.
---@param snapshot_id string  Snapshot id, optionally `<id>:<subfolder>` to take `subfolder` as the root.
---@param includes? string[]
---@param target string  Existing or creatable local directory.
---@return boolean? ok
---@return string? err
function Client:restore(snapshot_id, includes, target)
  local args = { "restore", snapshot_id, "--target", target }
  includes = includes or {}
  if not util.contains(includes, "/") then
    for _, include in ipairs(includes) do
      table.insert(args, "--include")
      table.insert(args, Client.escape_pattern(include))
    end
  end

  local stdout, err = self:run(args)
  if not stdout then
    return nil, err
  end
  return true
end

return Client
