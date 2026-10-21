local info = require(".info")

--- { title = { label = value } } for easy assertions.
local function as_map(sections)
  local map = {}
  for _, section in ipairs(sections) do
    map[section.title] = {}
    for _, row in ipairs(section.rows) do
      map[section.title][row.label] = row.value
    end
  end
  return map
end

describe("info.tally", function()
  local entries = {
    ["/g/snap/data/docs"] = { type = "dir" },
    ["/g/snap/data/a.txt"] = { type = "file", size = 1000 },
    ["/g/snap/data/b.txt"] = { type = "file", size = 24 },
    ["/g/snap/data/l"] = { type = "symlink" },
    ["/g/snap/data/p"] = { type = "fifo" },
    ["/g/snap/data/docs/deep.txt"] = { type = "file", size = 5 }, -- not a direct child
    ["/g/snap/other/x"] = { type = "file", size = 7 },
  }

  it(
    "counts the direct children by type and sums the file sizes",
    function()
      assert.same(
        { dirs = 1, files = 2, links = 1, others = 1, bytes = 1024 },
        info.tally(entries, "/g/snap/data")
      )
    end
  )

  it(
    "is all zeros for an empty or unlisted folder",
    function()
      assert.same(
        { dirs = 0, files = 0, links = 0, others = 0, bytes = 0 },
        info.tally(entries, "/g/snap/nothing")
      )
    end
  )
end)

describe("info.node", function()
  local file = { type = "file", path = "/data/a.txt", size = 6, permissions = "-rw-r--r--" }

  it("describes a file with the preview rows only", function()
    local sections = info.node(file, false)
    assert.equals(1, #sections)
    assert.equals("Backup entry", sections[1].title)
    assert.equals("/data/a.txt", as_map(sections)["Backup entry"]["Backup path"])
  end)

  it("adds the contents of a folder", function()
    local sections = as_map(
      info.node(
        { type = "dir", path = "/data" },
        false,
        { dirs = 1, files = 2, links = 0, others = 0, bytes = 2048 }
      )
    )
    assert.equals("1 folder, 2 files", sections.Contents.Items)
    assert.equals("2.0K (2048 bytes)", sections.Contents["Files size"])
  end)

  it("says that an empty folder is empty", function()
    local contents = as_map(
      info.node(
        { type = "dir", path = "/d" },
        false,
        { dirs = 0, files = 0, links = 0, others = 0, bytes = 0 }
      )
    ).Contents
    assert.equals("empty", contents.Items)
    assert.is_nil(contents["Files size"])
  end)
end)

describe("info.snapshot", function()
  local snapshot = {
    id = "29cca79ce3106c7dbd71d2c26f271c2cd87ac9ec56cbbd3997daa74ed1f91c75",
    time = "2026-10-21T18:43:47.8127+02:00",
    hostname = "myhost",
    username = "me",
    uid = 501,
    gid = 20,
    paths = { "/home/me/a", "/home/me/b" },
    tags = { "daily" },
    tree = "b32c",
    program_version = "restic 0.19.1",
    summary = {
      backup_start = "2026-10-21T18:43:47.8127+02:00",
      backup_end = "2026-10-21T18:44:50.2127+02:00",
      files_new = 2,
      files_changed = 1,
      files_unmodified = 7,
      dirs_new = 0,
      dirs_changed = 1,
      dirs_unmodified = 3,
      data_added = 4388,
      data_added_packed = 976,
      total_files_processed = 10,
      total_bytes_processed = 3006,
    },
  }

  it("lists the snapshot properties, one line per path", function()
    local map = as_map(info.snapshot(snapshot))
    assert.equals(snapshot.id, map.Snapshot.ID)
    assert.equals("2026-10-21 18:43:47 +02:00", map.Snapshot.Time)
    assert.equals("me (501:20)", map.Snapshot.User)
    assert.same({ "/home/me/a", "/home/me/b" }, map.Snapshot.Paths)
    assert.same({ "daily" }, map.Snapshot.Tags)
    assert.is_nil(map.Snapshot.Excludes)
    assert.is_nil(map.Snapshot.Parent)
    assert.equals("restic 0.19.1", map.Snapshot["Created by"])
  end)

  it("summarises the backup run", function()
    local run = as_map(info.snapshot(snapshot))["Backup run"]
    assert.equals("1m02s", run.Duration)
    assert.equals("2 new, 1 changed, 7 unmodified", run.Files)
    assert.equals("0 new, 1 changed, 3 unmodified", run.Folders)
    assert.equals("10 files, 2.9K", run.Processed)
    assert.equals("4.3K (976B compressed)", run.Added)
  end)

  it("marks the latest alias and copes with snapshots that have no summary", function()
    local copy = {}
    for key, value in pairs(snapshot) do
      copy[key] = value
    end
    copy.summary = nil
    local sections = info.snapshot(copy, true)
    assert.equals(1, #sections)
    assert.matches("%(latest%)$", as_map(sections).Snapshot.Time)
  end)
end)

describe("info.repository", function()
  local function snap(id, time, host, files)
    return {
      id = id .. "00000000",
      short_id = id,
      time = time,
      hostname = host,
      summary = files and { total_files_processed = files, total_bytes_processed = files * 100 } or nil,
    }
  end
  local list = {
    snap("aaaaaaaa", "2026-10-21T10:00:00+09:00", "tokyo", 5), -- 01:00 UTC: the oldest
    snap("bbbbbbbb", "2026-10-21T05:00:00+02:00", "paris", 7), -- 03:00 UTC: the newest despite the smaller text
    snap("cccccccc", "2026-10-21T02:00:00Z", "tokyo"),
  }
  local stats = {
    total_size = 2048,
    total_uncompressed_size = 8192,
    compression_ratio = 4,
    compression_space_saving = 75,
    total_blob_count = 12,
  }

  it("summarises snapshots by their real instants and lists the hosts once", function()
    local map = as_map(
      info.repository { details = { { label = "Location", value = "/repo" } }, snapshots = list, stats = stats }
    )
    assert.equals("/repo", map.Repository.Location)
    assert.equals("3", map.Snapshots.Count)
    assert.equals("2026-10-21 10:00:00 +09:00", map.Snapshots.First)
    assert.equals("2026-10-21 05:00:00 +02:00  (bbbbbbbb)", map.Snapshots.Last)
    assert.same({ "tokyo", "paris" }, map.Snapshots.Hosts)
    assert.equals("7", map["Latest snapshot"].Files)
    assert.equals("700B (700 bytes)", map["Latest snapshot"].Size)
  end)

  it("shows the storage figures", function()
    local storage = as_map(info.repository { details = {}, snapshots = list, stats = stats }).Storage
    assert.equals("2.0K (2048 bytes)", storage["Stored size"])
    assert.equals("8.0K (8192 bytes)", storage.Uncompressed)
    assert.equals("4.00x (75% saved)", storage.Compression)
    assert.equals("12", storage.Blobs)
  end)

  it("omits the compression of repositories that do not compress", function()
    local storage =
      as_map(info.repository { details = {}, snapshots = list, stats = { total_size = 10 } }).Storage
    assert.is_nil(storage.Compression)
    assert.is_nil(storage.Uncompressed)
  end)

  it("shows the note while the statistics are missing", function()
    local map = as_map(info.repository { details = {}, snapshots = list, note = "calculating..." })
    assert.equals("calculating...", map.Storage.Status)
  end)

  it("copes with an empty repository and with unknown snapshots", function()
    assert.equals("0", as_map(info.repository { details = {}, snapshots = {}, note = "-" }).Snapshots.Count)
    local map = as_map(info.repository { details = {}, note = "-" })
    assert.is_nil(map.Snapshots)
  end)
end)

describe("info.message", function()
  it(
    "is a section with one line",
    function() assert.equals("nope", as_map(info.message("Repository", "nope")).Repository.Info) end
  )
end)
