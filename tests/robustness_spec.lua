-- xyno-rust: failure modes found in review. A transient `cargo locate-project` failure is not cached as
-- "no workspace"; a trust prompt that errors or never answers does not stay open for ever; the state-file
-- lock is never released or reaped out from under a live owner.
-- xyno-os: linux,macos (child nvims, shell)
local H = require("xyno_rust_test.helpers")
local cargo = require("xyno_rust.cargo")
local statefile = require("xyno_rust.statefile")

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end
after_each(function()
  for i = #restores, 1, -1 do
    restores[i]()
  end
  restores = {}
end)

describe("cargo.locate_async negative caching", function()
  local function count_exec(result)
    local n = { n = 0 }
    stub(cargo, "exec", function(_, _, cb)
      n.n = n.n + 1
      vim.schedule(function()
        cb(vim.deepcopy(result))
      end)
    end)
    return n
  end
  local function locate(dir, stamp)
    local got, done
    cargo.locate_async(dir, stamp, function(r)
      got, done = r, true
    end)
    H.wait_for(function()
      return done
    end, 3000, "locate callback")
    return got
  end

  it("a timeout is not remembered as 'no workspace': the next ask runs cargo again", function()
    local dir = H.tmpdir()
    local n = count_exec({ code = 124, stdout = "", stderr = "timed out" })
    H.is_nil(locate(dir, "t1"))
    H.is_nil(cargo.located(dir, "t1"), "unknown, not false")
    H.is_nil(locate(dir, "t1"))
    H.eq(2, n.n)
  end)

  it("a spawn failure and an unrelated cargo error are not remembered either", function()
    local dir = H.tmpdir()
    local n = count_exec({ code = -1, stdout = "", stderr = "ENOENT" })
    locate(dir, "t2")
    locate(dir, "t2")
    H.eq(2, n.n)
    n = count_exec({ code = 101, stdout = "", stderr = "error: rustup could not choose a version of cargo to run" })
    locate(dir, "t2")
    locate(dir, "t2")
    H.eq(2, n.n)
  end)

  it("'could not find Cargo.toml' IS remembered (no new cargo run), but only for a short time", function()
    local dir = H.tmpdir()
    local n = count_exec({ code = 101, stdout = "", stderr = "error: could not find `Cargo.toml` in `/x` or any parent directory" })
    H.is_nil(locate(dir, "t3"))
    H.eq(false, cargo.located(dir, "t3"))
    H.is_nil(locate(dir, "t3"))
    H.eq(1, n.n, "the definitive answer is cached")
    stub(cargo.config, "locate_negative_ttl_ms", 0)
    vim.wait(5)
    H.is_nil(cargo.located(dir, "t3"), "expired")
    locate(dir, "t3")
    H.eq(2, n.n)
  end)

  it("a found root is cached", function()
    local dir = H.tmpdir()
    local n = count_exec({ code = 0, stdout = dir .. "/Cargo.toml\n", stderr = "" })
    H.eq(dir, locate(dir, "t4"))
    H.eq(dir, locate(dir, "t4"))
    H.eq(1, n.n)
  end)

  it("the blocking locate() does not wait again right after a transient failure", function()
    local dir = H.tmpdir()
    stub(cargo, "exec", function(_, _, cb)
      vim.defer_fn(function()
        cb({ code = 124, stdout = "", stderr = "timed out" })
      end, 400)
    end)
    local t = vim.uv.hrtime()
    H.is_nil(cargo.locate(dir, "t5"))
    H.ok((vim.uv.hrtime() - t) / 1e6 >= 350, "first call waits for cargo")
    t = vim.uv.hrtime()
    H.is_nil(cargo.locate(dir, "t5"))
    H.ok((vim.uv.hrtime() - t) / 1e6 < 100, "second call returns at once and retries in the background")
    H.wait_for(function()
      return cargo.pending() == 0
    end, 3000)
  end)
end)

describe("trust.ask", function()
  local trust
  before_each(function()
    H.fake_snacks()
    require("xyno_rust").setup()
    trust = require("xyno_rust.trust")
  end)

  it("a vim.ui.select that raises answers 'no' and does not leave the root stuck", function()
    local dir = H.tmpdir()
    local notes = {}
    stub(vim, "notify", function(m)
      notes[#notes + 1] = m
    end)
    stub(vim.ui, "select", function()
      error("select exploded")
    end)
    local got
    trust.ask(dir, "cargo run", function(ok)
      got = ok
    end)
    H.eq(false, got)
    -- not stuck: a working select is used for the next ask
    local asked = 0
    stub(vim.ui, "select", function(items, _, on_choice)
      asked = asked + 1
      on_choice(items[1])
    end)
    local got2
    trust.ask(dir, "cargo run", function(ok)
      got2 = ok
    end)
    H.eq(true, got2)
    H.eq(1, asked)
    H.match(table.concat(notes, "\n"), "select exploded", true)
  end)

  it("a vim.ui.select that never calls back is dropped after ask_timeout_ms; a late answer is ignored", function()
    local dir = H.tmpdir()
    stub(vim, "notify", function() end)
    stub(trust, "ask_timeout_ms", 80)
    local late
    stub(vim.ui, "select", function(_, _, on_choice)
      late = on_choice
    end)
    local first, second
    trust.ask(dir, "cargo run", function(ok)
      first = ok
    end)
    trust.ask(dir, "cargo test", function(ok) -- joins the same prompt
      second = ok
    end)
    H.wait_for(function()
      return first ~= nil
    end, 2000, "timeout")
    H.eq({ false, false }, { first, second })
    -- a new prompt works, and the old callback arriving now changes nothing
    local newer
    stub(vim.ui, "select", function(_, _, on_choice)
      newer = on_choice
    end)
    local third
    trust.ask(dir, "cargo run", function(ok)
      third = ok
    end)
    late({ "Trust this workspace", "trust" })
    H.is_nil(third, "the stale answer did not resolve the new prompt")
    newer({ "Do not run", "no" })
    H.eq(false, third)
  end)
end)

describe("statefile lock", function()
  it("the lock is only removed by its owner: a lock somebody else holds now survives our release", function()
    local dir = H.tmpdir()
    local file = dir .. "/s.json"
    statefile.update(file, function(all)
      -- our lock was reaped as 'stale' and another writer took the lock meanwhile
      os.remove(file .. ".lock")
      local f = assert(io.open(file .. ".lock", "w"))
      f:write("someone-else")
      f:close()
      all.k = 1
    end)
    local f = io.open(file .. ".lock")
    H.ok(f, "the other owner's lock was deleted by our release")
    H.eq("someone-else", f:read("*a"))
    f:close()
    H.eq(1, statefile.read(file).k)
  end)

  it("a waiter whose stat was out of date does not delete a live lock", function()
    local dir = H.tmpdir()
    local file = dir .. "/s.json"
    local f = assert(io.open(file .. ".lock", "w"))
    f:write("live-owner")
    f:close() -- fresh mtime
    local real_stat, first = vim.uv.fs_stat, true
    stub(vim.uv, "fs_stat", function(p, ...)
      local st = real_stat(p, ...)
      if first and st and p == file .. ".lock" then
        first = false
        st.mtime = { sec = os.time() - 60, nsec = 0 } -- the stale picture taken before the owner re-created it
      end
      return st
    end)
    stub(statefile, "lock_tries", 5)
    statefile.update(file, function(all)
      all.k = 2
    end)
    local g = io.open(file .. ".lock")
    H.ok(g, "live lock must survive")
    H.eq("live-owner", g:read("*a"))
    g:close()
    H.eq(2, statefile.read(file).k)
  end)

  it("a really stale lock (dead owner) is taken over and released", function()
    local dir = H.tmpdir()
    local file = dir .. "/s.json"
    local f = assert(io.open(file .. ".lock", "w"))
    f:write("dead-owner")
    f:close()
    vim.uv.fs_utime(file .. ".lock", os.time() - 60, os.time() - 60)
    statefile.update(file, function(all)
      all.k = 3
    end)
    H.eq(3, statefile.read(file).k)
    H.eq(0, vim.fn.filereadable(file .. ".lock"))
    H.eq({}, vim.fn.glob(file .. ".lock.*", true, true), "no reaper leftovers")
  end)

  it("six nvims updating different keys at once lose nothing", function()
    local dir = H.tmpdir()
    local file = dir .. "/s.json"
    local here = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
    local procs = {}
    for i = 1, 6 do
      local code = ([[vim.opt.rtp:prepend(%q); local s=require('xyno_rust.statefile'); for j=1,25 do s.update(%q, function(a) a['k%d_'..j]=j end) end]]):format(here, file, i)
      procs[i] = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "+lua " .. code, "+qa!" }, { text = true })
    end
    for _, p in ipairs(procs) do
      p:wait(60000)
    end
    H.eq(150, vim.tbl_count(statefile.read(file)))
    H.eq(0, vim.fn.filereadable(file .. ".lock"))
  end)
end)
