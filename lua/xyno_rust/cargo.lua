-- The one place that runs short cargo / rustup queries for the plugin and
-- keeps the answers: `cargo metadata --no-deps`, `cargo locate-project
-- --workspace` and `rustup target list --installed`.
--
--   * Every query is asynchronous (vim.system with a callback), has a timeout
--     (the process is killed when it passes), is cached, and a second request
--     for the same thing while one is running joins it instead of starting a
--     second process.
--   * The synchronous functions (`metadata`, `locate`) are wrappers around the
--     async ones for callers that cannot be turned into callbacks (the other
--     xyno plugins call `rust_context.root()`). They pump the event loop with
--     vim.wait, give up after `wait_ms`, and answer from the cache when it is
--     warm - so they only wait on the first, cold call.
--
-- Cargo metadata of a workspace is read with --no-deps: it does not build,
-- does not run build.rs or proc macros and does not resolve (so no network);
-- reading it is allowed in an untrusted workspace (see trust.lua and the
-- README for what was checked).
local M = {}

M.config = {
  metadata_timeout_ms = 30000, -- was an unconditional blocking wait of the same length
  locate_timeout_ms = 5000,
  targets_timeout_ms = 10000,
  targets_ttl_ms = 60000, -- the installed rustup targets change when the user runs `rustup target add`
  wait_ms = 2000, -- the longest a synchronous wrapper blocks (cold cache only)
}

local function now_ms()
  return vim.uv.hrtime() / 1e6
end

local function mtime(path)
  local st = path and vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

--- Run argv asynchronously: cb({ code, stdout, stderr }) on the main loop.
--- A spawn failure (no such executable) is reported as code -1. Returns the
--- vim.SystemObj (or nil after a spawn failure).
local running = 0

function M.exec(argv, opts, cb)
  opts = opts or {}
  running = running + 1
  local finished = false
  local timer
  local obj
  local function finish(r)
    if finished then
      return
    end
    finished = true
    running = running - 1
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
    cb({ code = r.code, stdout = r.stdout or "", stderr = r.stderr or "", signal = r.signal })
  end
  local ok, res = pcall(vim.system, argv, { text = true, cwd = opts.cwd, timeout = opts.timeout }, vim.schedule_wrap(finish))
  if not ok then
    vim.schedule(function()
      finish({ code = -1, stderr = tostring(res) })
    end)
    return nil
  end
  obj = res
  if opts.timeout then
    -- vim.system's own timeout sends SIGTERM and then waits for the pipes to close: a rustup proxy that
    -- left the real cargo running (holding the pipes) would keep the callback away for ever.
    timer = vim.uv.new_timer()
    timer:start(opts.timeout + 1000, 0, vim.schedule_wrap(function()
      if obj and obj.kill then
        pcall(obj.kill, obj, 9)
      end
      finish({ code = 124, stderr = "timed out" })
    end))
  end
  return obj
end

--- Run `cb` once for everybody who asked for `key` while `start` is running.
--- start(done) must call done(...) exactly once; every waiting cb gets the same arguments.
local inflight = {}
local function join(key, cb, start)
  local waiting = inflight[key]
  if waiting then
    waiting[#waiting + 1] = cb
    return
  end
  waiting = { cb }
  inflight[key] = waiting
  start(function(...)
    inflight[key] = nil
    for _, f in ipairs(waiting) do
      f(...)
    end
  end)
end

--- Number of processes currently running through exec() (for the health check and the specs).
function M.pending()
  return running
end

--- Block (pumping events) until `done()` is true or `ms` pass.
local function block(done, ms)
  return vim.wait(ms or M.config.wait_ms, done, 2)
end

local function failure(r, what)
  if r.code == 124 or r.signal == 15 or r.signal == 9 then
    return what .. " timed out"
  end
  local err = vim.trim(r.stderr or "")
  return err ~= "" and err or (what .. " exited " .. tostring(r.code))
end

-- --------------------------------------------------------------- metadata

local meta_cache = {} -- root -> { stamp, meta }

local function meta_stamp(root, meta)
  local parts = { mtime(root .. "/Cargo.toml"), mtime(root .. "/Cargo.lock") }
  for _, p in ipairs(meta and meta.packages or {}) do
    if p.manifest_path then
      parts[#parts + 1] = p.manifest_path .. "=" .. mtime(p.manifest_path)
    end
  end
  return table.concat(parts, "|")
end

--- Decoded `cargo metadata --no-deps` of the workspace at `root`, cached until
--- a manifest or the lock file changes. cb(meta) or cb(nil, err); cb always
--- runs on a later loop iteration (never inside this call).
---@param opts? { refresh?: boolean }
function M.metadata_async(root, cb, opts)
  opts = opts or {}
  local hit = meta_cache[root]
  if hit and not opts.refresh and hit.stamp == meta_stamp(root, hit.meta) then
    return vim.schedule(function()
      cb(hit.meta)
    end)
  end
  join("metadata\0" .. root, cb, function(done)
    M.exec({ "cargo", "metadata", "--format-version", "1", "--no-deps" }, { cwd = root, timeout = M.config.metadata_timeout_ms }, function(r)
      if r.code ~= 0 then
        return done(nil, failure(r, "cargo metadata"))
      end
      local ok, meta = pcall(vim.json.decode, r.stdout)
      if not ok or type(meta) ~= "table" then
        return done(nil, "cargo metadata printed no JSON")
      end
      meta_cache[root] = { stamp = meta_stamp(root, meta), meta = meta }
      done(meta)
    end)
  end)
end

--- Blocking wrapper of metadata_async: meta, or nil + error. Waits at most `opts.timeout`
--- (default wait_ms) and only when the cache is cold.
function M.metadata(root, opts)
  opts = opts or {}
  local finished, meta, err
  M.metadata_async(root, function(m, e)
    finished, meta, err = true, m, e
  end, opts)
  if not block(function()
    return finished
  end, opts.timeout or (M.config.metadata_timeout_ms + 1000)) then
    return nil, "cargo metadata timed out"
  end
  return meta, err
end

--- Forget the cached metadata of `root` (all roots without argument).
function M.invalidate(root)
  if root then
    meta_cache[root] = nil
  else
    meta_cache = {}
  end
end

-- ----------------------------------------------------------------- locate

local located = {} -- dir -> { stamp, root = string|false }

--- Cargo's own answer for the workspace of `dir` (`cargo locate-project
--- --workspace`): knows `members` and `exclude`. Cached per directory and
--- `stamp` (the modification times of the manifests it depends on).
--- cb(root) with root = nil when cargo cannot answer (no cargo, a manifest that
--- does not parse). Always asynchronous.
function M.locate_async(dir, stamp, cb)
  local hit = located[dir]
  if hit and hit.stamp == stamp then
    return vim.schedule(function()
      cb(hit.root or nil)
    end)
  end
  if vim.fn.executable("cargo") ~= 1 then
    located[dir] = { stamp = stamp, root = false }
    return vim.schedule(function()
      cb(nil)
    end)
  end
  join("locate\0" .. dir .. "\0" .. stamp, cb, function(done)
    M.exec({ "cargo", "locate-project", "--workspace", "--message-format", "plain" }, { cwd = dir, timeout = M.config.locate_timeout_ms }, function(r)
      local manifest = r.code == 0 and vim.trim(r.stdout) or ""
      local root = manifest:match("Cargo%.toml$") and vim.fs.dirname(manifest) or false
      located[dir] = { stamp = stamp, root = root }
      done(root or nil)
    end)
  end)
end

--- The cached answer of locate_async: root (string), false (cargo has no answer) or nil (unknown yet).
function M.located(dir, stamp)
  local hit = located[dir]
  if hit and hit.stamp == stamp then
    return hit.root
  end
end

--- Blocking wrapper: the cached answer, else waits (at most wait_ms) for cargo.
function M.locate(dir, stamp)
  local cached = M.located(dir, stamp)
  if cached ~= nil then
    return cached or nil
  end
  local finished, root
  M.locate_async(dir, stamp, function(r)
    finished, root = true, r
  end)
  block(function()
    return finished
  end)
  return root
end

-- ---------------------------------------------------------- rustup targets

local targets_cache -- { at = ms, list = string[] }

--- Installed rustup targets, cached for targets_ttl_ms. cb(list) or cb(nil, err).
function M.installed_targets_async(cb, opts)
  opts = opts or {}
  if targets_cache and not opts.refresh and now_ms() - targets_cache.at < M.config.targets_ttl_ms then
    return vim.schedule(function()
      cb(vim.deepcopy(targets_cache.list))
    end)
  end
  join("targets", cb, function(done)
    M.exec({ "rustup", "target", "list", "--installed" }, { timeout = M.config.targets_timeout_ms }, function(r)
      if r.code ~= 0 then
        return done(nil, failure(r, "rustup target list"))
      end
      local list = {}
      for t in r.stdout:gmatch("[^\r\n]+") do
        list[#list + 1] = vim.trim(t)
      end
      targets_cache = { at = now_ms(), list = list }
      done(vim.deepcopy(list))
    end)
  end)
end

function M.reset_caches()
  meta_cache, located, targets_cache = {}, {}, nil
end

return M
