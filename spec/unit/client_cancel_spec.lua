local Client = require(".client")

--- Replace the global `Command` with a fake that plays `steps` back, one per `read_line_with`.
--- Each step is `{ line, event }` (0 = stdout, 1 = stderr); the read returns end-of-input after the last one.
---@param steps table[]
---@param opts? { on_kill?: fun(), success?: boolean }  `success` is what restic exits with (default: killed or not).
---@return table calls  `calls.kills` counts the SIGTERMs, `calls.reads` the reads, `calls.args` the restic arguments.
local function install_fake(steps, opts)
  opts = opts or {}
  local calls = { kills = 0, reads = 0, args = {} }

  local function child()
    local index, killed = 0, false
    return {
      read_line_with = function()
        calls.reads = calls.reads + 1
        if killed then
          return nil, 2 -- a killed process yields no more data
        end
        index = index + 1
        local step = steps[index]
        if not step then
          return nil, 2
        end
        return step[1], step[2]
      end,
      start_kill = function()
        killed = true
        calls.kills = calls.kills + 1
        if opts.on_kill then
          opts.on_kill()
        end
        return true
      end,
      wait = function()
        local success = opts.success
        if success == nil then
          success = not killed
        end
        return { success = success, code = success and 0 or 1 }
      end,
    }
  end

  local Builder = {}
  Builder.__index = Builder
  function Builder:arg(arg)
    for _, value in ipairs(type(arg) == "table" and arg or { arg }) do
      calls.args[#calls.args + 1] = value
    end
    return self
  end
  function Builder:env() return self end
  function Builder:stdout() return self end
  function Builder:stderr() return self end
  function Builder:spawn() return child() end

  _G.Command = setmetatable({ NULL = 0, PIPED = 1, INHERIT = 2 }, {
    __call = function() return setmetatable({}, Builder) end,
  })
  return calls
end

describe("Client:restore with a cancellation check", function()
  local saved_command

  before_each(function() saved_command = _G.Command end)
  after_each(function() _G.Command = saved_command end)

  local function client()
    return Client.new {
      exec = "restic",
      repository = "/repo",
      password = "pw",
      json_decode = ya.json_decode,
    }
  end

  it("restores normally when nobody asks to stop", function()
    install_fake { { "restoring snapshot\n", 0 }, { "Summary: Restored 2 files\n", 0 } }
    local ok, err, stdout, cancelled = client():restore(
      "abc",
      { "/a" },
      "/out",
      { cancelled = function() return false end }
    )

    assert.is_true(ok)
    assert.is_nil(err)
    assert.is_nil(cancelled)
    assert.equals("restoring snapshot\nSummary: Restored 2 files\n", stdout)
  end)

  it("kills restic as soon as the caller asks to stop and reports a cancellation", function()
    local calls = install_fake { { "restoring snapshot\n", 0 }, { "more\n", 0 }, { "more\n", 0 } }
    local asked = 0
    local ok, err, _, cancelled = client():restore("abc", { "/a" }, "/out", {
      cancelled = function()
        asked = asked + 1
        return asked > 2 -- the user presses the key while restic is working
      end,
    })

    assert.is_true(cancelled)
    assert.is_nil(ok)
    assert.is_nil(err) -- a cancellation is not an error
    assert.equals(1, calls.kills) -- killed once, not on every poll
  end)

  it("keeps restic's stderr for the error message", function()
    install_fake(
      { { '{"message_type":"exit_error","code":12,"message":"wrong password"}\n', 1 } },
      { success = false }
    )
    local ok, err = client():restore("abc", { "/a" }, "/out", { cancelled = function() return false end })

    assert.is_nil(ok)
    assert.equals("wrong password", err)
  end)
end)
