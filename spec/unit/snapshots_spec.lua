local snapshots = require(".snapshots")

--- A snapshot record with sensible defaults; `overrides` replaces fields (use `false` to drop one).
local function snap(overrides)
  local record = {
    id = "e3e4a9ff683455825c32024fafec297dc59f60ab23e5a329967e1574d97c29bf",
    short_id = "e3e4a9ff",
    time = "2026-10-19T20:21:21.932104+02:00",
    hostname = "my host",
    paths = { "/data" },
    tags = { "daily", "home dir" },
  }
  for key, value in pairs(overrides or {}) do
    record[key] = value or nil
  end
  return record
end

describe("snapshots.dirname", function()
  it(
    "follows <timestamp>__<short_id>__<hostname>__[<tags>]",
    function()
      assert.equals("2026-10-19_18-21-21__e3e4a9ff__my_host__[daily,home_dir]", snapshots.dirname(snap()))
    end
  )

  it("derives the short id from the id and copes with missing tags", function()
    local name = snapshots.dirname(snap { short_id = false, tags = false })
    assert.equals("2026-10-19_18-21-21__e3e4a9ff__my_host__[]", name)
  end)
end)

describe("snapshots.dirname time", function()
  it("is the instant in the (pinned UTC) local time, whatever zone the snapshot was made in", function()
    local tokyo = snapshots.dirname(snap { time = "2026-10-20T10:00:00.5+09:00" })
    local rome = snapshots.dirname(snap { time = "2026-10-20T05:00:00+02:00" })
    assert.matches("^2026%-10%-20_01%-00%-00__", tokyo)
    assert.matches("^2026%-10%-20_03%-00%-00__", rome)
    assert.is_true(tokyo < rome) -- the folder order is the chronological order
  end)

  it(
    "keeps the text of a time it cannot parse",
    function()
      assert.matches(
        "^2026%-10%-19_20%-21%-21__",
        snapshots.dirname(snap { time = "2026-10-19T20:21:21 CEST" })
      )
    end
  )

  it("formats with the machine's local time by default", function()
    local pinned = snapshots.format_time
    local source = assert(loadfile("restic.yazi/snapshots.lua"))
    local fresh = assert(source())
    assert.equals(os.date("%Y-%m-%d_%H-%M-%S", 1792434081), fresh.format_time(1792434081.9))
    assert.equals(pinned, snapshots.format_time) -- the shared module still has the pinned one
  end)
end)

describe("snapshots.parse_dirname", function()
  it("round-trips the short id", function()
    assert.equals("e3e4a9ff", snapshots.parse_dirname(snapshots.dirname(snap())))
    assert.equals("e3e4a9ff", snapshots.parse_dirname(snapshots.dirname(snap { tags = {} })))
  end)

  it("rejects foreign names", function()
    assert.is_nil(snapshots.parse_dirname("latest"))
    assert.is_nil(snapshots.parse_dirname("random__dir"))
  end)
end)

describe("snapshots.sorted", function()
  it("orders oldest first without mutating the input", function()
    local a, b = snap { time = "2026-01-02T00:00:00+00:00" }, snap { time = "2026-01-01T00:00:00+00:00" }
    local input = { a, b }
    local out = snapshots.sorted(input)
    assert.equals(b, out[1])
    assert.equals(a, input[1])
  end)

  it("compares instants, not the text: snapshots made in different time zones", function()
    local tokyo = snap { time = "2026-10-20T10:00:00.5+09:00" } -- 01:00:00.5 UTC
    local rome = snap { time = "2026-10-20T05:00:00+02:00" } -- 03:00 UTC, after tokyo but smaller as text
    local utc = snap { time = "2026-10-20T02:00:00Z" }
    local out = snapshots.sorted { rome, utc, tokyo }
    assert.equals(tokyo, out[1])
    assert.equals(utc, out[2])
    assert.equals(rome, out[3])
  end)
end)

describe("snapshots.epoch", function()
  it("converts to UTC seconds whatever the zone and the fraction", function()
    -- expected values from Python: datetime.fromisoformat(<iso>).timestamp()
    assert.equals(0, snapshots.epoch("1970-01-01T00:00:00Z"))
    assert.equals(1792434081, snapshots.epoch("2026-10-19T20:21:21+02:00"))
    assert.equals(1792434081.932104, snapshots.epoch("2026-10-19T20:21:21.932104+02:00"))
    assert.equals(1792434081, snapshots.epoch("2026-10-19T14:21:21-04:00"))
    assert.equals(951782400, snapshots.epoch("2000-02-29T00:00:00+00:00")) -- leap day
    assert.is_nil(snapshots.epoch("yesterday"))
  end)
end)
