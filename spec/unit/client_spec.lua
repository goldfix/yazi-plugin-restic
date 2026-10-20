local Client = require(".client")

local function client() return Client.new { exec = "restic", repository = "/srv/repo", password = "pw" } end

describe("Client:command", function()
  it("passes the repository and password and never puts the password on the command line", function()
    local command = client():command { "snapshots" }
    assert.same({ "-r", "/srv/repo", "--no-lock", "snapshots" }, command.args)
    assert.equals("pw", command.envs.RESTIC_PASSWORD)
    for _, arg in ipairs(command.args) do
      assert.not_equals("pw", arg)
    end
  end)

  it("clears environment variables that would override or conflict with them", function()
    local envs = client():command({ "snapshots" }).envs
    assert.equals("", envs.RESTIC_PASSWORD_FILE)
    assert.equals("", envs.RESTIC_PASSWORD_COMMAND)
    assert.equals("", envs.RESTIC_REPOSITORY_FILE)
  end)
end)

describe("ssh batch mode", function()
  local function args_for(repository, batch)
    return Client.new({ exec = "restic", repository = repository, password = "pw", ssh_batch_mode = batch })
      :command({ "snapshots" }).args
  end

  it("is added for sftp repositories by default, before the subcommand", function()
    assert.same(
      { "-r", "sftp:u@h:/srv/r", "--no-lock", "-o", "sftp.args=-o BatchMode=yes", "snapshots" },
      args_for("sftp:u@h:/srv/r")
    )
    assert.same(
      { "-r", "sftp://u@h:2222//r", "--no-lock", "-o", "sftp.args=-o BatchMode=yes", "snapshots" },
      args_for("sftp://u@h:2222//r", true)
    )
  end)

  it("can be disabled, and never applies to other backends", function()
    assert.same({ "-r", "sftp:u@h:/srv/r", "--no-lock", "snapshots" }, args_for("sftp:u@h:/srv/r", false))
    for _, repo in ipairs { "/srv/r", "s3:host/bucket", "rest:https://h/", "rclone:remote:sftp:x" } do
      assert.same({ "-r", repo, "--no-lock", "snapshots" }, args_for(repo), repo)
    end
  end)

  it("puts what ssh said first and adds a hint", function()
    local stderr = "subprocess ssh: Host key verification failed.\n"
      .. '{"message_type":"exit_error","code":1,"message":"Fatal: unable to start the sftp session"}\n'
    local sftp = Client.new { exec = "restic", repository = "sftp:u@h:/r", password = "pw" }
    local err = sftp:failure(1, stderr)
    assert.matches("^ssh: Host key verification failed%.", err)
    assert.matches("ssh%-agent", err)
    assert.matches("ssh_batch_mode = no", err)

    local manual =
      Client.new { exec = "restic", repository = "sftp:u@h:/r", password = "pw", ssh_batch_mode = false }
    assert.equals("ssh: Host key verification failed.", manual:failure(1, stderr))
  end)
end)

describe("Client:failure", function()
  it("extracts the message of a JSON exit_error", function()
    local stderr =
      'warning: something\n{"message_type":"exit_error","code":10,"message":"Fatal: repository does not exist"}\n'
    assert.equals("Fatal: repository does not exist", client():failure(10, stderr))
  end)

  it(
    "keeps plain text errors",
    function() assert.equals("Fatal: boom", client():failure(1, "Fatal: boom\n")) end
  )

  it("recognises a wrong password by exit code and by message (restic < 0.17 exits with 1)", function()
    assert.equals("wrong password", client():failure(12, ""))
    assert.equals("wrong password", client():failure(1, "Fatal: wrong password or no key found\n"))
  end)

  it(
    "falls back to the exit code",
    function() assert.equals("restic exited with code 3", client():failure(3, "  \n")) end
  )
end)

describe("Client.escape_pattern", function()
  it(
    "escapes restic pattern syntax",
    function() assert.equals("/a/b\\[1]\\*\\?\\\\", Client.escape_pattern("/a/b[1]*?\\")) end
  )
end)
