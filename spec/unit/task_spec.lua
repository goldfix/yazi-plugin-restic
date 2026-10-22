local Task = require(".task")

--- Stand-in for Yazi's task API: records what the plugin does with the handle it gets back.
---@param opts? { fail_start?: boolean, fail_handle?: boolean }
---@return table calls  `calls.events` = the handle calls, in order.
local function install_fake(opts)
  opts = opts or {}
  local calls = { events = {} }
  local function record(event) calls.events[#calls.events + 1] = event end

  _G.rt = {
    scope = function() return "scope" end,
  }
  _G.ya.task = function(kind, table_)
    calls.kind, calls.options = kind, table_
    if opts.fail_start then
      error("Run custom task: missing field track")
    end
    return {
      name = function(self, title)
        calls.title = title
        return self
      end,
      spawn = function()
        if opts.fail_handle then
          error("cannot create task")
        end
        return {
          progress = function(_, progress) record { progress = progress } end,
          log = function(_, line) record { log = line } end,
          succeed = function() record { succeed = true } end,
          fail = function(_, reason) record { fail = reason } end,
          cancel = function() record { cancel = true } end,
        }
      end,
    }
  end
  return calls
end

describe("Task.start", function()
  local saved

  before_each(function() saved = { task = ya.task, rt = _G.rt } end)

  after_each(function()
    ya.task, _G.rt = saved.task, saved.rt
  end)

  it("starts a tracked custom task with the title and the work to do", function()
    local calls = install_fake()
    Task.start("Restore 3 item(s)", 3)

    assert.equals("custom", calls.kind)
    assert.equals("plugin", calls.options.pool)
    assert.equals("scope", calls.options.scope)
    assert.is_true(calls.options.track)
    assert.is_true(calls.options.progress)
    assert.equals("Restore 3 item(s)", calls.title)
    -- the title is also the first log line, so the task manager shows what the task was about
    assert.same({ log = "Restore 3 item(s)" }, calls.events[1])
    assert.same({ progress = { total = 3, workload = 3 } }, calls.events[2])
  end)

  it("counts finished steps, keeps the log and records the outcome", function()
    local calls = install_fake()
    local task = Task.start("Restore 2 item(s)", 2)

    task:log("Restoring 2 item(s) from snapshot e3e4a9ff (1/2)")
    task:log(nil)
    task:log("")
    task:step()
    task:succeed()

    assert.same({ log = "Restoring 2 item(s) from snapshot e3e4a9ff (1/2)" }, calls.events[3])
    assert.same({ progress = { succeeded = 1, processed = 1 } }, calls.events[4])
    assert.same({ succeed = true }, calls.events[5])
    assert.equals(5, #calls.events) -- the empty line was not logged
  end)

  it("records a failure reason in the log", function()
    local calls = install_fake()
    Task.start("Restore 1 item(s)", 1):fail("Snapshot e3e4a9ff: wrong password")

    assert.same({ fail = "Snapshot e3e4a9ff: wrong password" }, calls.events[3])
  end)

  it("drops the task from the task manager when the operation is cancelled", function()
    local calls = install_fake()
    Task.start("Restore 1 item(s)", 1):cancel()

    assert.same({ cancel = true }, calls.events[3])
  end)

  it("degrades to a no-op without the Yazi task API", function()
    _G.ya.task = nil
    local task = Task.start("Restore 1 item(s)", 1)

    assert.is_truthy(task)
    assert.is_nil(task.handle)
    assert.is_nil(task:step())
    assert.is_nil(task:log("line"))
    assert.is_nil(task:succeed())
    assert.is_nil(task:fail("reason"))
    assert.is_nil(task:cancel())
  end)

  it("degrades to a no-op when Yazi rejects the task options", function()
    local calls = install_fake { fail_start = true }
    local task = Task.start("Restore 1 item(s)", 1)

    assert.is_nil(task.handle)
    assert.is_nil(calls.title) -- the task never came into existence
    assert.is_nil(task:step()) -- no error escapes
  end)

  it("keeps the operation going when the handle rejects a call", function()
    install_fake { fail_handle = true }
    local task = Task.start("Restore 1 item(s)", 1)

    assert.is_nil(task.handle)
    assert.is_nil(task:step())
  end)
end)
