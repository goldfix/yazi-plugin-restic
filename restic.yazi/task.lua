--- A Yazi task for operations that take a while (restore). While it runs, the status bar shows a gauge and the
--- task manager (`w`) lists the task with its progress, so a notification that fades does not leave the user
--- wondering. When it fails, the task stays in the task manager (Yazi keeps failed tasks) and its log holds the
--- reason; on success Yazi removes it from the list and the final notification tells the outcome.
---
--- `ya.task` is undocumented (the 26.9 Lua reference has no task API) but it is what Yazi's own long-running
--- plugins use (`extract`, `dnd`). Where it is unavailable, `start` returns a no-op handle: the caller's
--- notifications still tell the story.
local M = {}

---@class ResticTask
---@field private handle? table  The Yazi task, nil when the API is unavailable.
local Task = {}
Task.__index = Task

--- Run `fn(handle)` if there is a handle, swallowing failures: a task is a nicety, it must never break the
--- operation it reports on.
---@param self ResticTask
---@param fn fun(handle: table)
local function call(self, fn)
  if self.handle then
    pcall(fn, self.handle)
  end
end

--- Account one finished step (`succeeded` and `processed` are deltas, Yazi sums them).
function Task:step()
  call(self, function(handle) handle:progress { succeeded = 1, processed = 1 } end)
end

--- Append a line to the task log (the numbers restic reported, the destination…). Empty lines are ignored.
---@param line? string
function Task:log(line)
  if line and line ~= "" then
    call(self, function(handle) return handle:log(line) end)
  end
end

--- Drop the task from the task manager (used when the operation is cancelled).
function Task:cancel()
  call(self, function(handle) return handle:cancel() end)
end

--- Mark the task as done.
function Task:succeed()
  call(self, function(handle) return handle:succeed() end)
end

--- Mark the task as failed, keeping `reason` in its log (the error stays readable in the task manager).
---@param reason string
function Task:fail(reason)
  call(self, function(handle) return handle:fail(reason) end)
end

--- Start a task called `title` with `total` steps, already counted in the progress as work to do.
---@param title string  Shown in the task manager.
---@param total integer  Steps expected (restic calls); every `step()` counts one.
---@return ResticTask task  A handle even when Yazi did not create a task.
function M.start(title, total)
  local ok, handle = pcall(function()
    -- `pool` and `scope` are required, `track`/`progress` are what make the task appear with a gauge
    return ya.task("custom", { pool = "plugin", scope = rt.scope(), track = true, progress = true })
      :name(title)
      :spawn()
  end)

  local task = setmetatable({ handle = ok and handle or nil }, Task)
  task:log(title)
  call(task, function(own) return own:progress { total = total, workload = total } end)
  return task
end

return M
