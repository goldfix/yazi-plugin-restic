local util = require(".util")

describe("util", function()
  it("trims whitespace", function() assert.equals("a b", util.trim("  a b \t\n")) end)

  it("computes parents", function()
    assert.equals("/a", util.parent("/a/b"))
    assert.equals("/", util.parent("/a"))
    assert.equals("/", util.parent("/"))
    assert.equals(".", util.parent("a"))
  end)

  it(
    "joins segments without duplicate slashes",
    function() assert.equals("/tmp/x/y", util.join("/tmp/", "/x", "y")) end
  )

  it("sanitizes names", function()
    assert.equals("my_host_.local", util.sanitize("my host/.local"))
    assert.equals("a_b", util.sanitize("a  //  b"))
    assert.equals("ok-1.2", util.sanitize("ok-1.2"))
  end)

  it("hashes deterministically to 8 hex digits", function()
    assert.equals(util.hash("repo"), util.hash("repo"))
    assert.not_equals(util.hash("repo"), util.hash("repo2"))
    assert.matches("^%x%x%x%x%x%x%x%x$", util.hash("anything"))
    assert.equals("e40c292c", util.hash("a")) -- known FNV-1a 32-bit vector
  end)

  it("extracts base names", function()
    assert.equals("c.txt", util.basename("/a/b/c.txt"))
    assert.equals("a", util.basename("a"))
  end)

  it("formats sizes", function()
    assert.equals("0B", util.human_size(0))
    assert.equals("1023B", util.human_size(1023))
    assert.equals("1.5K", util.human_size(1536))
    assert.equals("5.0M", util.human_size(5 * 1024 * 1024))
  end)

  it("tells whether a list contains a value", function()
    assert.is_true(util.contains({ "a", "/" }, "/"))
    assert.is_false(util.contains({ "a" }, "/"))
    assert.is_false(util.contains({}, "/"))
  end)

  it("formats durations", function()
    assert.equals("0s", util.duration(0))
    assert.equals("59s", util.duration(59))
    assert.equals("2m05s", util.duration(125))
    assert.equals("1h02m", util.duration(3725))
  end)
end)
