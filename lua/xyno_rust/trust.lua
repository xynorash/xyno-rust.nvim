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
-- API for other plugins (stable within api_version 1.x, see xyno_rust.api_version):
--   trust.is_trusted(root)               -> boolean, trusted_by_root?
--   trust.require(root, what, cb)        cb(true|false); asks once if needed; may call cb before it returns
--   trust.trust(root, { recursive? })    remember (recursive: everything below root)
--   trust.revoke(root) / trust.revoke_all()
--   trust.list()                         -> { { root, recursive, at } ... } sorted by root
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

local function entries()
  local out = {}
  for root, e in pairs(require("xyno_rust.statefile").read(file())) do
    if type(root) == "string" and type(e) == "table" then
      out[root] = { recursive = e.recursive == true, at = tonumber(e.at) or 0 }
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

--- Whether `root` (a workspace root or any path in it) is trusted. Second result: the entry that trusts it.
function M.is_trusted(root)
  local path = M.normalize(root)
  if not path then
    return false
  end
  local all = entries()
  if all[path] then
    return true, path
  end
  for dir, e in pairs(all) do
    if e.recursive and inside(path, dir) then
      return true, dir
    end
  end
  return false
end

function M.trust(root, opts)
  local path = M.normalize(root)
  assert(path, "trust.trust: a directory is required")
  require("xyno_rust.statefile").update(file(), function(all)
    all[path] = { recursive = (opts and opts.recursive) == true, at = os.time() }
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
  local choices = {
    { "Trust this workspace", "trust" },
    { "Trust everything under " .. parent, "parent" },
    { "Run this once", "once" },
    { "Do not run", "no" },
  }
  if parent == path or parent == "." then
    table.remove(choices, 2)
  end
  local function finish(answer)
    local waiting = asking[path]
    asking[path] = nil
    for _, f in ipairs(waiting) do
      f(answer)
    end
  end
  vim.ui.select(choices, {
    prompt = ("Trust %s?\n%s can run code from it (build.rs, proc macros, tests, workflow steps)."):format(path, what),
    format_item = function(c)
      return c[1]
    end,
  }, function(choice)
    local kind = choice and choice[2]
    if kind == "trust" or kind == "parent" then
      local ok, err = pcall(M.trust, kind == "parent" and parent or path, { recursive = kind == "parent" })
      if not ok then
        vim.notify("xyno-rust: could not remember the choice: " .. tostring(err), vim.log.levels.WARN)
      end
      return finish(true)
    end
    finish(kind == "once")
  end)
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
