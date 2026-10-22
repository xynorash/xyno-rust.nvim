-- Spec runner:  nvim -l tests/run.lua [spec file ...]
-- Without arguments every tests/*_spec.lua runs, each in its own headless nvim
-- (child processes of this one). With a file, that spec runs in this process.
-- Output: one line per test (ok / FAIL / SKIP) and a final
--   RESULT passed=N failed=N skipped=N
-- line. Exit code is 0 only without failures.
local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local repo = vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(here, ":p")))
local spec = arg and arg[1]

vim.o.swapfile = false
vim.opt.rtp:prepend(repo)
if vim.env.XYNO_TEST_RTP and vim.env.XYNO_TEST_RTP ~= "" then
  vim.opt.rtp:append(vim.env.XYNO_TEST_RTP) -- e.g. a directory holding parser/rust.so
end

if not spec then
  local files = vim.fn.glob(repo .. "/tests/*_spec.lua", true, true)
  table.sort(files)
  local total = { passed = 0, failed = 0, skipped = 0 }
  for _, f in ipairs(files) do
    local r = vim.system({ vim.v.progpath, "-l", repo .. "/tests/run.lua", f }, { text = true }):wait(600000)
    io.stdout:write(r.stdout or "", r.stderr or "")
    for k in pairs(total) do
      total[k] = total[k] + (tonumber((r.stdout or ""):match("RESULT[^\n]-" .. k .. "=(%d+)")) or 0)
    end
    if r.code ~= 0 and not (r.stdout or ""):find("RESULT", 1, true) then
      total.failed = total.failed + 1
    end
  end
  io.stdout:write(("RESULT passed=%d failed=%d skipped=%d\n"):format(total.passed, total.failed, total.skipped))
  os.exit(total.failed > 0 and 1 or 0)
end

package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
for _, name in ipairs({ "helpers", "harness" }) do
  package.preload["xyno_rust_test." .. name] = function()
    return dofile(repo .. "/tests/" .. name .. ".lua")
  end
end

local function finish(n)
  io.stdout:write(("RESULT passed=%d failed=%d skipped=%d\n"):format(n.passed, n.failed, n.skipped))
  io.stdout:flush()
  local helpers = package.loaded["xyno_rust_test.helpers"]
  if helpers then
    pcall(helpers.cleanup)
  end
  pcall(vim.cmd, "messages clear")
  vim.cmd(n.failed > 0 and "cquit 1" or "qa!")
end

--- A spec may declare where it can run in a header line (first 15 lines):
---   -- xyno-os: linux,macos (why it cannot run elsewhere)
local function os_skip_reason()
  local current = vim.fn.has("win32") == 1 and "windows" or vim.fn.has("mac") == 1 and "macos" or "linux"
  local n = 0
  for line in io.lines(spec) do
    n = n + 1
    local list, why = line:match("^%-%- xyno%-os: *([%a,]+) *(.*)$")
    if list then
      for os_name in list:gmatch("[^,]+") do
        if os_name == current then
          return nil
        end
      end
      why = why:gsub("^%((.*)%)$", "%1")
      return ("needs %s, this is %s%s"):format(list:gsub(",", " or "), current, why ~= "" and (": " .. why) or "")
    end
    if n >= 15 then
      break
    end
  end
end

local harness = require("xyno_rust_test.harness")
harness.install()
local why = os_skip_reason()
if why then
  io.stdout:write(("SKIP %s (%s)\n"):format(vim.fs.basename(spec), why))
  return finish({ passed = 0, failed = 0, skipped = 1 })
end
local ok, err = xpcall(dofile, debug.traceback, spec)
if not ok then
  if harness.is_skip(err) then
    io.stdout:write(("SKIP %s (%s)\n"):format(vim.fs.basename(spec), err.reason))
    return finish({ passed = 0, failed = 0, skipped = 1 })
  end
  io.stdout:write("FAIL loading " .. spec .. "\n")
  for l in tostring(err):gmatch("[^\n]+") do
    io.stdout:write("       " .. l .. "\n")
  end
  return finish({ passed = 0, failed = 1, skipped = 0 })
end
finish(harness.run())
