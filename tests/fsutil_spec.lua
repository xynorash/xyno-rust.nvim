-- xyno_rust.fsutil: rename over an existing file and slash().
local H = require("xyno_rust_test.helpers")
local fs = require("xyno_rust.fsutil")

describe("fsutil.rename", function()
  it("moves a file over an existing one", function()
    local dir = H.tmpdir()
    vim.fn.writefile({ "new" }, dir .. "/a.tmp")
    vim.fn.writefile({ "old" }, dir .. "/a")
    H.ok(fs.rename(dir .. "/a.tmp", dir .. "/a"))
    H.eq({ "new" }, vim.fn.readfile(dir .. "/a"))
    H.eq(0, vim.fn.filereadable(dir .. "/a.tmp"))
  end)

  it("returns nil + error for a missing source (and does not retry off Windows)", function()
    local dir = H.tmpdir()
    local ok, err = fs.rename(dir .. "/nope", dir .. "/b")
    H.is_nil(ok)
    H.match(err, "ENOENT", true)
  end)
end)

describe("fsutil.slash", function()
  it("passes nil and plain paths through", function()
    H.is_nil(fs.slash(nil))
    H.eq("/a/b", fs.slash("/a/b"))
  end)

  it("turns backslashes into slashes on Windows only", function()
    if vim.fn.has("win32") == 1 then
      H.eq("C:/a/b", fs.slash("C:\\a\\b"))
    else
      H.eq("a\\b", fs.slash("a\\b"))
    end
  end)
end)
