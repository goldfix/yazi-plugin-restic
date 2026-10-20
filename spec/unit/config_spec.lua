local config = require(".config")

describe("config.parse", function()
  it("reads repository and restic_exec", function()
    local cfg = assert(config.parse("repository = sftp:u@h:/srv/repo\nrestic_exec = /usr/local/bin/restic\n"))
    assert.equals("sftp:u@h:/srv/repo", cfg.repository)
    assert.equals("/usr/local/bin/restic", cfg.restic_exec)
  end)

  it("ignores comments, blank lines, CRLF and unknown keys", function()
    local cfg = assert(config.parse("# comment\r\n; other\r\n\r\nfoo = bar\r\nrepository=/srv/r\r\n"))
    assert.equals("/srv/r", cfg.repository)
    assert.is_nil(cfg.restic_exec)
  end)

  it("keeps '=' inside values and strips quotes", function()
    local cfg = assert(config.parse('repository = "s3:host/bucket?a=b"'))
    assert.equals("s3:host/bucket?a=b", cfg.repository)
  end)

  it(
    "is case-insensitive on keys",
    function() assert.equals("/r", assert(config.parse("Repository = /r")).repository) end
  )

  it("does not treat commented keys as settings", function()
    local cfg, err = config.parse("# repository = /hidden")
    assert.is_nil(cfg)
    assert.matches("repository", err)
  end)

  it("fails without a repository", function()
    local cfg, err = config.parse("restic_exec = restic")
    assert.is_nil(cfg)
    assert.matches("repository", err)
  end)
end)

describe("config.read", function()
  it("reports unreadable files", function()
    local cfg, err = config.read("/nonexistent/file.restic")
    assert.is_nil(cfg)
    assert.is_string(err)
  end)
end)

describe("config.repo_id", function()
  it("is stable and distinguishes repositories", function()
    assert.equals(config.repo_id("/srv/a"), config.repo_id("/srv/a"))
    assert.not_equals(config.repo_id("/srv/a"), config.repo_id("/srv/b"))
  end)
end)

describe("config.resolve_binary", function()
  local function probe_for(name, output)
    return function(candidate)
      return candidate == name and (output or "restic 0.19.1 compiled with go1.26") or nil
    end
  end

  it(
    "uses the explicit path when it runs",
    function() assert.equals("/opt/restic", config.resolve_binary("/opt/restic", probe_for("/opt/restic"))) end
  )

  it("falls back to 'restic' on $PATH when empty or missing", function()
    assert.equals("restic", config.resolve_binary(nil, probe_for("restic")))
    assert.equals("restic", config.resolve_binary("", probe_for("restic")))
  end)

  it("expands ~ in restic_exec", function()
    local home = os.getenv("HOME")
    assert.equals(
      home .. "/bin/restic",
      config.resolve_binary("~/bin/restic", probe_for(home .. "/bin/restic"))
    )
  end)

  it("reports the failing candidate", function()
    local bin, err = config.resolve_binary("/nope/restic", function() return nil end)
    assert.is_nil(bin)
    assert.matches("/nope/restic", err)
  end)

  it("rejects restic versions older than the minimum", function()
    local bin, err = config.resolve_binary(nil, probe_for("restic", "restic 0.16.4 compiled with go1.22"))
    assert.is_nil(bin)
    assert.matches("0.16.4 found, 0.17.0 or newer is required", err)
  end)

  it(
    "accepts unparsable version strings (custom builds)",
    function() assert.equals("restic", config.resolve_binary(nil, probe_for("restic", "something else"))) end
  )

  it("really probes binaries through Command", function()
    assert.is_nil((config.resolve_binary("/nonexistent/restic")))
    assert.equals("restic", config.resolve_binary("restic")) -- the real one, >= 0.17 on the dev machine
  end)
end)

describe("config versions", function()
  it("parses release and dev version strings", function()
    assert.same({ 0, 19, 1 }, config.parse_version("restic 0.19.1 compiled with go1.26.5 on darwin/arm64"))
    assert.same({ 0, 17, 3 }, config.parse_version("restic 0.17.3-dev (compiled manually) compiled with go"))
    assert.same({ 1, 0, 0 }, config.parse_version("restic 1.0 compiled"))
    assert.is_nil(config.parse_version("nope"))
  end)

  it("compares versions", function()
    assert.is_true(config.at_least({ 0, 17, 0 }, { 0, 17, 0 }))
    assert.is_true(config.at_least({ 0, 18, 0 }, { 0, 17, 9 }))
    assert.is_true(config.at_least({ 1, 0, 0 }, { 0, 17, 0 }))
    assert.is_false(config.at_least({ 0, 16, 9 }, { 0, 17, 0 }))
  end)
end)

describe("config paths", function()
  local home = os.getenv("HOME")

  it("expands a leading ~ only", function()
    assert.equals(home, config.expand_home("~"))
    assert.equals(home .. "/x", config.expand_home("~/x"))
    assert.equals("~user/x", config.expand_home("~user/x"))
    assert.equals("/a/~/b", config.expand_home("/a/~/b"))
  end)

  it("recognises absolute paths", function()
    for _, p in ipairs { "/a", "C:\\a", "c:/a", "\\\\server\\share" } do
      assert.is_true(config.is_absolute(p), p)
    end
    for _, p in ipairs { "a", "./a", "~/a", "C:" } do
      assert.is_false(config.is_absolute(p), p)
    end
  end)
end)

describe("config.resolve_repository", function()
  it("keeps absolute paths and backend URLs", function()
    for _, repo in ipairs {
      "/srv/repo",
      "sftp:u@h:/srv/repo",
      "s3:s3.amazonaws.com/bucket",
      "rest:https://h/r",
      "C:\\repo",
    } do
      assert.equals(repo, config.resolve_repository(repo, "/home/me"))
    end
  end)

  it(
    "expands ~ in local repository paths",
    function()
      assert.equals(
        os.getenv("HOME") .. "/backups/repo",
        config.resolve_repository("~/backups/repo", "/elsewhere")
      )
    end
  )

  it("anchors relative paths to the .restic directory", function()
    assert.equals("/home/me/repo", config.resolve_repository("repo", "/home/me"))
    assert.equals("/home/me/repo", config.resolve_repository("./repo", "/home/me"))
    assert.equals("/home/me/../r", config.resolve_repository("../r", "/home/me"))
  end)
end)
