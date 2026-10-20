local Client = require(".client")
local ghost = require(".ghost")
local localfs = require("spec.helpers.localfs")
local repo = require("spec.helpers.repo")
local snapshots = require(".snapshots")

--- Whole read path against a real restic repository: snapshots -> ghost root -> lazy expansion -> fetch.
describe("ghost + client (real restic)", function()
  local fixture, client, root, session, snapshot_dir

  setup(function()
    fixture = repo.create()
    client = Client.new { exec = "restic", repository = fixture.repo, password = repo.PASSWORD }
    root = fixture.dir .. "/ghost"
    session = { root = root, client = client }

    local list = assert(client:snapshots())
    assert(ghost.init_root(root, list, localfs.fs))
    for _, snapshot in ipairs(list) do
      if snapshot.tags and snapshot.tags[1] == "second" then
        snapshot_dir = root .. "/" .. snapshots.dirname(snapshot)
      end
    end
  end)

  teardown(function() repo.destroy(fixture) end)

  it("walks the absolute backup path level by level, creating only what is asked for", function()
    local dir = snapshot_dir
    -- Descend through every component of the (absolute, deep) path of the backed-up directory.
    for component in fixture.data:gmatch("[^/]+") do
      assert(ghost.expand(session, dir, localfs.fs))
      dir = dir .. "/" .. component
      assert.same({ ghost.MARKER }, localfs.list(dir))
    end

    local entries = assert(ghost.expand(session, dir, localfs.fs))
    assert.same({ "a.txt", "docs", "img" }, localfs.list(dir))
    assert.equals(6, entries[dir .. "/a.txt"].size)
    assert.same({ ghost.MARKER }, localfs.list(dir .. "/docs")) -- children not fetched yet
    assert.equals(0, require("lfs").attributes(dir .. "/a.txt").size)
  end)

  it("fetches a ghost file using the path mapping", function()
    local ghost_file = snapshot_dir .. fixture.data .. "/a.txt"
    local location = assert(ghost.locate(root, ghost_file))
    assert.equals(fixture.data .. "/a.txt", location.path)

    assert(client:fetch(location.short_id, location.path, ghost_file, ghost.staging_for(root, ghost_file)))
    assert.equals("hello\n", io.open(ghost_file, "rb"):read("a"))
  end)

  it("expands directories whose names contain spaces and unicode", function()
    local dir = fixture.data .. "/s p\xc3\xa0ce"
    os.execute(string.format("mkdir -p '%s' && printf x > '%s/f\xc3\xa8.txt'", dir, dir))
    os.execute(
      string.format(
        "RESTIC_PASSWORD=%s restic -r '%s' backup -q '%s' >/dev/null 2>&1",
        repo.PASSWORD,
        fixture.repo,
        fixture.data
      )
    )

    local latest = assert(client:snapshots())
    local newest = latest[#latest]
    local ghost_dir = root .. "/2000-01-01_00-00-00__" .. newest.short_id .. "__h__[]" .. fixture.data
    localfs.mkdir_p(ghost_dir)
    assert(ghost.expand(session, ghost_dir, localfs.fs))
    assert.is_true(localfs.fs.exists(ghost_dir .. "/s p\xc3\xa0ce"))
  end)
end)
