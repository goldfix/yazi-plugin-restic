local Client = require(".client")

--- restic must really hand `BatchMode=yes` to ssh. A fake `ssh` placed first on PATH records its arguments
--- and fails like a real one meeting an unknown host key.
describe("sftp repositories (fake ssh)", function()
  local dir

  setup(function()
    dir = os.tmpname()
    os.remove(dir)
    os.execute(string.format("mkdir -p '%s'", dir))
    local script = io.open(dir .. "/ssh", "w")
    script:write('#!/bin/sh\nprintf "%s\\n" "$@" > "$(dirname "$0")/args"\n')
    script:write('echo "Host key verification failed." >&2\nexit 255\n')
    script:close()
    os.execute(string.format("chmod +x '%s/ssh'", dir))
  end)

  teardown(function() os.execute(string.format("rm -rf '%s'", dir)) end)

  --- A client whose restic sees the fake ssh first on PATH.
  local function client(batch)
    local c = Client.new {
      exec = "restic",
      repository = "sftp:bob@example.org:/srv/repo",
      password = "x",
      ssh_batch_mode = batch,
    }
    local command = c.command
    function c.command(self, args) return command(self, args):env("PATH", dir .. ":" .. os.getenv("PATH")) end
    return c
  end

  local function ssh_args()
    local file = assert(io.open(dir .. "/args"))
    local text = file:read("a")
    file:close()
    return text
  end

  it("passes BatchMode=yes to ssh and reports ssh's own error with a hint", function()
    local snaps, err = client():snapshots()
    assert.is_nil(snaps)
    assert.matches("BatchMode=yes", ssh_args())
    assert.matches("^ssh: Host key verification failed%.", err)
    assert.matches("ssh_batch_mode = no", err)
  end)

  it("leaves ssh alone when batch mode is disabled", function()
    local _, err = client(false):snapshots()
    assert.not_matches("BatchMode", ssh_args())
    assert.equals("ssh: Host key verification failed.", err)
  end)
end)
