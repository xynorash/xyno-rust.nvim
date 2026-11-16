-- xyno_rust.lsp_status.explain: "Failed to load workspaces" gets cargo's own reason. Real cargo, real manifests.
-- xyno-os: linux,macos (cargo)
local H = require("xyno_rust_test.helpers")
local status = require("xyno_rust.lsp_status")

local function crate(manifest_tail)
  local dir = H.tmpdir()
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile({ "fn main() {}" }, dir .. "/src/main.rs")
  vim.fn.writefile(
    vim.split('[package]\nname = "t"\nversion = "0.1.0"\nedition = "2021"\n' .. manifest_tail, "\n"),
    dir .. "/Cargo.toml"
  )
  return dir
end

local function explain(dir, message)
  local notes = {}
  local real = vim.notify
  vim.notify = function(msg, level, opts)
    notes[#notes + 1] = { msg = msg, level = level, title = opts and opts.title }
  end
  status.explain(dir, message)
  local ok, err = pcall(H.wait_for, function()
    return #notes > 0
  end, 30000, "no explanation")
  vim.notify = real
  assert(ok, err)
  return notes
end

describe("explain", function()
  it("names the TOML parse error of a broken Cargo.toml and says how it recovers", function()
    if vim.fn.executable("cargo") ~= 1 then
      return skip("cargo is not installed")
    end
    local notes = explain(crate("[dependencies\nfoo = 1\n"), "Failed to load workspaces.")
    H.eq(1, #notes)
    H.eq(vim.log.levels.ERROR, notes[1].level)
    H.has(notes[1].msg, "cargo says")
    H.has(notes[1].msg, "unclosed table")
    H.has(notes[1].msg, "at Cargo.toml:")
    H.has(notes[1].msg, "save")
    H.not_ok(notes[1].msg:find("stack traceback", 1, true))
  end)

  it("names a bad feature", function()
    if vim.fn.executable("cargo") ~= 1 then
      return skip("cargo is not installed")
    end
    local notes = explain(crate('[features]\na = ["nope"]\n'), "Failed to load workspaces.")
    H.has(notes[1].msg, "nope")
  end)

  it("manifests that cargo reads fine: a warning pointing at the log, not an invented reason", function()
    if vim.fn.executable("cargo") ~= 1 then
      return skip("cargo is not installed")
    end
    local notes = explain(crate(""), "Failed to load workspaces.")
    H.eq(vim.log.levels.WARN, notes[1].level)
    H.has(notes[1].msg, "RustLsp logFile")
  end)

  it("reports a state of the manifest once", function()
    if vim.fn.executable("cargo") ~= 1 then
      return skip("cargo is not installed")
    end
    local dir = crate("[dependencies\n")
    explain(dir, "m")
    local again = {}
    local real = vim.notify
    vim.notify = function(m)
      again[#again + 1] = m
    end
    status.explain(dir, "m")
    vim.wait(800)
    vim.notify = real
    H.eq(0, #again)
  end)
end)
