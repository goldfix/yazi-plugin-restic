--- Builds a real restic repository in a temp dir for integration specs.
local M = {}

M.PASSWORD = "secret"

---@param cmd string
local function sh(cmd)
  local ok = os.execute("{ " .. cmd .. "; } >/dev/null 2>&1")
  assert(ok, "command failed: " .. cmd)
end

--- Create `<tmp>/data` (a.txt, docs/report.md, docs/sub/deep.txt, img/blob.bin) and back it up twice
--- (second snapshot tagged "second" with an extra file). Returns `{ dir, repo, data }`.
---@return table fixture
function M.create()
  local dir = os.tmpname()
  os.remove(dir)
  local data, repo = dir .. "/data", dir .. "/repo"
  sh(string.format("mkdir -p '%s/docs/sub' '%s/img'", data, data))
  sh(string.format("printf 'hello\\n' > '%s/a.txt'", data))
  sh(string.format("printf 'report body' > '%s/docs/report.md'", data))
  sh(string.format("printf 'deep' > '%s/docs/sub/deep.txt'", data))
  sh(string.format("head -c 5000 /dev/urandom > '%s/img/blob.bin'", data))

  local env = string.format("RESTIC_PASSWORD='%s' restic -r '%s' ", M.PASSWORD, repo)
  sh(env .. "init")
  sh(env .. string.format("backup '%s'", data))
  sh(string.format("printf 'more' > '%s/docs/extra[1].txt'", data))
  sh(env .. string.format("backup --tag second '%s'", data))
  return { dir = dir, repo = repo, data = data }
end

---@param fixture table
function M.destroy(fixture) os.execute(string.format("rm -rf '%s'", fixture.dir)) end

return M
