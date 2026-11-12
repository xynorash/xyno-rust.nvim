-- Workspace trust for the Rust tooling, in the manner of VS Code's Workspace
-- Trust: running a target, a test, a cargo tool or `act` executes code that
-- comes with the project (build.rs, proc macros, tests, workflow steps), so in
-- a workspace nobody said they trust the plugin asks first. The answer is
-- remembered per workspace root in stdpath("state")/xyno-rust-trust.json,
-- listed and revoked with :RustTrust, and shared by every nvim instance.
--
-- What needs trust and what does not:
--   * Reading `cargo metadata --no-deps` and `cargo locate-project` is allowed
--     in any workspace: neither builds, runs build.rs / proc macros nor
--     resolves dependencies (checked with a canary build.rs and a canary
--     `build.rustc` in .cargo/config.toml, see tests/trust_spec.lua).
--   * Running a target / test / bench / doctest, samply / flamegraph, any
--     :RustTools entry and :ActJob needs trust.
--   * Starting rust-analyzer and bacon-ls is NOT done by this plugin (it only
--     supplies their settings): `ra_overrides(root)` returns the rust-analyzer
--     settings that keep an untrusted workspace from running build scripts and
--     proc macros, for a config to merge in. Nothing applies it by default.
--
-- Trust follows the content that runs code. A trust entry of its own (not "everything under <parent>")
-- stores a fingerprint of what cargo executes or obeys in that workspace: every Cargo.toml and build.rs
-- below the root, .cargo/config(.toml) and rust-toolchain(.toml) in the tree and in the parent
-- directories (cargo and rustup read those upward). When the content differs (a `git pull`, a checkout
-- of another branch, an unseen edit by another tool) the workspace is untrusted again and the next
-- action asks once more, naming the files. Not part of it: .rs sources, Cargo.lock, target/, .git/
-- (ordinary edits and a lockfile refresh never ask). Edits made inside nvim call `rehash`, so the
-- editor's own saves are not re-asked. direnv works this way (re-asks after .envrc changes); VS Code's
-- Workspace Trust asks once per folder and never again, which is why a pulled build.rs runs there
-- unannounced. "Trust everything under <parent>" is one explicit decision about a whole tree and keeps
-- no fingerprint.
--
-- API for other plugins (stable within api_version 1.x, see xyno_rust.api_version):
--   trust.is_trusted(root)               -> boolean, trusted_by_root?
--   trust.require(root, what, cb)        cb(true|false); asks once if needed; may call cb before it returns
--   trust.trust(root, { recursive? })    remember (recursive: everything below root)
--   trust.revoke(root) / trust.revoke_all()
--   trust.list()                         -> { { root, recursive, at } ... } sorted by root
--   trust.drift(root)                    -> nil, or the files whose content differs from what was trusted (api 1.3)
--   trust.rehash(root, saved?)           -> boolean: record the current content of root's own entry (only `saved` may differ) (api 1.3)
--   trust.fingerprint(root)              -> { hash, files = { [rel|abs path] = short hash }, truncated? } (api 1.3)
--   trust.ra_overrides(root)             -> rust-analyzer settings table ({} for a trusted workspace)
local M = {}

local function file()
  return vim.fn.stdpath("state") .. "/xyno-rust-trust.json"
end
M.file = file

--- One spelling per directory: symlinks resolved (a link into a trusted tree is
--- that tree), Windows drive letters / slashes unified, no trailing slash.
function M.normalize(root)
  if type(root) ~= "string" or root == "" then
    return nil
  end
  local real = vim.uv.fs_realpath(root) or root
  real = require("xyno_rust.rust_context").canon(real)
  real = real:gsub("[/\\]+$", "")
  return real ~= "" and real or "/"
end


-- ------------------------------------------------------------ fingerprint

local SKIP_DIR = { target = true, [".git"] = true, [".hg"] = true, [".svn"] = true, node_modules = true }
local WATCHED = { ["Cargo.toml"] = true, ["build.rs"] = true, ["rust-toolchain"] = true, ["rust-toolchain.toml"] = true }
local MAX_FILES, MAX_DEPTH, MAX_BYTES = 400, 6, 1024 * 1024

local function digest(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read(MAX_BYTES) or ""
  f:close()
  return vim.fn.sha256(text)
end

--- What cargo executes or obeys under `root`: { hash = combined, files = { [name] = first 12 hex digits } }.
--- Names are relative to root, or absolute for files in parent directories.
function M.fingerprint(root)
  local path = M.normalize(root)
  local files, n, truncated = {}, 0, false
  local function add(name, full)
    if n >= MAX_FILES then
      truncated = true
      return
    end
    local d = digest(full)
    if d then
      n = n + 1
      files[name] = d:sub(1, 12)
    end
  end
  local function walk(dir, rel, depth)
    local handle = vim.uv.fs_scandir(dir)
    if not handle then
      return
    end
    local sub = {}
    while true do
      local name, kind = vim.uv.fs_scandir_next(handle)
      if not name then
        break
      end
      local relname = rel == "" and name or (rel .. "/" .. name)
      if kind == "file" then
        if WATCHED[name] or ((name == "config" or name == "config.toml") and vim.fs.basename(dir) == ".cargo")
          or (name == "run.toml" and vim.fs.basename(dir) == ".xynovim") then
          add(relname, dir .. "/" .. name)
        end
      elseif kind == "directory" and not SKIP_DIR[name] and depth < MAX_DEPTH then
        sub[#sub + 1] = { dir .. "/" .. name, relname }
      end
    end
    table.sort(sub, function(a, b)
      return a[2] < b[2]
    end)
    for _, d in ipairs(sub) do
      walk(d[1], d[2], depth + 1)
    end
  end
  if path then
    walk(path, "", 0)
    -- cargo reads .cargo/config(.toml) and rustup rust-toolchain(.toml) of every parent directory
    local dir = vim.fs.dirname(path)
    local guard = 0
    while dir and dir ~= "" and guard < 64 do
      guard = guard + 1
      for _, name in ipairs({ ".cargo/config", ".cargo/config.toml", "rust-toolchain", "rust-toolchain.toml" }) do
        add(dir == "/" and ("/" .. name) or (dir .. "/" .. name), (dir == "/" and "" or dir) .. "/" .. name)
      end
      local up = vim.fs.dirname(dir)
      if up == dir then
        break
      end
      dir = up
    end
  end
  local names = vim.tbl_keys(files)
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do
    parts[#parts + 1] = name .. "\0" .. files[name]
  end
  return { hash = vim.fn.sha256(table.concat(parts, "\n")), files = files, truncated = truncated or nil }
end

local function changed_files(old, new)
  local out = {}
  for name, h in pairs(new) do
    if old[name] ~= h then
      out[#out + 1] = name
    end
  end
  for name in pairs(old) do
    if new[name] == nil then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

local function entry_of(path)
  local e = require("xyno_rust.statefile").read(file())[path]
  return type(e) == "table" and e or nil
end

local function entries()
  local out = {}
  for root, e in pairs(require("xyno_rust.statefile").read(file())) do
    if type(root) == "string" and type(e) == "table" then
      out[root] = {
        recursive = e.recursive == true,
        at = tonumber(e.at) or 0,
        hash = type(e.hash) == "string" and e.hash or nil,
        files = type(e.files) == "table" and e.files or nil,
      }
    end
  end
  return out
end

local function inside(path, dir)
  if dir == "/" then
    return true
  end
  return path == dir or path:sub(1, #dir + 1) == dir .. "/"
end

--- The entry of `path` itself is trusted only while the content it was trusted for is unchanged.
--- An entry without a fingerprint (stored by an older version) takes the current one on first sight.
local function entry_current(path, e)
  if e.recursive then
    return true
  end
  if not e.hash then
    pcall(function()
      local f = M.fingerprint(path)
      require("xyno_rust.statefile").update(file(), function(all)
        if type(all[path]) == "table" and not all[path].hash then
          all[path].hash, all[path].files = f.hash, f.files
        end
      end)
    end)
    return true
  end
  return M.fingerprint(path).hash == e.hash
end

--- Whether `root` (a workspace root or any path in it) is trusted. Second result: the entry that trusts it.
--- A workspace whose manifests / build scripts / cargo config / toolchain changed since it was trusted is
--- not (see the header; `drift` names the files).
function M.is_trusted(root)
  local path = M.normalize(root)
  if not path then
    return false
  end
  local all = entries()
  if all[path] and entry_current(path, all[path]) then
    return true, path
  end
  for dir, e in pairs(all) do
    if e.recursive and inside(path, dir) then
      return true, dir
    end
  end
  return false
end

--- nil when `root` has no entry of its own or nothing changed; else the names of the changed files.
function M.drift(root)
  local path = M.normalize(root)
  local e = path and entries()[path]
  if not e or e.recursive or not e.hash then
    return nil
  end
  local f = M.fingerprint(path)
  if f.hash == e.hash then
    return nil
  end
  local names = e.files and changed_files(e.files, f.files) or {}
  return #names > 0 and names or { "(content)" }
end

--- Record the current content for the entry of `root` itself. Returns whether it was recorded.
--- With `saved` (an edit made inside nvim: the path that was saved) only that file may differ from what
--- was trusted: if something else changed too (a pulled build.rs next to the Cargo.toml you just
--- saved), nothing is recorded and the workspace stays untrusted.
function M.rehash(root, saved)
  local path = M.normalize(root)
  local e = path and entries()[path]
  if not e or e.recursive then
    return false
  end
  local f = M.fingerprint(path)
  if saved and e.files then
    local only = vim.fs.normalize(vim.uv.fs_realpath(saved) or saved)
    for _, name in ipairs(changed_files(e.files, f.files)) do
      local full = name:sub(1, 1) == "/" and name or (path .. "/" .. name)
      if vim.fs.normalize(vim.uv.fs_realpath(full) or full) ~= only then
        return false
      end
    end
  end
  local had = false
  require("xyno_rust.statefile").update(file(), function(all)
    local cur = all[path]
    if type(cur) == "table" and not cur.recursive then
      cur.hash, cur.files = f.hash, f.files
      had = true
    end
  end)
  return had
end

function M.trust(root, opts)
  local path = M.normalize(root)
  assert(path, "trust.trust: a directory is required")
  local fp = not (opts and opts.recursive) and M.fingerprint(path) or nil
  require("xyno_rust.statefile").update(file(), function(all)
    local recursive = (opts and opts.recursive) == true
    all[path] = { recursive = recursive, at = os.time() }
    if not recursive then
      all[path].hash, all[path].files = fp.hash, fp.files
    end
  end)
  return path
end

--- Returns whether an entry was removed.
function M.revoke(root)
  local path = M.normalize(root)
  local had = false
  if path then
    require("xyno_rust.statefile").update(file(), function(all)
      had = all[path] ~= nil
      all[path] = nil
    end)
  end
  return had
end

function M.revoke_all()
  require("xyno_rust.statefile").update(file(), function(all)
    for k in pairs(all) do
      all[k] = nil
    end
  end)
end

function M.list()
  local out = {}
  for root, e in pairs(entries()) do
    out[#out + 1] = { root = root, recursive = e.recursive, at = e.at }
  end
  table.sort(out, function(a, b)
    return a.root < b.root
  end)
  return out
end

local asking = {} -- root -> { cb ... } : one prompt per root at a time
local ask_timers = {} -- root -> uv timer that gives up on a prompt nobody answers
M.ask_timeout_ms = 300000 -- a prompt vim.ui.select never answers (a broken UI plugin) is dropped after this long

local function drop_asking()
  for path, t in pairs(ask_timers) do
    pcall(function()
      t:stop()
      t:close()
    end)
    ask_timers[path] = nil
  end
  asking = {}
end

--- Ask whether to trust `root` for `what` (a short description of the action).
--- cb(true) after "trust" or "run once", cb(false) otherwise. Nothing is stored
--- for "run once" and "do not run": the next action asks again.
function M.ask(root, what, cb)
  local path = M.normalize(root)
  if not path then
    return cb(false)
  end
  if asking[path] then
    table.insert(asking[path], cb)
    return
  end
  asking[path] = { cb }
  local parent = vim.fs.dirname(path)
  local drifted = M.drift(path)
  local choices = {
    { "Trust this workspace", "trust" },
    { "Trust everything under " .. parent, "parent" },
    { "Run this once", "once" },
    { "Do not run", "no" },
  }
  if parent == path or parent == "." then
    table.remove(choices, 2)
  end
  local mine = asking[path] -- a late answer of a prompt that already timed out must not touch a newer one
  local function finish(answer)
    if asking[path] ~= mine then
      return
    end
    asking[path] = nil
    local t = ask_timers[path]
    if t then
      ask_timers[path] = nil
      pcall(function()
        t:stop()
        t:close()
      end)
    end
    for _, f in ipairs(mine) do
      f(answer)
    end
  end
  if not M._leave_hooked then
    M._leave_hooked = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("xyno_rust_trust_ask", { clear = true }),
      callback = drop_asking, -- no callbacks at exit: the refusal would only notify into a closing UI
    })
  end
  local timer = vim.uv.new_timer()
  ask_timers[path] = timer
  timer:start(M.ask_timeout_ms, 0, vim.schedule_wrap(function()
    if asking[path] == mine then
      vim.notify(("xyno-rust: the trust prompt for %s got no answer and was dropped (treated as 'do not run')"):format(path), vim.log.levels.WARN)
      finish(false)
    end
  end))
  local ok, err = pcall(vim.ui.select, choices, {
    prompt = ("Trust %s?\n%s can run code from it (build.rs, proc macros, tests, workflow steps)."):format(path, what)
      .. (drifted and ("\nTrusted before, but changed since: %s%s"):format(table.concat(vim.list_slice(drifted, 1, 6), ", "), #drifted > 6 and (" and " .. (#drifted - 6) .. " more") or "") or ""),
    format_item = function(c)
      return c[1]
    end,
  }, function(choice)
    local kind = choice and choice[2]
    if kind == "trust" or kind == "parent" then
      local tok, terr = pcall(M.trust, kind == "parent" and parent or path, { recursive = kind == "parent" })
      if not tok then
        vim.notify("xyno-rust: could not remember the choice: " .. tostring(terr), vim.log.levels.WARN)
      end
      return finish(true)
    end
    finish(kind == "once")
  end)
  if not ok then
    if asking[path] ~= mine then
      error(err, 0) -- the prompt answered and a callback raised: that is the caller's error, not the prompt's
    end
    vim.notify("xyno-rust: the trust prompt failed: " .. tostring(err), vim.log.levels.WARN)
    finish(false)
  end
end

--- cb(true) when `root` is trusted or the user agrees; cb(false) otherwise (a refusal is notified).
function M.require(root, what, cb)
  if M.is_trusted(root) then
    return cb(true)
  end
  M.ask(root, what, function(ok)
    if not ok then
      vim.notify(("xyno-rust: %s not run: %s is not a trusted workspace (:RustTrust add)"):format(what, tostring(root)), vim.log.levels.WARN)
    end
    cb(ok)
  end)
end

--- rust-analyzer settings that stop an untrusted workspace from running code:
--- no build scripts, no proc macros (rust-analyzer then reports less, it does not fail).
function M.ra_overrides(root)
  if M.is_trusted(root) then
    return {}
  end
  return {
    cargo = { buildScripts = { enable = false } },
    procMacro = { enable = false },
  }
end

local function target_dir(arg)
  if arg and arg ~= "" then
    return vim.fn.fnamemodify(vim.fn.expand(arg), ":p")
  end
  return require("xyno_rust.rust_context").root() or vim.uv.cwd()
end

local function fmt(e)
  return ("%s%s  (%s)"):format(e.root, e.recursive and "/**" or "", e.at > 0 and os.date("%Y-%m-%d", e.at) or "?")
end

--- :RustTrust [list | add [dir] | revoke [dir] | revoke-all | status]
function M.command(args)
  local sub, rest = args:match("^(%S*)%s*(.-)%s*$")
  if sub == "" or sub == "list" then
    local list = M.list()
    if #list == 0 then
      return vim.notify("xyno-rust: no trusted workspaces", vim.log.levels.INFO)
    end
    if sub == "" then -- the bare command lists and offers to revoke
      return vim.ui.select(list, { prompt = "Trusted Rust workspaces (select one to revoke)", format_item = fmt }, function(e)
        if e then
          M.revoke(e.root)
          vim.notify("xyno-rust: revoked " .. e.root)
        end
      end)
    end
    return vim.notify("xyno-rust trusted workspaces:\n" .. table.concat(vim.tbl_map(fmt, list), "\n"))
  elseif sub == "add" then
    local dir = target_dir(rest)
    vim.notify("xyno-rust: trusted " .. M.trust(dir))
  elseif sub == "revoke" then
    local dir = target_dir(rest)
    vim.notify(M.revoke(dir) and ("xyno-rust: revoked " .. M.normalize(dir)) or ("xyno-rust: " .. dir .. " had no entry of its own"), vim.log.levels.INFO)
  elseif sub == "revoke-all" then
    M.revoke_all()
    vim.notify("xyno-rust: all trust entries revoked")
  elseif sub == "status" then
    local dir = target_dir(rest)
    local ok, by = M.is_trusted(dir)
    vim.notify(("xyno-rust: %s is %s%s"):format(M.normalize(dir), ok and "trusted" or "NOT trusted", ok and by ~= M.normalize(dir) and (" (under " .. by .. ")") or ""))
  else
    vim.notify("RustTrust: unknown argument '" .. sub .. "' (list, add, revoke, revoke-all, status)", vim.log.levels.WARN)
  end
end

--- opts.commands = false: do not define :RustTrust.
function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  vim.api.nvim_create_user_command("RustTrust", function(a)
    M.command(a.args)
  end, {
    nargs = "*",
    complete = function(lead, line)
      if line:match("^%S+%s+%S*$") then
        return vim.tbl_filter(function(s)
          return s:find(lead, 1, true) == 1
        end, { "list", "add", "revoke", "revoke-all", "status" })
      end
      return vim.fn.getcompletion(lead, "dir")
    end,
    desc = "Workspace trust for running Rust targets and tools: list, add, revoke",
  })
end

return M
