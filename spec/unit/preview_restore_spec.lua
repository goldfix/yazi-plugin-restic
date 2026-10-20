local preview = require(".preview")
local restore = require(".restore")

describe("preview.rows", function()
  local node = {
    type = "file",
    path = "/data/a.txt",
    size = 1536,
    permissions = "-rw-r--r--",
    uid = 501,
    gid = 20,
    mtime = "2026-10-19T20:21:21.932104+02:00",
    atime = "2026-10-19T20:21:22Z",
  }

  local function as_map(rows)
    local map = {}
    for _, row in ipairs(rows) do
      map[row.label] = row.value
    end
    return map
  end

  it("describes a file", function()
    local map = as_map(preview.rows(node, false))
    assert.equals("file", map.Type)
    assert.equals("1.5K (1536 bytes)", map.Size)
    assert.equals("-rw-r--r--", map.Permissions)
    assert.equals("501:20", map.Owner)
    assert.equals("2026-10-19 20:21:21 +02:00", map.Modified)
    assert.equals("2026-10-19 20:21:22 UTC", map.Accessed)
    assert.equals("/data/a.txt", map["Backup path"])
    assert.matches("no", map["Local copy"])
    assert.is_nil(map.Changed)
  end)

  it(
    "reports a cached copy",
    function() assert.equals("yes", as_map(preview.rows(node, true))["Local copy"]) end
  )

  it("omits size/copy for directories and shows symlink targets", function()
    local dir = as_map(preview.rows({ type = "dir", path = "/data", permissions = "drwxr-xr-x" }, false))
    assert.is_nil(dir.Size)
    assert.is_nil(dir["Local copy"])
    local link = as_map(preview.rows({ type = "symlink", linktarget = "/etc/hosts", path = "/l" }, false))
    assert.equals("symlink -> /etc/hosts", link.Type)
  end)
end)

describe("restore.plan", function()
  local root = "/tmp/yazi-restic-1"
  local name = "2026-10-19_20-21-21__e3e4a9ff__h__[]"
  local snap = root .. "/" .. name
  local other = root .. "/2026-10-18_10-00-00__0badcafe__h__[]"

  it("maps ghost paths, dedups and skips (counting) what is not a backup entry", function()
    local groups, skipped = restore.plan(root, {
      snap .. "/data/docs",
      snap .. "/data/docs",
      "/etc/passwd",
      root, -- the ghost root itself
      snap .. "/data/.unfetched", -- the plugin's marker
      snap .. "/data/a",
    })
    assert.same({ { short_id = "e3e4a9ff", paths = { "/data/docs", "/data/a" } } }, groups)
    assert.equals(3, skipped)
  end)

  it("resolves 'latest' and treats it as the same snapshot", function()
    local groups = restore.plan(root, { root .. "/latest/data", snap .. "/data" }, name)
    assert.same({ { short_id = "e3e4a9ff", paths = { "/data" } } }, groups)
  end)

  it("makes one group per snapshot, in order of appearance", function()
    local groups = restore.plan(root, { snap .. "/a", other .. "/b", snap .. "/c" })
    assert.same({
      { short_id = "e3e4a9ff", paths = { "/a", "/c" } },
      { short_id = "0badcafe", paths = { "/b" } },
    }, groups)
    assert.equals(3, restore.count(groups))
  end)

  it("drops entries below another selected entry of the same snapshot", function()
    local groups =
      restore.plan(root, { snap .. "/data/docs/x.txt", snap .. "/data/docs", snap .. "/data/docs2" })
    assert.same({ { short_id = "e3e4a9ff", paths = { "/data/docs", "/data/docs2" } } }, groups) -- docs2 is no child
  end)

  it("keeps only the whole snapshot when it is selected", function()
    assert.same(
      { { short_id = "e3e4a9ff", paths = { "/" } } },
      restore.plan(root, { snap .. "/data/a", snap })
    )
    -- ...but a path below another snapshot is unaffected
    local groups = restore.plan(root, { snap, other .. "/data/a" })
    assert.same({ "/" }, groups[1].paths)
    assert.same({ "/data/a" }, groups[2].paths)
  end)
end)

describe("restore.progress / restore.summary", function()
  it("names the snapshot and counts groups only when there are several", function()
    assert.equals(
      "Restoring 3 item(s) from snapshot e3e4a9ff",
      restore.progress(1, 1, { short_id = "e3e4a9ff", paths = { "a", "b", "c" } })
    )
    assert.equals(
      "Restoring 1 item(s) from snapshot 0badcafe (2/2)",
      restore.progress(2, 2, { short_id = "0badcafe", paths = { "a" } })
    )
  end)

  it(
    "reports the elapsed time",
    function() assert.equals("Restored 2 item(s) to /x in 7s", restore.summary(2, "/x", 7)) end
  )
end)

describe("restore.destination", function()
  local root = "/tmp/yazi-restic-1/abcd"

  it("expands ~ and strips trailing separators", function()
    assert.equals(os.getenv("HOME") .. "/restored", restore.destination(" ~/restored/ ", root))
    assert.equals("/", restore.destination("/", root))
  end)

  it("rejects empty, relative and in-tree destinations", function()
    for _, bad in ipairs { "", "  ", "relative/dir", root, root .. "/snap/x", root .. "/" } do
      local dest, err = restore.destination(bad, root)
      assert.is_nil(dest, bad)
      assert.is_string(err)
    end
  end)

  it("accepts ancestors and siblings of the ghost tree", function()
    assert.equals("/tmp", restore.destination("/tmp", root))
    assert.equals("/tmp/yazi-restic-1/other", restore.destination("/tmp/yazi-restic-1/other", root))
  end)
end)
