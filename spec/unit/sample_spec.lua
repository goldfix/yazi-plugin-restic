local config = require(".config")

--- `sample_backup.restic` is documentation users copy from: every example in it must really work.
describe("sample_backup.restic", function()
  local lines = {}
  do
    local file = assert(io.open("sample_backup.restic", "r"), "run busted from the project root")
    for line in file:lines() do
      lines[#lines + 1] = line
    end
    file:close()
  end

  local function parse(...) return config.parse(table.concat({ ... }, "\n")) end

  --- Example lines: a commented `key = value` for one of the real keys (prose never starts like that).
  local function examples(key)
    local found = {}
    for _, line in ipairs(lines) do
      local value = line:match("^#%s+" .. key .. "%s*=%s*(.-)%s*$")
      if value then
        found[#found + 1] = line:gsub("^#%s+", "")
      end
    end
    return found
  end

  it("is a valid configuration as shipped, with exactly one active repository", function()
    local cfg = assert(parse(table.unpack(lines)))
    assert.equals("./repo", cfg.repository)
    assert.is_nil(cfg.restic_exec)
    assert.is_true(cfg.ssh_batch_mode)

    local active = 0
    for _, line in ipairs(lines) do
      if line:find("^repository%s*=") then
        active = active + 1
      end
    end
    assert.equals(1, active)
  end)

  it("has working repository examples", function()
    local found = examples("repository")
    assert.is_true(#found >= 10, "expected many repository examples")
    for _, example in ipairs(found) do
      local cfg = assert(parse(example), example)
      assert.is_true(cfg.repository ~= "", example)
      assert.is_nil(cfg.repository:find("[#;]%s"), example) -- no comment smuggled into the value
    end
  end)

  it("has working restic_exec and ssh_batch_mode examples", function()
    assert.is_true(#examples("restic_exec") >= 3)
    for _, example in ipairs(examples("restic_exec")) do
      local cfg = assert(parse("repository = /r", example), example)
      assert.is_true(cfg.restic_exec ~= "", example)
    end
    local seen = {}
    for _, example in ipairs(examples("ssh_batch_mode")) do
      local cfg = assert(parse("repository = /r", example), example)
      seen[cfg.ssh_batch_mode] = true
    end
    assert.same({ [true] = true, [false] = true }, seen)
  end)

  it("keeps the documented keys and values in sync with the parser", function()
    local text = table.concat(lines, "\n")
    for _, word in ipairs {
      "repository",
      "restic_exec",
      "ssh_batch_mode",
      "yes, no, true, false, on, off, 1, 0",
    } do
      assert.is_truthy(text:find(word, 1, true), word)
    end
    for _, value in ipairs { "yes", "no", "true", "false", "on", "off", "1", "0" } do
      assert(parse("repository = /r\nssh_batch_mode = " .. value))
    end
  end)
end)
