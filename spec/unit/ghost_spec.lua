local ghost = require(".ghost")
local localfs = require("spec.helpers.localfs")

local ROOT = "/tmp/yazi-restic-501/1a2b3c4d"
local SNAP_DIR = "2026-10-19_20-21-21__e3e4a9ff__host__[]"

describe("ghost.root_for", function()
  it("is private to the user and distinct per repository", function()
    assert.equals(string.format("/tmp/yazi-restic-%d/1a2b3c4d", ya.uid()), ghost.root_for("1a2b3c4d"))
    assert.not_equals(ghost.root_for("aaaaaaaa"), ghost.root_for("bbbbbbbb"))
  end)

  it("uses a different base directory for another uid", function()
    local original = ya.uid
    ya.uid = function() return 777 end
    local root = ghost.root_for("1a2b3c4d")
    ya.uid = original
    assert.equals("/tmp/yazi-restic-777/1a2b3c4d", root)
  end)
end)

describe("ghost.ensure_user_dir", function()
  local original, dir

  before_each(function()
    dir = os.tmpname()
    os.remove(dir)
    original = ghost.user_dir
    ghost.user_dir = function() return dir end
  end)

  after_each(function()
    ghost.user_dir = original
    localfs.fs.remove_all(dir)
  end)

  it("creates the per-user directory, private", function()
    assert.is_true(ghost.ensure_user_dir(localfs.fs))
    assert.equals("rwx------", require("lfs").attributes(dir).permissions)
  end)

  it("accepts an existing directory of the user", function()
    localfs.mkdir_p(dir)
    assert.is_true(ghost.ensure_user_dir(localfs.fs))
  end)

  it("refuses a symlink planted in its place", function()
    local target = dir .. "-target"
    localfs.mkdir_p(target)
    require("lfs").link(target, dir, true)
    local ok, err = ghost.ensure_user_dir(localfs.fs)
    os.remove(dir)
    localfs.fs.remove_all(target)
    assert.is_nil(ok)
    assert.matches("refusing to use", err)
  end)

  it("refuses a directory owned by someone else, without touching it", function()
    local restricted = false
    local fsx = setmetatable({
      owned = function() return false end,
      restrict = function() restricted = true end,
    }, { __index = localfs.fs })
    local ok, err = ghost.ensure_user_dir(fsx)
    assert.is_nil(ok)
    assert.matches("not a directory owned by the current user", err)
    assert.is_false(restricted)
  end)
end)

describe("ghost path mapping", function()
  it("locates snapshot and in-backup path", function()
    local loc = assert(ghost.locate(ROOT, ROOT .. "/" .. SNAP_DIR .. "/home/me/a.txt"))
    assert.equals(SNAP_DIR, loc.snapshot_dir)
    assert.equals("e3e4a9ff", loc.short_id)
    assert.equals("/home/me/a.txt", loc.path)
  end)

  it(
    "maps the snapshot directory itself to '/'",
    function() assert.equals("/", ghost.locate(ROOT, ROOT .. "/" .. SNAP_DIR).path) end
  )

  it("rejects the root, foreign paths, look-alike prefixes and non-snapshot dirs", function()
    assert.is_nil(ghost.locate(ROOT, ROOT))
    assert.is_nil(ghost.locate(ROOT, "/home/me"))
    assert.is_nil(ghost.locate(ROOT, ROOT .. "-other/" .. SNAP_DIR))
    assert.is_nil(ghost.locate(ROOT, ROOT .. "/latest"))
    assert.is_nil(ghost.locate(ROOT, ROOT .. "/" .. ghost.STAGING .. "/x"))
  end)

  it("resolves paths through the latest symlink", function()
    local loc = assert(ghost.locate(ROOT, ROOT .. "/latest/home/me", SNAP_DIR))
    assert.equals(SNAP_DIR, loc.snapshot_dir)
    assert.equals("e3e4a9ff", loc.short_id)
    assert.equals("/home/me", loc.path)
    assert.equals("/", ghost.locate(ROOT, ROOT .. "/latest", SNAP_DIR).path)
  end)

  it("spells paths through latest via the real snapshot directory (one key per file)", function()
    local real = ROOT .. "/" .. SNAP_DIR
    assert.equals(real, ghost.canonical(ROOT, ROOT .. "/latest", SNAP_DIR))
    assert.equals(real .. "/home/me", ghost.canonical(ROOT, ROOT .. "/latest/home/me", SNAP_DIR))
    assert.equals(real .. "/home/me", ghost.canonical(ROOT, real .. "/home/me", SNAP_DIR))
    assert.equals(ROOT .. "/latest2/x", ghost.canonical(ROOT, ROOT .. "/latest2/x", SNAP_DIR)) -- look-alike
    assert.equals(ROOT .. "/latest/x", ghost.canonical(ROOT, ROOT .. "/latest/x", nil)) -- no snapshots
    assert.equals("/home/me", ghost.canonical(ROOT, "/home/me", SNAP_DIR))
  end)

  it("creates unique staging directories below the root", function()
    local a, b = ghost.staging_for(ROOT, ROOT .. "/x"), ghost.staging_for(ROOT, ROOT .. "/x")
    assert.not_equals(a, b)
    assert.matches("^" .. ROOT:gsub("%-", "%%-") .. "/%.staging/%x+$", a)
  end)

  it("is_inside is boundary aware", function()
    assert.is_true(ghost.is_inside(ROOT, ROOT))
    assert.is_true(ghost.is_inside(ROOT, ROOT .. "/x"))
    assert.is_false(ghost.is_inside(ROOT, ROOT .. "x"))
  end)
end)

describe("ghost.safe_name", function()
  it("accepts ordinary names and rejects dangerous ones", function()
    assert.is_true(ghost.safe_name("report.md"))
    assert.is_true(ghost.safe_name("..hidden"))
    for _, bad in ipairs { "", ".", "..", "a/b", "a\\b", ghost.MARKER, ghost.LEGACY_MARKER, "nul\0byte" } do
      assert.is_false(ghost.safe_name(bad), bad)
    end
  end)
end)

describe("ghost.children", function()
  local records = {
    { message_type = "snapshot", id = "x" },
    { name = "docs", type = "dir", path = "/data/docs" },
    { name = "z.txt", type = "file", path = "/data/docs/z.txt", size = 1 },
    { name = "a.txt", type = "file", path = "/data/docs/a.txt", size = 2 },
    { name = "deep.txt", type = "file", path = "/data/docs/sub/deep.txt" },
    { name = "..", type = "file", path = "/data/docs/.." },
  }

  it("keeps only sorted, direct, safe children", function()
    local names = {}
    for i, node in ipairs(ghost.children(records, "/data/docs")) do
      names[i] = node.name
    end
    assert.same({ "a.txt", "z.txt" }, names)
  end)

  it("lists the top level of a snapshot", function()
    local top = ghost.children({ { name = "data", type = "dir", path = "/data" } }, "/")
    assert.equals("data", top[1].name)
  end)
end)

describe("ghost tree", function()
  local root, session

  --- Fake restic client answering `ls` from a canned tree.
  local function fake_client(tree)
    return {
      ls = function(_, _, path) return tree[path] or nil, "unknown path " .. path end,
    }
  end

  before_each(function()
    root = os.tmpname()
    os.remove(root)
    root = root .. "-ghost"
    session = {
      root = root,
      client = fake_client {
        ["/"] = { { name = "data", type = "dir", path = "/data" } },
        ["/data"] = {
          { name = "data", type = "dir", path = "/data" },
          { name = "a.txt", type = "file", path = "/data/a.txt", size = 6 },
          { name = "docs", type = "dir", path = "/data/docs" },
          { name = "link", type = "symlink", path = "/data/link", linktarget = "/etc/passwd" },
        },
      },
    }
  end)

  after_each(function() localfs.fs.remove_all(root) end)

  local snapshots = {
    {
      id = "e3e4a9ff00",
      short_id = "e3e4a9ff",
      time = "2026-10-19T20:21:21+00:00",
      hostname = "host",
      tags = {},
    },
    {
      id = "11111111aa",
      short_id = "11111111",
      time = "2026-10-18T10:00:00+00:00",
      hostname = "host",
      tags = {},
    },
  }

  it("init_root creates one flagged directory per snapshot and a 'latest' link", function()
    local tree = assert(ghost.init_root(root, snapshots, localfs.fs))
    assert.same({
      "2026-10-18_10-00-00__11111111__host__[]",
      "2026-10-19_20-21-21__e3e4a9ff__host__[]",
      "latest",
    }, localfs.list(root))
    assert.equals(SNAP_DIR, tree.latest)
    assert.same({ ghost.MARKER }, localfs.list(root .. "/" .. SNAP_DIR))
    assert.equals(SNAP_DIR, require("lfs").symlinkattributes(root .. "/latest").target) -- relative link
  end)

  it("init_root without snapshots removes a stale 'latest' link", function()
    assert(ghost.init_root(root, snapshots, localfs.fs))
    local tree = assert(ghost.init_root(root, {}, localfs.fs))
    assert.is_nil(tree.latest)
    assert.same({}, localfs.list(root))
  end)

  it("expand works through the 'latest' link", function()
    local tree = assert(ghost.init_root(root, snapshots, localfs.fs))
    session.latest = tree.latest
    local entries = assert(ghost.expand(session, root .. "/latest", localfs.fs))
    assert.equals("dir", entries[root .. "/latest/data"].type)
    assert.same({ "data" }, localfs.list(root .. "/" .. SNAP_DIR)) -- same directory on disk
  end)

  it("init_root makes the root private", function()
    assert(ghost.init_root(root, snapshots, localfs.fs))
    assert.equals("rwx------", require("lfs").attributes(root).permissions)
  end)

  describe("reusing an existing tree", function()
    local dir, old_dir

    before_each(function()
      assert(ghost.init_root(root, snapshots, localfs.fs))
      dir = root .. "/" .. SNAP_DIR
      old_dir = root .. "/2026-10-18_10-00-00__11111111__host__[]"
      assert(ghost.expand(session, dir, localfs.fs))
      assert(ghost.expand(session, dir .. "/data", localfs.fs))
      local file = io.open(dir .. "/data/a.txt", "w")
      file:write("fetched")
      file:close()
    end)

    it("keeps fetched files and expanded folders", function()
      assert(ghost.init_root(root, snapshots, localfs.fs))
      assert.same({ ghost.MARKER, "a.txt", "docs", "link" }, localfs.list(dir .. "/data"))
      assert.equals(7, require("lfs").attributes(dir .. "/data/a.txt").size)
    end)

    it("flags every folder again so the metadata is listed anew", function()
      assert(ghost.init_root(root, snapshots, localfs.fs))
      for _, folder in ipairs { dir, dir .. "/data", dir .. "/data/docs" } do
        assert.is_true(localfs.fs.exists(folder .. "/" .. ghost.MARKER), folder)
      end
      local entries = assert(ghost.expand(session, dir .. "/data", localfs.fs))
      assert.is_false(localfs.fs.exists(dir .. "/data/" .. ghost.MARKER))
      assert.equals(6, entries[dir .. "/data/a.txt"].size)
      assert.equals(7, require("lfs").attributes(dir .. "/data/a.txt").size) -- still not truncated
    end)

    it("removes the hidden markers left by older versions", function()
      for _, folder in ipairs { dir, dir .. "/data" } do
        io.open(folder .. "/" .. ghost.LEGACY_MARKER, "w"):close()
      end
      assert(ghost.init_root(root, snapshots, localfs.fs))
      assert.same({ ghost.MARKER, "a.txt", "docs", "link" }, localfs.list(dir .. "/data"))
      assert.is_false(localfs.fs.exists(dir .. "/" .. ghost.LEGACY_MARKER))
    end)

    it("drops snapshots that no longer exist and adds the new ones", function()
      local newer = {
        id = "22222222bb",
        short_id = "22222222",
        time = "2026-10-20T10:00:00+00:00",
        hostname = "host",
        tags = {},
      }
      assert(ghost.init_root(root, { snapshots[1], newer }, localfs.fs))
      assert.is_false(localfs.fs.exists(old_dir))
      assert.is_true(localfs.fs.exists(root .. "/2026-10-20_10-00-00__22222222__host__[]"))
      assert.equals(
        "2026-10-20_10-00-00__22222222__host__[]",
        require("lfs").symlinkattributes(root .. "/latest").target
      )
    end)

    it("removes interrupted staging areas and leaves everything else alone", function()
      localfs.mkdir_p(root .. "/something-else")
      localfs.mkdir_p(root .. "/" .. ghost.STAGING .. "/0123abcd")
      localfs.mkdir_p(dir .. "/data/.a.txt.part") -- could be a real backed-up folder: never touched
      assert(ghost.init_root(root, snapshots, localfs.fs))
      assert.is_true(localfs.fs.exists(root .. "/something-else"))
      assert.is_true(localfs.fs.exists(dir .. "/data/.a.txt.part"))
      assert.is_false(localfs.fs.exists(root .. "/" .. ghost.STAGING))
    end)
  end)

  it("expand builds one level, flags sub-directories and removes the marker", function()
    assert(ghost.init_root(root, snapshots, localfs.fs))
    local dir = root .. "/" .. SNAP_DIR

    local entries = assert(ghost.expand(session, dir, localfs.fs))
    assert.same({ "data" }, localfs.list(dir))
    assert.same({ ghost.MARKER }, localfs.list(dir .. "/data"))
    assert.equals("dir", entries[dir .. "/data"].type)

    entries = assert(ghost.expand(session, dir .. "/data", localfs.fs))
    assert.same({ "a.txt", "docs", "link" }, localfs.list(dir .. "/data"))
    assert.same({ ghost.MARKER }, localfs.list(dir .. "/data/docs"))
    assert.equals(6, entries[dir .. "/data/a.txt"].size)
    -- symlinks become plain empty files: a repository must never make us follow a link outside the tree
    assert.is_nil(require("lfs").symlinkattributes(dir .. "/data/link").target)
    assert.equals(0, require("lfs").attributes(dir .. "/data/a.txt").size)
  end)

  it("expand never truncates an already fetched file", function()
    assert(ghost.init_root(root, snapshots, localfs.fs))
    local dir = root .. "/" .. SNAP_DIR
    assert(ghost.expand(session, dir, localfs.fs))
    assert(ghost.expand(session, dir .. "/data", localfs.fs))

    local file = io.open(dir .. "/data/a.txt", "w")
    file:write("fetched content")
    file:close()
    io.open(dir .. "/data/" .. ghost.MARKER, "w"):close() -- simulate a re-flagged directory
    assert(ghost.expand(session, dir .. "/data", localfs.fs))
    assert.equals(#"fetched content", require("lfs").attributes(dir .. "/data/a.txt").size)
  end)

  it("expand keeps the marker when restic fails", function()
    assert(ghost.init_root(root, snapshots, localfs.fs))
    local dir = root .. "/" .. SNAP_DIR
    local entries, err = ghost.expand(session, dir .. "/missing", localfs.fs)
    assert.is_nil(entries)
    assert.matches("unknown path", err)
    assert.same({ ghost.MARKER }, localfs.list(dir))
  end)

  it("expand refuses paths outside the tree", function()
    local entries, err = ghost.expand(session, "/etc", localfs.fs)
    assert.is_nil(entries)
    assert.matches("not inside a snapshot", err)
  end)
end)
