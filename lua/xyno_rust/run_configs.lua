-- Run configurations, saved per project (the JetBrains idea: a named "cargo run --bin x -- args" with
-- environment variables, kept between sessions), without an IDE-style dialog: a picker to run, edit and
-- delete them and a few prompts to make one.
--
--   :RustRun [name]      pick a configuration and run it (or run `name`); "+ new" makes one
--   :RustRunLast         run the previous one again (the last one run in this project)
--   :RustRunEdit [name]  change a configuration (prompts, prefilled)
--   :RustRunDelete [name]
--
-- A configuration is data, never a shell line:
--   { name, cmd = "run"|"test"|"bench"|"build"|"check"|"clippy", package?, bin?|example?|test?|bench?|lib?,
--     cargo_args = "--release", args = "--port 8080 'a b'", env = { RUST_LOG = "debug" },
--     profiler = "none"|"samply"|"flamegraph" }
-- `cargo_args` and `args` are split with split_args (quotes group, nothing is expanded: no `$VAR`, no
-- backticks, no `;`), the result is an argv list and goes to the terminal as one: a configuration can not
-- run anything but cargo (or, for profilers, samply / cargo-flamegraph) with the arguments that were typed.
-- `args` follow `--` (the program's own arguments; for `test` / `bench` they reach the test harness).
-- The feature flags of :RustContext are added unless `cargo_args` names `--features`, `-F`,
-- `--all-features` or `--no-default-features` itself.
--
-- Storage: stdpath("state")/xyno-rust-run-configs.json, keyed by workspace root, like the :RustContext
-- choice. It is NOT read from the project: a repository can not ship a run configuration that runs on your
-- machine. Running one still asks for workspace trust once (trust.lua), like :RustTargets.
local M = {}

M.CMDS = { "run", "test", "bench", "build", "check", "clippy" }
M.PROFILERS = { "none", "samply", "flamegraph" }
-- only these can profile a binary
local TARGET_KEYS = { "bin", "example", "test", "bench", "lib" }

local function file()
  return vim.fn.stdpath("state") .. "/xyno-rust-run-configs.json"
end
M.file = file

-- ------------------------------------------------------------------ parsing

--- "a --b 'c d' \"e f\" g\\ h" -> { "a", "--b", "c d", "e f", "g h" }. Quotes group and a backslash
--- escapes the next character (outside single quotes). Nothing else is special. Returns nil, reason
--- for an unterminated quote.
---@param s string?
---@return string[]?, string?
function M.split_args(s)
  local out, cur, has, q = {}, {}, false, nil
  local i, n = 1, #(s or "")
  s = s or ""
  while i <= n do
    local c = s:sub(i, i)
    if q then
      if c == q then
        q = nil
      elseif c == "\\" and q == '"' and s:sub(i + 1, i + 1):match('["\\]') then
        i = i + 1
        cur[#cur + 1] = s:sub(i, i)
      else
        cur[#cur + 1] = c
      end
    elseif c == "'" or c == '"' then
      q, has = c, true
    elseif c == "\\" and i < n then
      i = i + 1
      cur[#cur + 1] = s:sub(i, i)
      has = true
    elseif c:match("%s") then
      if has or #cur > 0 then
        out[#out + 1] = table.concat(cur)
        cur, has = {}, false
      end
    else
      cur[#cur + 1] = c
    end
    i = i + 1
  end
  if q then
    return nil, "unterminated " .. q .. " quote"
  end
  if has or #cur > 0 then
    out[#out + 1] = table.concat(cur)
  end
  return out
end

--- The inverse for display and editing: words with blanks or quotes are quoted.
---@param words string[]
function M.join_args(words)
  return table.concat(
    vim.tbl_map(function(w)
      if w == "" or w:find("[%s'\"\\]") then
        return "'" .. w:gsub("'", [['\'']]) .. "'"
      end
      return w
    end, words),
    " "
  )
end

--- "RUST_LOG=debug A=1" -> { RUST_LOG = "debug", A = "1" }. The value may be quoted. Returns nil,
--- reason for a word that is not NAME=value or a NAME that is not an identifier.
---@param s string?
---@return table<string,string>?, string?
function M.parse_env(s)
  local words, err = M.split_args(s)
  if not words then
    return nil, err
  end
  local env = {}
  for _, w in ipairs(words) do
    local k, v = w:match("^([^=]+)=(.*)$")
    if not k then
      return nil, ("%q is not NAME=value"):format(w)
    end
    if not k:match("^[A-Za-z_][A-Za-z0-9_]*$") then
      return nil, ("%q is not a valid variable name"):format(k)
    end
    env[k] = v
  end
  return env
end

--- Sorted "A=1 B='x y'" text of an env table.
function M.format_env(env)
  local keys = vim.tbl_keys(env or {})
  table.sort(keys)
  return table.concat(
    vim.tbl_map(function(k)
      local v = env[k]
      if v == "" or v:find("[%s'\"\\]") then
        v = "'" .. v:gsub("'", [['\'']]) .. "'"
      end
      return k .. "=" .. v
    end, keys),
    " "
  )
end

-- ----------------------------------------------------------------- storage

local function rootkey(root)
  return require("xyno_rust.trust").normalize(root)
end

--- Keep what the fields allow; drop the rest (a hand-edited file must not crash the picker).
---@return table?
function M.sanitize(c)
  if type(c) ~= "table" or type(c.name) ~= "string" or c.name:match("^%s*$") then
    return nil
  end
  local cmd = vim.tbl_contains(M.CMDS, c.cmd) and c.cmd or "run"
  local out = { name = vim.trim(c.name), cmd = cmd, cargo_args = type(c.cargo_args) == "string" and c.cargo_args or "", args = type(c.args) == "string" and c.args or "" }
  if type(c.package) == "string" and c.package ~= "" then
    out.package = c.package
  end
  for _, k in ipairs(TARGET_KEYS) do
    if c[k] == true or (type(c[k]) == "string" and c[k] ~= "") then
      out[k] = c[k]
      break
    end
  end
  out.env = {}
  if type(c.env) == "table" then
    for k, v in pairs(c.env) do
      if type(k) == "string" and k:match("^[A-Za-z_][A-Za-z0-9_]*$") and type(v) == "string" then
        out.env[k] = v
      end
    end
  end
  out.profiler = vim.tbl_contains(M.PROFILERS, c.profiler) and c.profiler or "none"
  return out
end

---@return { configs: table[], last?: string }
function M.load(root)
  local key = rootkey(root)
  local raw = key and require("xyno_rust.statefile").read(file())[key]
  local res = { configs = {} }
  if type(raw) ~= "table" then
    return res
  end
  local seen = {}
  for _, c in ipairs(type(raw.configs) == "table" and raw.configs or {}) do
    local s = M.sanitize(c)
    if s and not seen[s.name] then
      seen[s.name] = true
      res.configs[#res.configs + 1] = s
    end
  end
  if type(raw.last) == "string" and seen[raw.last] then
    res.last = raw.last
  end
  return res
end

local function store(root, fn)
  local key = rootkey(root)
  if not key then
    return false
  end
  require("xyno_rust.statefile").update(file(), function(all)
    local cur = M.load(root)
    fn(cur)
    all[key] = { configs = cur.configs, last = cur.last }
  end)
  return true
end

--- Add `cfg` or replace the configuration called `replace` (a rename keeps its place).
---@return table? sanitized, string? error
function M.save(root, cfg, replace)
  local s = M.sanitize(cfg)
  if not s then
    return nil, "a configuration needs a name"
  end
  local clash
  local ok = store(root, function(cur)
    local at
    for i, c in ipairs(cur.configs) do
      if c.name == (replace or s.name) then
        at = i
      end
      if c.name == s.name and (not replace or c.name ~= replace) then
        clash = true -- a new one, or a rename onto another configuration
      end
    end
    if clash then
      return
    end
    if at then
      cur.configs[at] = s
    else
      cur.configs[#cur.configs + 1] = s
    end
    if replace and cur.last == replace then
      cur.last = s.name
    end
  end)
  if not ok then
    return nil, "no workspace root"
  end
  if clash then
    return nil, ("a configuration called %q exists"):format(s.name)
  end
  return s
end

function M.delete(root, name)
  local removed
  store(root, function(cur)
    for i, c in ipairs(cur.configs) do
      if c.name == name then
        table.remove(cur.configs, i)
        removed = true
        break
      end
    end
    if cur.last == name then
      cur.last = nil
    end
  end)
  return removed == true
end

function M.set_last(root, name)
  store(root, function(cur)
    for _, c in ipairs(cur.configs) do
      if c.name == name then
        cur.last = name
      end
    end
  end)
end

-- ------------------------------------------------------------ command line

local FEATURE_FLAGS = { ["--features"] = true, ["-F"] = true, ["--all-features"] = true, ["--no-default-features"] = true }

local function names_features(words)
  for _, w in ipairs(words) do
    if FEATURE_FLAGS[w] or w:find("^%-%-features=") or w:find("^%-F.") then
      return true
    end
  end
  return false
end

--- cargo's profile for a profiled run: release plus debug symbols, defined on the command line so it
--- works without a `[profile.profiling]` in the user's Cargo.toml / ~/.cargo/config.toml (an existing
--- definition of the same name is overridden by these two values only).
M.PROFILING_FLAGS = { "--config", 'profile.profiling.inherits="release"', "--config", "profile.profiling.debug=true" }

--- argv + env of a configuration. `ctx_flags` are the :RustContext feature flags (a list), `meta` the
--- `cargo metadata --no-deps` table (needed for profilers: the binary's path).
---@return { argv: string[], env: table<string,string>, tool?: string, label: string }?, string? error
function M.build(cfg, ctx_flags, meta)
  cfg = M.sanitize(cfg)
  if not cfg then
    return nil, "invalid configuration"
  end
  local cargo_extra, e1 = M.split_args(cfg.cargo_args)
  if not cargo_extra then
    return nil, "cargo arguments: " .. e1
  end
  local prog, e2 = M.split_args(cfg.args)
  if not prog then
    return nil, "program arguments: " .. e2
  end
  local sel = {}
  if cfg.package then
    vim.list_extend(sel, { "-p", cfg.package })
  end
  for _, k in ipairs(TARGET_KEYS) do
    if cfg[k] == true then
      sel[#sel + 1] = "--" .. k
    elseif cfg[k] then
      vim.list_extend(sel, { "--" .. k, cfg[k] })
    end
  end
  local features = names_features(cargo_extra) and {} or (ctx_flags or {})
  local label = cfg.name
  if cfg.profiler ~= "none" then
    if cfg.cmd ~= "run" or not cfg.bin then
      return nil, "profilers need a configuration that runs a binary (command run, a --bin target)"
    end
    if cfg.profiler == "samply" then
      local pkg
      for _, p in ipairs(meta and meta.packages or {}) do
        if (not cfg.package or p.name == cfg.package) then
          for _, t in ipairs(p.targets) do
            if t.name == cfg.bin and t.kind[1] == "bin" then
              pkg = pkg or p
            end
          end
        end
      end
      if not pkg or not meta then
        return nil, ("binary %q not found in cargo metadata"):format(cfg.bin)
      end
      local exe = ("%s/profiling/%s%s"):format(meta.target_directory, cfg.bin, vim.fn.has("win32") == 1 and ".exe" or "")
      -- `--target T` is not supported here: the path would change; say so instead of recording the wrong binary
      if vim.tbl_contains(cargo_extra, "--target") then
        return nil, "samply: --target changes the binary's path; remove it from the cargo arguments"
      end
      local build = { "cargo", "build", "--profile", "profiling" }
      vim.list_extend(build, M.PROFILING_FLAGS)
      vim.list_extend(build, { "-p", pkg.name, "--bin", cfg.bin })
      vim.list_extend(build, features)
      vim.list_extend(build, cargo_extra)
      local argv = { "sh", "-c", table.concat(vim.tbl_map(vim.fn.shellescape, build), " ") .. ' && exec samply record "$@"', "samply", exe }
      if vim.fn.has("win32") == 1 then
        return nil, "samply from a run configuration needs a POSIX shell; use :RustTargets on Windows"
      end
      vim.list_extend(argv, prog)
      return { argv = argv, env = cfg.env, tool = "samply", label = label }
    end
    -- cargo flamegraph takes the same -p / --bin; the program's arguments follow `--`
    local argv = { "cargo", "flamegraph", "--profile", "profiling" }
    vim.list_extend(argv, M.PROFILING_FLAGS)
    vim.list_extend(argv, sel)
    vim.list_extend(argv, features)
    vim.list_extend(argv, cargo_extra)
    if #prog > 0 then
      argv[#argv + 1] = "--"
      vim.list_extend(argv, prog)
    end
    return { argv = argv, env = cfg.env, tool = "cargo-flamegraph", label = label }
  end
  local argv = { "cargo", cfg.cmd }
  vim.list_extend(argv, sel)
  vim.list_extend(argv, features)
  vim.list_extend(argv, cargo_extra)
  if #prog > 0 then
    argv[#argv + 1] = "--"
    vim.list_extend(argv, prog)
  end
  return { argv = argv, env = cfg.env, label = label }
end

-- ------------------------------------------------------------------- doing

--- Default configurations of a workspace, for the first run: every binary and example, and "test all".
---@param meta table cargo metadata --no-deps
function M.defaults(meta)
  local out = {}
  local multi = #meta.packages > 1
  for _, p in ipairs(meta.packages) do
    for _, t in ipairs(p.targets) do
      local k = t.kind[1]
      if k == "bin" or k == "example" then
        out[#out + 1] = M.sanitize({
          name = "run " .. t.name,
          cmd = "run",
          package = multi and p.name or nil,
          [k] = t.name,
        })
      end
    end
  end
  out[#out + 1] = M.sanitize({ name = "test all", cmd = "test", cargo_args = "--workspace" })
  return out
end

--- Run the terminal: the same one-at-a-time bottom terminal as :RustTargets.
local function open(argv, env, root)
  local Snacks = require("xyno_rust.deps").snacks()
  if not Snacks then
    return
  end
  local old = M._last_term
  if old and old.buf_valid and old:buf_valid() then
    pcall(old.close, old, { buf = true })
  end
  M._last_term = Snacks.terminal.open(argv, { cwd = root, env = env, auto_close = false, win = { position = "bottom" } })
  return M._last_term
end
-- specs replace this to see what would run
M.open = open

local function exe_ok(tool)
  if tool == "samply" then
    return vim.fn.executable("samply") == 1, "samply is not installed (cargo install samply)"
  elseif tool == "cargo-flamegraph" then
    return vim.fn.executable("cargo-flamegraph") == 1, "cargo-flamegraph is not installed (cargo install flamegraph)"
  end
  return true
end

--- Run `cfg` in `root`: build the argv, check the profiler is installed, ask for trust, open the terminal.
function M.run(root, cfg, meta)
  local ctx = require("xyno_rust.rust_context")
  local built, err = M.build(cfg, ctx.cargo_flags(ctx.get(root)), meta)
  if not built then
    return vim.notify("xyno-rust: " .. err, vim.log.levels.ERROR)
  end
  local ok, why = exe_ok(built.tool)
  if not ok then
    return vim.notify("xyno-rust: " .. why, vim.log.levels.ERROR)
  end
  require("xyno_rust.trust").require(root, built.label, function(go)
    if go then
      M.set_last(root, cfg.name)
      M.open(built.argv, next(built.env) and built.env or nil, root)
    end
  end)
end

local function with_workspace(cb)
  local rc = require("xyno_rust.rust_context")
  rc.root_async(nil, function(root)
    if not root then
      return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
    end
    require("xyno_rust.cargo").metadata_async(root, function(meta, err)
      if not meta then
        return vim.notify("cargo metadata failed: " .. tostring(err), vim.log.levels.ERROR)
      end
      cb(root, meta)
    end)
  end)
end

local function find(root, name)
  for _, c in ipairs(M.load(root).configs) do
    if c.name == name then
      return c
    end
  end
end

--- The prompts of a new or edited configuration; `cfg` prefills them. `done(cfg)` gets the result.
function M.prompt(root, meta, cfg, done)
  cfg = vim.deepcopy(cfg or { cmd = "run" })
  local targets = {}
  for _, p in ipairs(meta.packages) do
    for _, t in ipairs(p.targets) do
      local k = t.kind[1]
      k = (k == "proc-macro" or k == "rlib" or k == "cdylib" or k == "staticlib" or k == "dylib") and "lib" or k
      if vim.tbl_contains(TARGET_KEYS, k) then
        targets[#targets + 1] = { text = ("%s %s (%s)"):format(k, t.name, p.name), kind = k, name = t.name, package = p.name }
      end
    end
  end
  local function ask(steps, i)
    if i > #steps then
      return done(cfg)
    end
    steps[i](function()
      ask(steps, i + 1)
    end)
  end
  local steps = {
    function(nxt) -- target
      if not cfg.name or cfg.name == "" or not (cfg.bin or cfg.example or cfg.test or cfg.bench or cfg.lib) then
        vim.ui.select(targets, {
          prompt = "Target",
          format_item = function(t)
            return t.text
          end,
        }, function(t)
          if not t then
            return
          end
          for _, k in ipairs(TARGET_KEYS) do
            cfg[k] = nil
          end
          cfg[t.kind] = t.kind == "lib" and true or t.name
          cfg.package = #meta.packages > 1 and t.package or nil
          if t.kind == "test" then
            cfg.cmd = "test"
          elseif t.kind == "bench" then
            cfg.cmd = "bench"
          elseif t.kind == "lib" then
            cfg.cmd = "test"
          else
            cfg.cmd = "run"
          end
          nxt()
        end)
      else
        nxt()
      end
    end,
    function(nxt) -- command
      vim.ui.select(M.CMDS, { prompt = "cargo command (now: " .. (cfg.cmd or "run") .. ")" }, function(c)
        if c then
          cfg.cmd = c
          nxt()
        end
      end)
    end,
    function(nxt)
      vim.ui.input({ prompt = "Program arguments (after --): ", default = cfg.args or "" }, function(v)
        if v ~= nil then
          local _, e = M.split_args(v)
          if e then
            return vim.notify("xyno-rust: " .. e, vim.log.levels.ERROR)
          end
          cfg.args = v
          nxt()
        end
      end)
    end,
    function(nxt)
      vim.ui.input({ prompt = "Cargo arguments (e.g. --release): ", default = cfg.cargo_args or "" }, function(v)
        if v ~= nil then
          local _, e = M.split_args(v)
          if e then
            return vim.notify("xyno-rust: " .. e, vim.log.levels.ERROR)
          end
          cfg.cargo_args = v
          nxt()
        end
      end)
    end,
    function(nxt)
      vim.ui.input({ prompt = "Environment (NAME=value ...): ", default = M.format_env(cfg.env) }, function(v)
        if v ~= nil then
          local env, e = M.parse_env(v)
          if not env then
            return vim.notify("xyno-rust: " .. e, vim.log.levels.ERROR)
          end
          cfg.env = env
          nxt()
        end
      end)
    end,
    function(nxt)
      if cfg.cmd ~= "run" or not cfg.bin then
        cfg.profiler = "none"
        return nxt()
      end
      vim.ui.select(M.PROFILERS, { prompt = "Profiler (now: " .. (cfg.profiler or "none") .. ")" }, function(p)
        if p then
          cfg.profiler = p
          nxt()
        end
      end)
    end,
    function(nxt)
      local def = cfg.name
      if not def or def == "" then
        def = (cfg.cmd or "run") .. " " .. (cfg.bin or cfg.example or cfg.test or cfg.bench or "lib")
        if cfg.profiler and cfg.profiler ~= "none" then
          def = def .. " (" .. cfg.profiler .. ")"
        end
      end
      vim.ui.input({ prompt = "Name: ", default = def }, function(v)
        if v and vim.trim(v) ~= "" then
          cfg.name = vim.trim(v)
          nxt()
        end
      end)
    end,
  }
  ask(steps, 1)
end

--- New or edited: prompts, then save. `old` is the configuration being edited.
function M.edit(root, meta, old)
  local replace = old and old.name
  M.prompt(root, meta, old, function(cfg)
    local saved, err = M.save(root, cfg, replace)
    if not saved then
      return vim.notify("xyno-rust: " .. err, vim.log.levels.ERROR)
    end
    vim.notify(("xyno-rust: saved %q. :RustRun to run it"):format(saved.name))
  end)
end

local function describe(c)
  local t = c.bin and ("bin " .. c.bin) or c.example and ("example " .. c.example) or c.test and ("test " .. c.test)
    or c.bench and ("bench " .. c.bench) or c.lib and "lib" or "workspace"
  local extra = {}
  if c.args ~= "" then
    extra[#extra + 1] = "-- " .. c.args
  end
  if c.cargo_args ~= "" then
    extra[#extra + 1] = c.cargo_args
  end
  if next(c.env) then
    extra[#extra + 1] = M.format_env(c.env)
  end
  if c.profiler ~= "none" then
    extra[#extra + 1] = "[" .. c.profiler .. "]"
  end
  return ("%-24s cargo %s %s  %s"):format(c.name, c.cmd, t, table.concat(extra, "  "))
end
M.describe = describe

--- The picker. Enter runs; <C-e> edits, <C-x> deletes the highlighted configuration.
function M.pick()
  with_workspace(function(root, meta)
    local cur = M.load(root)
    if #cur.configs == 0 then
      for _, c in ipairs(M.defaults(meta)) do
        M.save(root, c)
      end
      cur = M.load(root)
    end
    local Snacks = require("xyno_rust.deps").snacks()
    if not Snacks then
      return
    end
    local items = {}
    -- the last run first
    local ordered = vim.list_slice(cur.configs)
    table.sort(ordered, function(a, b)
      return (a.name == cur.last) and (b.name ~= cur.last)
    end)
    for _, c in ipairs(ordered) do
      items[#items + 1] = { text = describe(c), cfg = c }
    end
    items[#items + 1] = { text = "+ new configuration...", new = true }
    local function reopen(fn)
      return function(picker, item)
        picker:close()
        vim.schedule(function()
          fn(item)
        end)
      end
    end
    Snacks.picker({
      title = "Run configurations (<CR> run, <C-e> edit, <C-x> delete)",
      items = items,
      format = "text",
      layout = { preset = "select" },
      confirm = function(picker, item)
        picker:close()
        if not item then
          return
        end
        if item.new then
          M.edit(root, meta, nil)
        else
          M.run(root, item.cfg, meta)
        end
      end,
      actions = {
        rr_edit = reopen(function(item)
          if item and item.cfg then
            M.edit(root, meta, item.cfg)
          end
        end),
        rr_delete = reopen(function(item)
          if item and item.cfg and M.delete(root, item.cfg.name) then
            vim.notify(("xyno-rust: deleted %q"):format(item.cfg.name))
          end
        end),
      },
      win = {
        input = { keys = { ["<C-e>"] = { "rr_edit", mode = { "i", "n" } }, ["<C-x>"] = { "rr_delete", mode = { "i", "n" } } } },
        list = { keys = { ["<C-e>"] = "rr_edit", ["<C-x>"] = "rr_delete" } },
      },
    })
  end)
end

--- Run by name, or the previous one.
---@param name? string
function M.run_named(name)
  with_workspace(function(root, meta)
    local c
    if name and name ~= "" then
      c = find(root, name)
      if not c then
        return vim.notify(("xyno-rust: no run configuration %q (see :RustRun)"):format(name), vim.log.levels.WARN)
      end
    else
      local cur = M.load(root)
      c = cur.last and find(root, cur.last)
      if not c then
        return vim.notify("xyno-rust: nothing was run yet in this project (:RustRun)", vim.log.levels.INFO)
      end
    end
    M.run(root, c, meta)
  end)
end

local function names(lead)
  local out = {}
  local ok, rc = pcall(require, "xyno_rust.rust_context")
  local root = ok and rc.root(nil, { nowait = true })
  if root then
    for _, c in ipairs(M.load(root).configs) do
      if c.name:find(lead, 1, true) == 1 then
        out[#out + 1] = c.name
      end
    end
  end
  return out
end

function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  local cmd = vim.api.nvim_create_user_command
  cmd("RustRun", function(a)
    if a.args ~= "" then
      M.run_named(a.args)
    else
      M.pick()
    end
  end, { nargs = "?", complete = function(lead) return names(lead) end, desc = "Run a saved cargo run configuration (picker)" })
  cmd("RustRunLast", function()
    M.run_named(nil)
  end, { desc = "Run the previous run configuration again" })
  cmd("RustRunEdit", function(a)
    with_workspace(function(root, meta)
      local c = a.args ~= "" and find(root, a.args)
      if a.args ~= "" and not c then
        return vim.notify(("xyno-rust: no run configuration %q"):format(a.args), vim.log.levels.WARN)
      end
      M.edit(root, meta, c or nil)
    end)
  end, { nargs = "?", complete = function(lead) return names(lead) end, desc = "Edit (or create) a run configuration" })
  cmd("RustRunDelete", function(a)
    with_workspace(function(root)
      if M.delete(root, a.args) then
        vim.notify(("xyno-rust: deleted %q"):format(a.args))
      else
        vim.notify(("xyno-rust: no run configuration %q"):format(a.args), vim.log.levels.WARN)
      end
    end)
  end, { nargs = 1, complete = function(lead) return names(lead) end, desc = "Delete a run configuration" })
end

return M
