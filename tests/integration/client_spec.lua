local Client = require(".client")
local repo = require("spec.helpers.repo")

describe("client (real restic)", function()
  local fixture, client

  setup(function()
    fixture = repo.create()
    client = Client.new { exec = "restic", repository = fixture.repo, password = repo.PASSWORD }
  end)

  teardown(function() repo.destroy(fixture) end)

  it("lists snapshots", function()
    local snaps = assert(client:snapshots())
    assert.equals(2, #snaps)
    assert.is_string(snaps[1].id)
    assert.is_string(snaps[1].hostname)
  end)

  it("reports the repository statistics", function()
    local stats = assert(client:stats())
    assert.is_true(stats.total_size > 0)
    assert.is_true(stats.total_blob_count > 0)
    assert.equals(2, stats.snapshots_count)
  end)

  it("reports the restore size when asked", function()
    local stats = assert(client:stats("restore-size"))
    assert.is_true(stats.total_file_count > 0)
  end)

  it("reports a wrong password for the statistics too", function()
    local bad = Client.new { exec = "restic", repository = fixture.repo, password = "nope" }
    local stats, err = bad:stats()
    assert.is_nil(stats)
    assert.equals("wrong password", err)
  end)

  it("reports a wrong password", function()
    local bad = Client.new { exec = "restic", repository = fixture.repo, password = "nope" }
    local snaps, err = bad:snapshots()
    assert.is_nil(snaps)
    assert.equals("wrong password", err)
  end)

  it("reports a missing repository", function()
    local bad = Client.new { exec = "restic", repository = "/nonexistent/repo", password = "x" }
    local snaps, err = bad:snapshots()
    assert.is_nil(snaps)
    assert.is_string(err)
  end)

  it("reports a missing binary", function()
    local bad = Client.new { exec = "/nonexistent/restic", repository = fixture.repo, password = "x" }
    local snaps, err = bad:snapshots()
    assert.is_nil(snaps)
    assert.is_string(err)
  end)

  it("lists one directory level with ls", function()
    local id = assert(client:snapshots())[2].id
    local records = assert(client:ls(id, fixture.data))
    local paths = {}
    for _, r in ipairs(records) do
      if r.path then
        paths[r.path] = true
      end
    end
    assert.is_true(paths[fixture.data] and paths[fixture.data .. "/a.txt"] and paths[fixture.data .. "/docs"])
    assert.is_nil(paths[fixture.data .. "/docs/report.md"]) -- not recursive
  end)

  it("fetches a file and removes the staging area", function()
    local id = assert(client:snapshots())[1].id
    local dest, staging = fixture.dir .. "/out.txt", fixture.dir .. "/stage1"
    assert(client:fetch(id, fixture.data .. "/a.txt", dest, staging))
    assert.equals("hello\n", io.open(dest, "rb"):read("a"))
    assert.is_nil(require("lfs").attributes(staging))
  end)

  it("fetches binary files bigger than one block intact", function()
    local id = assert(client:snapshots())[1].id
    local dest = fixture.dir .. "/blob.bin"
    assert(client:fetch(id, fixture.data .. "/img/blob.bin", dest, fixture.dir .. "/stage2"))
    local copy = io.open(dest, "rb"):read("a")
    local original = io.open(fixture.data .. "/img/blob.bin", "rb"):read("a")
    assert.equals(#original, #copy)
    assert.is_true(original == copy)
  end)

  it("fetches names with pattern characters and overwrites a placeholder", function()
    local id = assert(client:snapshots())[2].id
    local dest = fixture.dir .. "/extra.txt"
    io.open(dest, "w"):close()
    assert(client:fetch(id, fixture.data .. "/docs/extra[1].txt", dest, fixture.dir .. "/stage3"))
    assert.equals("more", io.open(dest, "rb"):read("a"))
  end)

  it("leaves the placeholder untouched and no staging data on failure", function()
    local id = assert(client:snapshots())[1].id
    local dest = fixture.dir .. "/missing.txt"
    io.open(dest, "w"):close()
    local ok, err = client:fetch(id, fixture.data .. "/does-not-exist", dest, fixture.dir .. "/stage4")
    assert.is_nil(ok)
    assert.matches("not found", err)
    assert.equals(0, #io.open(dest, "rb"):read("a"))
    assert.is_nil(require("lfs").attributes(fixture.dir .. "/stage4"))
  end)

  it("fetches a file out of a read-only directory", function()
    local locked = fixture.dir .. "/locked-src/ro"
    os.execute(
      string.format("mkdir -p '%s' && printf locked > '%s/f.txt' && chmod 555 '%s'", locked, locked, locked)
    )
    os.execute(
      string.format(
        "RESTIC_PASSWORD=%s restic -r '%s' backup -q '%s' >/dev/null 2>&1",
        repo.PASSWORD,
        fixture.repo,
        locked
      )
    )
    local snaps = assert(client:snapshots())
    local dest = fixture.dir .. "/locked.txt"
    local ok, err = client:fetch(snaps[#snaps].id, locked .. "/f.txt", dest, fixture.dir .. "/stage5")
    os.execute(string.format("chmod 755 '%s'", locked))
    assert.is_true(ok, err)
    assert.equals("locked", io.open(dest, "rb"):read("a"))
  end)

  it("restores a directory with its content under the target", function()
    local id = assert(client:snapshots())[2].id
    local target = fixture.dir .. "/restored"
    assert(client:restore(id, { fixture.data .. "/docs" }, target))
    assert.equals("report body", io.open(target .. fixture.data .. "/docs/report.md", "rb"):read("a"))
    assert.equals("deep", io.open(target .. fixture.data .. "/docs/sub/deep.txt", "rb"):read("a"))
    assert.is_nil(io.open(target .. fixture.data .. "/a.txt")) -- only the requested subtree
  end)

  it("restores a whole snapshot when no include is given", function()
    local id = assert(client:snapshots())[1].id
    local target = fixture.dir .. "/restored3"
    assert(client:restore(id, { "/" }, target))
    assert.equals("hello\n", io.open(target .. fixture.data .. "/a.txt", "rb"):read("a"))
    assert.equals("deep", io.open(target .. fixture.data .. "/docs/sub/deep.txt", "rb"):read("a"))
  end)

  it("restores several includes with a single call, whole snapshot when '/' is among them", function()
    local id = assert(client:snapshots())[2].id
    local target = fixture.dir .. "/restored4"
    assert(client:restore(id, { fixture.data .. "/docs/sub", fixture.data .. "/docs/extra[1].txt" }, target))
    assert.equals("deep", io.open(target .. fixture.data .. "/docs/sub/deep.txt", "rb"):read("a"))
    assert.equals("more", io.open(target .. fixture.data .. "/docs/extra[1].txt", "rb"):read("a"))
    assert.is_nil(io.open(target .. fixture.data .. "/docs/report.md")) -- not requested
    assert.is_nil(io.open(target .. fixture.data .. "/a.txt"))

    local all = fixture.dir .. "/restored5"
    assert(client:restore(id, { fixture.data .. "/docs/sub", "/" }, all))
    assert.equals("report body", io.open(all .. fixture.data .. "/docs/report.md", "rb"):read("a"))
  end)

  it("restores a file whose name contains pattern characters", function()
    local id = assert(client:snapshots())[2].id
    local target = fixture.dir .. "/restored2"
    assert(client:restore(id, { fixture.data .. "/docs/extra[1].txt" }, target))
    assert.equals("more", io.open(target .. fixture.data .. "/docs/extra[1].txt", "rb"):read("a"))
  end)
end)
