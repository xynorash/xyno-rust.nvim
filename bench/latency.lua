-- Latency of the commands that used to block the main thread, old code against new code.
--
--   nvim -l bench/latency.lua <plugin-dir> <workspace> [runs] [cargo-delay-seconds]
--
-- Every measurement runs in a fresh headless nvim (cold caches, a state directory of its own) whose
-- main loop is fed one <Esc> every 4 ms from outside, through its RPC socket, while the operation runs.
--   total  : ms from the call to the result (the picker being handed its items)
--   input  : the longest gap between two of those keys being processed (vim.on_key). A call that waits
--            for a process (vim.system():wait()) or a loop that parses files without yielding keeps the
--            editor from reading input, and shows up here as one large gap; an editor that keeps up
--            shows about 4-10 ms.
-- Operations: root (cold cargo locate-project), targets (:RustTargets), routes (:RustRoutes) and, where
-- the plugin has the async layer, root_async. `cargo-delay-seconds` puts a `cargo` shim in front of PATH
-- that sleeps first (a cold registry, a toolchain download, a network share).
-- <plugin-dir> may be any checkout of xyno-rust.nvim (the old one for the "before" column).
local here = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))

-- ---------------------------------------------------------------- child (inside the measured nvim)
if vim.env.XYNO_BENCH_CHILD then
  local op, plugin, ws, out =
    vim.env.XYNO_BENCH_OP, vim.env.XYNO_BENCH_PLUGIN, vim.env.XYNO_BENCH_WS, vim.env.XYNO_BENCH_OUT
  vim.opt.rtp:prepend(plugin)
  package.path = plugin .. "/lua/?.lua;" .. plugin .. "/lua/?/init.lua;" .. package.path
  local picked
  _G.Snacks = {
    picker = function(opts)
      picked = opts
    end,
    terminal = { get = function() end, open = function() end },
  }
  -- (a workspace without routes ends in a notification instead of a picker)
  vim.notify = function(msg)
    if type(msg) == "string" and msg:find("no routes found", 1, true) then
      picked = { items = {} }
    end
  end
  local keys = {}
  vim.on_key(function()
    keys[#keys + 1] = vim.uv.hrtime()
  end)
  local rc = require("xyno_rust.rust_context")
  require("xyno_rust.rust_tasks").setup({})
  require("xyno_rust.rust_routes").setup({})
  vim.cmd.cd(vim.fn.fnameescape(ws))
  local file
  for name, t in vim.fs.dir(ws, { depth = 6 }) do
    if t == "file" and name:match("%.rs$") and not name:match("^target/") then
      file = ws .. "/" .. name
      break
    end
  end
  vim.cmd.edit(vim.fn.fnameescape(file))

  -- The operation is started from a timer callback and the result is awaited with the editor's own
  -- loop (a timer that polls), NOT with vim.wait: vim.wait would process events and hide the very
  -- stall that blocking code causes.
  vim.defer_fn(function()
    local t0 = vim.uv.hrtime()
    local result
    local function finish()
      local t1 = vim.uv.hrtime()
      vim.defer_fn(function()
        local lo, hi = t0 - 20e6, t1 + 20e6
        local worst, prev = 0, nil
        for _, k in ipairs(keys) do
          if k >= lo and k <= hi then
            if prev then
              worst = math.max(worst, (k - prev) / 1e6)
            end
            prev = k
          end
        end
        local f = assert(io.open(out, "w"))
        f:write(vim.json.encode({
          total = (t1 - t0) / 1e6,
          input = worst,
          result = type(result) == "string" and 1 or result,
          keys = #keys,
        }))
        f:close()
        vim.cmd("qa!")
      end, 60)
    end
    local function poll(ready)
      local timer = vim.uv.new_timer()
      timer:start(
        1,
        1,
        vim.schedule_wrap(function()
          if ready() then
            timer:stop()
            timer:close()
            finish()
          end
        end)
      )
    end
    if op == "root" then
      result = rc.root(file)
      finish()
    elseif op == "root_async" then
      rc.root_async(file, function(r)
        result = r
      end)
      poll(function()
        return result ~= nil
      end)
    elseif op == "targets" then
      require("xyno_rust.rust_tasks").targets()
      poll(function()
        result = picked and #picked.items
        return picked ~= nil
      end)
    elseif op == "routes" then
      require("xyno_rust.rust_routes").pick()
      poll(function()
        result = picked and #picked.items
        return picked ~= nil
      end)
    end
  end, 400)
  return
end

-- ---------------------------------------------------------------------------------- driver
local args = { unpack(arg) }
local plugin, ws = args[1], args[2]
local runs = tonumber(args[3]) or 5
local delay = tonumber(args[4])
assert(plugin and ws, "usage: nvim -l bench/latency.lua <plugin-dir> <workspace> [runs] [cargo-delay-seconds]")
plugin, ws = vim.fn.fnamemodify(plugin, ":p"):gsub("/$", ""), vim.fn.fnamemodify(ws, ":p"):gsub("/$", "")

local env = {}
if delay then
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local real = vim.fn.exepath("cargo")
  local f = assert(io.open(dir .. "/cargo", "w"))
  f:write(('#!/bin/sh\nsleep %s\nexec %s "$@"\n'):format(delay, real))
  f:close()
  vim.uv.fs_chmod(dir .. "/cargo", 493)
  env.PATH = dir .. ":" .. vim.env.PATH
end

--- Send <Esc> to the nvim listening on `sock` every 4 ms until `stop()` is true.
local function feed(sock, stop)
  local pipe, connected
  for _ = 1, 200 do
    pipe = vim.uv.new_pipe(false)
    connected = nil
    pipe:connect(sock, function(err)
      connected = err == nil and "ok" or "err"
    end)
    vim.wait(100, function()
      return connected ~= nil
    end, 2)
    if connected == "ok" then
      break
    end
    pipe:close()
    vim.wait(20, function()
      return false
    end, 5)
  end
  if connected ~= "ok" then
    return
  end
  local msg = vim.mpack.encode({ 2, "nvim_input", { "<Esc>" } })
  local timer = vim.uv.new_timer()
  timer:start(0, 4, function()
    if not pipe:is_closing() then
      pipe:write(msg)
    end
  end)
  vim.wait(180000, stop, 5)
  timer:stop()
  timer:close()
  if not pipe:is_closing() then
    pipe:close()
  end
end

local function measure(op)
  local state = vim.fn.tempname()
  vim.fn.mkdir(state, "p")
  local sock = state .. "/sock"
  local out = state .. "/out.json"
  local e = vim.tbl_extend("force", env, {
    XDG_STATE_HOME = state,
    XYNO_BENCH_CHILD = "1",
    XYNO_BENCH_OP = op,
    XYNO_BENCH_PLUGIN = plugin,
    XYNO_BENCH_WS = ws,
    XYNO_BENCH_OUT = out,
  })
  local done = false
  local child = vim.system({
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "-i",
    "NONE",
    "--listen",
    sock,
    "-c",
    "luafile " .. here .. "/latency.lua",
  }, { env = e, text = true }, function()
    done = true
  end)
  feed(sock, function()
    return done
  end)
  child:wait(10000)
  local f = io.open(out)
  local d = f and vim.json.decode(f:read("*a"))
  if f then
    f:close()
  end
  vim.fn.delete(state, "rf")
  return d
end

local ops = { "root", "targets", "routes" }
if vim.uv.fs_stat(plugin .. "/lua/xyno_rust/cargo.lua") then
  table.insert(ops, 2, "root_async")
end
local function median(t)
  table.sort(t)
  return t[math.ceil(#t / 2)]
end
for _, op in ipairs(ops) do
  local totals, inputs, res, nkeys = {}, {}, nil, 0
  for _ = 1, runs do
    local d = measure(op)
    if d then
      totals[#totals + 1], inputs[#inputs + 1], res, nkeys = d.total, d.input, d.result, d.keys
    else
      io.stderr:write("run failed: " .. op .. "\n")
    end
  end
  if #totals > 0 then
    io.stdout:write(
      ("%-11s total %8.1f ms   input stall %8.1f ms   (median of %d, items=%s, %d keys seen)\n"):format(
        op,
        median(totals),
        median(inputs),
        #totals,
        tostring(res),
        nkeys
      )
    )
  end
end
vim.cmd("qa!")
