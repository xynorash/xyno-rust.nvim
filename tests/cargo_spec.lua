-- xyno_rust.cargo: the asynchronous cargo / rustup layer. Slow cargo is a shim script in front
-- of PATH that sleeps and then runs the real one, so "does the main thread stall" is measured, not assumed.
-- xyno-os: linux,macos (the cargo shim is a shell script)
local H = require("xyno_rust_test.helpers")
local cargo = require("xyno_rust.cargo")
local rc = require("xyno_rust.rust_context")

local old_path = vim.env.PATH
local function restore_path()
  vim.env.PATH = old_path
end

--- PATH with a `cargo` (and `rustup`) in front that sleeps `secs` first; every call is logged to the returned file.
local function slow_tools(secs)
  local dir = H.tmpdir()
  local log = dir .. "/calls.log"
  local real_cargo, real_rustup = vim.fn.exepath("cargo"), vim.fn.exepath("rustup")
  for name, real in pairs({ cargo = real_cargo, rustup = real_rustup }) do
    local f = assert(io.open(dir .. "/" .. name, "w"))
    f:write(('#!/bin/sh\necho "%s $*" >> %s\nsleep %s\nexec %s "$@"\n'):format(name, log, secs, real))
    f:close()
    vim.uv.fs_chmod(dir .. "/" .. name, 493)
  end
  vim.env.PATH = dir .. ":" .. old_path
  return log
end

local function calls(log)
  local ok, lines = pcall(vim.fn.readfile, log)
  return ok and lines or {}
end

--- Longest gap between two ticks of a 5 ms timer while `body` runs (a stalled main thread shows as a big gap).
local function max_stall(body)
  local last, worst = vim.uv.hrtime(), 0
  local t = vim.uv.new_timer()
  t:start(5, 5, function()
    local now = vim.uv.hrtime()
    worst = math.max(worst, (now - last) / 1e6)
    last = now
  end)
  body()
  t:stop()
  t:close()
  return worst
end

local cleanups = {}
local function on_cleanup(fn)
  cleanups[#cleanups + 1] = fn
end

before_each(function()
  cargo.reset_caches()
end)
after_each(function()
  restore_path()
  for i = #cleanups, 1, -1 do
    pcall(cleanups[i])
  end
  cleanups = {}
end)

describe("cargo.metadata_async", function()
  before_each(function()
    H.need_rust()
  end)

  it("calls back later, with the decoded `cargo metadata --no-deps` and never blocks the main thread", function()
    local log = slow_tools(1)
    local dir = H.fixture("basic")
    local meta, called_inside
    local stall = max_stall(function()
      local inside = true
      cargo.metadata_async(dir, function(m)
        called_inside = inside
        meta = m
      end)
      inside = false
      H.wait_for(function()
        return meta
      end, 10000, "metadata")
    end)
    H.eq(false, called_inside, "the callback never runs inside the call")
    H.eq("basic", meta.packages[1].name)
    H.eq({ "cargo metadata --format-version 1 --no-deps" }, calls(log))
    H.ok(stall < 250, ("main thread stalled %.0f ms while cargo slept 1000 ms"):format(stall))
  end)

  it("joins a request that is already running: ten askers, one cargo process", function()
    local log = slow_tools(0.5)
    local dir = H.fixture("basic")
    local got = 0
    for _ = 1, 10 do
      cargo.metadata_async(dir, function(m)
        got = m and got + 1 or got
      end)
    end
    H.wait_for(function()
      return got == 10
    end, 10000, "ten callbacks")
    H.eq(1, #calls(log))
  end)

  it("is cached until a manifest changes, and refresh bypasses the cache", function()
    local log = slow_tools(0)
    local dir = H.fixture("basic")
    local function ask(opts)
      local m
      cargo.metadata_async(dir, function(x)
        m = x
      end, opts)
      H.wait_for(function()
        return m
      end, 10000, "metadata")
      return m
    end
    ask()
    ask()
    H.eq(1, #calls(log), "second call from the cache")
    ask({ refresh = true })
    H.eq(2, #calls(log))
    vim.uv.sleep(20)
    local f = assert(io.open(dir .. "/Cargo.toml", "a"))
    f:write("\n# touched\n")
    f:close()
    ask()
    H.eq(3, #calls(log), "a changed Cargo.toml invalidates")
  end)

  it("reports cargo's own error text and does not cache a failure", function()
    local dir = H.tmpdir()
    vim.fn.writefile({ "[package]", "this is not toml" }, dir .. "/Cargo.toml")
    local err, done
    cargo.metadata_async(dir, function(m, e)
      err, done = e, true
      H.is_nil(m)
    end)
    H.wait_for(function()
      return done
    end, 10000, "failure")
    H.match(err, "Cargo.toml", true)
    H.eq(0, cargo.pending())
  end)

  it("kills cargo after the configured timeout and says so", function()
    slow_tools(30)
    local dir = H.fixture("basic")
    local old = cargo.config.metadata_timeout_ms
    on_cleanup(function()
      cargo.config.metadata_timeout_ms = old
    end)
    cargo.config.metadata_timeout_ms = 300
    local err, done
    local t0 = vim.uv.hrtime()
    cargo.metadata_async(dir, function(_, e)
      err, done = e, true
    end)
    H.wait_for(function()
      return done
    end, 10000, "timeout")
    H.ok((vim.uv.hrtime() - t0) / 1e9 < 5, "returned long before the 30 s sleep")
    H.match(err, "timed out", true)
  end)

  it(
    "the synchronous wrapper still answers (callers like xyno-crates need it) and pumps events while it waits",
    function()
      slow_tools(0.3)
      local dir = H.fixture("basic")
      local ticks = 0
      local t = vim.uv.new_timer()
      t:start(
        10,
        10,
        vim.schedule_wrap(function()
          ticks = ticks + 1
        end)
      )
      local meta = cargo.metadata(dir)
      t:stop()
      t:close()
      H.eq("basic", meta.packages[1].name)
      H.ok(ticks > 5, "scheduled work kept running during the wait: " .. ticks)
    end
  )
end)

describe("rust_context.root: cargo's answer without freezing the editor", function()
  before_each(function()
    H.need_rust()
  end)

  it("root_async answers for an excluded crate like the synchronous root does", function()
    local ws = H.fixture("workspace")
    local want = rc.root(ws .. "/app/src/main.rs")
    cargo.reset_caches()
    local got
    rc.root_async(ws .. "/app/src/main.rs", function(r)
      got = r
    end)
    H.wait_for(function()
      return got
    end, 5000, "root")
    H.eq(want, got)
  end)

  it("never holds the main thread while cargo is slow (root_async)", function()
    slow_tools(1)
    local ws = H.fixture("workspace")
    local got
    local stall = max_stall(function()
      rc.root_async(ws .. "/app/src/main.rs", function(r)
        got = r
      end)
      H.wait_for(function()
        return got
      end, 10000, "root")
    end)
    H.ok(stall < 250, ("stalled %.0f ms"):format(stall))
  end)

  it(
    "root(path, { nowait = true }) returns at once from the file system and fills the cache for the next call",
    function()
      local log = slow_tools(0.5)
      local ws = H.fixture("workspace")
      local t0 = vim.uv.hrtime()
      local first = rc.root(ws .. "/app/src/main.rs", { nowait = true })
      H.ok((vim.uv.hrtime() - t0) / 1e6 < 200, "did not wait for the 500 ms cargo")
      H.eq(ws, first)
      H.wait_for(function()
        return #calls(log) >= 1 and cargo.pending() == 0
      end, 10000, "background locate")
      t0 = vim.uv.hrtime()
      H.eq(ws, rc.root(ws .. "/app/src/main.rs"))
      H.ok((vim.uv.hrtime() - t0) / 1e6 < 100, "the warm synchronous root does not run cargo again")
      H.eq(1, #calls(log))
    end
  )

  it("a cold synchronous root waits at most wait_ms for cargo and then falls back to the file system", function()
    slow_tools(30)
    local ws = H.fixture("workspace")
    local old = cargo.config.wait_ms
    on_cleanup(function()
      cargo.config.wait_ms = old
    end)
    cargo.config.wait_ms = 200
    local t0 = vim.uv.hrtime()
    local r = rc.root(ws .. "/app/src/main.rs")
    local ms = (vim.uv.hrtime() - t0) / 1e6
    H.eq(ws, r)
    H.ok(ms < 1500, ("waited %.0f ms"):format(ms))
  end)

  it("warm(): entering a Rust buffer asks cargo in the background", function()
    local log = slow_tools(0)
    local ws = H.fixture("workspace")
    rc.warm()
    vim.cmd.edit(vim.fn.fnameescape(ws .. "/app/src/main.rs"))
    H.wait_for(function()
      return #calls(log) >= 1
    end, 5000, "locate-project from the autocmd")
    vim.cmd("silent! %bwipeout!")
  end)
end)

describe("cargo.installed_targets_async", function()
  before_each(function()
    if vim.fn.executable("rustup") ~= 1 then
      require("xyno_rust_test.harness").skip("rustup is not installed")
    end
  end)

  it("is asynchronous, shared between askers and cached", function()
    local log = slow_tools(0.3)
    local n = 0
    local list
    for _ = 1, 3 do
      cargo.installed_targets_async(function(l)
        n, list = n + 1, l
      end)
    end
    H.wait_for(function()
      return n == 3
    end, 10000, "rustup")
    H.ok(#list >= 1, "at least the host target is installed")
    H.eq(1, #calls(log))
    local again
    cargo.installed_targets_async(function(l)
      again = l
    end)
    H.wait_for(function()
      return again
    end, 2000, "cached")
    H.eq(1, #calls(log), "second request came from the cache")
    H.eq(list, again)
  end)
end)
