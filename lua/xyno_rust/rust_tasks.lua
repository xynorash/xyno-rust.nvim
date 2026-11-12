-- Cargo targets picker (inspired by the Cargo tool window / run configurations of the JetBrains IDEs,
-- minimal) and a project scaffold command. Honors the :RustContext choice.
local M = {}

--- `<build argv> && samply record <bin>`: through sh on POSIX, through cmd.exe on
--- Windows (where sh may be missing and vim.fn.shellescape quotes for the 'shell' option).
function M.samply_cmd(build, bin)
  if vim.fn.has("win32") == 1 then
    local function q(s)
      return '"' .. s:gsub('"', '""') .. '"'
    end
    return { "cmd", "/s", "/c", '"' .. table.concat(vim.tbl_map(q, build), " ") .. " && samply record " .. q(bin) .. '"' }
  end
  return { "sh", "-c", table.concat(vim.tbl_map(vim.fn.shellescape, build), " ") .. " && samply record " .. vim.fn.shellescape(bin) }
end

local rc = require("xyno_rust.rust_context")

--- `profiling` = release + debug symbols, defined on the command line so a project (or ~/.cargo/config.toml)
--- needs no `[profile.profiling]` of its own (run_configs.lua has the same constant).
local PROFILING_FLAGS = require("xyno_rust.run_configs").PROFILING_FLAGS

local TOOL_HINT = {
  samply = "samply is not installed (cargo install samply)",
  ["cargo-flamegraph"] = "cargo-flamegraph is not installed (cargo install flamegraph)",
}

--- Run in a bottom terminal that stays open after exit 0 (Snacks closes it
--- by default and the output is gone). A rerun replaces the previous one:
--- Snacks.terminal would just toggle the finished window.
local last_term
local function open_term(cmd, root)
  local Snacks = require("xyno_rust.deps").snacks()
  if not Snacks then
    return
  end
  local old = Snacks.terminal.get(cmd, { cwd = root, create = false })
  if old then
    old:close({ buf = true })
  end
  -- a DIFFERENT command used to open one more split each time (only an
  -- identical command was found above): the previous run's terminal goes too
  if last_term and last_term ~= old and last_term.buf_valid and last_term:buf_valid() then
    pcall(last_term.close, last_term, { buf = true })
  end
  last_term = Snacks.terminal.open(cmd, { cwd = root, auto_close = false, win = { position = "bottom" } })
end

--- Every command this module runs executes code that comes with the workspace (build.rs, proc
--- macros, tests, workflow steps): ask once per workspace root (trust.lua) before running it.
---@param what string short description for the prompt
local function term(cmd, root, what)
  require("xyno_rust.trust").require(root, what or table.concat(cmd, " "), function(ok)
    if ok then
      open_term(cmd, root)
    end
  end)
end

--- Feature/target flags of the context (the default is --all-features).
local function ctx_flags(root)
  return rc.cargo_flags(rc.get(root))
end

--- cargo-flamegraph has no --all-features: spell the package's features out.
local function flamegraph_flags(root, pkg)
  local flags = ctx_flags(root)
  local i = vim.fn.index(flags, "--all-features")
  if i >= 0 then
    table.remove(flags, i + 1)
    local names = vim.tbl_filter(function(n)
      return n ~= "default"
    end, vim.tbl_keys(pkg.features))
    table.sort(names)
    if #names > 0 then
      vim.list_extend(flags, { "--features", table.concat(names, ",") })
    end
  end
  return flags
end

-- target kind -> { label, cargo subcommand words, target selector flag }
local ACTIONS = {
  bin = { { "run", "run", "--bin" }, { "test", "test", "--bin" }, { "build", "build", "--bin" } },
  example = { { "run", "run", "--example" }, { "build", "build", "--example" } },
  test = { { "test", "test", "--test" } },
  bench = { { "bench", "bench", "--bench" } },
  lib = { { "test", "test", "--lib" }, { "doc-test", "test", "--doc" }, { "build", "build", "--lib" } },
}

--- The picker items of a workspace's `cargo metadata --no-deps`.
function M.target_items(root, meta)
  local items = {}
  local ctx = rc.get(root)
  local win = vim.fn.has("win32") == 1
  for _, p in ipairs(meta.packages) do
    for _, t in ipairs(p.targets) do
      local kind = t.kind[1]
      kind = (kind == "proc-macro" or kind == "rlib" or kind == "cdylib" or kind == "staticlib" or kind == "dylib") and "lib" or kind
      -- `--target T` puts the artefacts in target/T/<profile>/, the context's target is part of the path
      local triple = ctx and ctx.target
      if kind == "bin" and not (triple and triple:find("^wasm")) then
        -- `profiling` profile = release + debug symbols (~/.cargo/config.toml)
        local bin = ("%s/%sprofiling/%s"):format(meta.target_directory, triple and (triple .. "/") or "", t.name)
        if win or (triple and triple:find("windows")) then
          bin = bin .. ".exe"
        end
        local build = { "cargo", "build", "--profile", "profiling" }
        vim.list_extend(build, PROFILING_FLAGS)
        vim.list_extend(build, { "-p", p.name, "--bin", t.name })
        vim.list_extend(build, ctx_flags(root))
        items[#items + 1] = {
          text = ("samply  bin %s (%s)"):format(t.name, p.name),
          cmd = M.samply_cmd(build, bin),
          tool = "samply",
        }
      end
      if kind == "bin" then
        items[#items + 1] = {
          text = ("flamegraph  bin %s (%s)"):format(t.name, p.name),
          cmd = vim.list_extend(
            vim.list_extend({ "cargo", "flamegraph", "--profile", "profiling" }, vim.list_extend(vim.deepcopy(PROFILING_FLAGS), { "-p", p.name, "--bin", t.name })),
            flamegraph_flags(root, p)
          ),
          tool = "cargo-flamegraph",
        }
      end
      for _, a in ipairs(ACTIONS[kind] or {}) do
        local cmd = { "cargo", a[2], "-p", p.name }
        if kind == "lib" then
          cmd[#cmd + 1] = a[3]
        else
          vim.list_extend(cmd, { a[3], t.name })
        end
        vim.list_extend(cmd, ctx_flags(root))
        items[#items + 1] = {
          text = ("%s  %s %s (%s)"):format(a[1], kind, t.name, p.name),
          cmd = cmd,
        }
      end
    end
  end
  return items
end

function M.targets()
  rc.root_async(nil, function(root)
    if not root then
      return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
    end
    require("xyno_rust.cargo").metadata_async(root, function(meta, err)
      if not meta then
        return vim.notify("cargo metadata failed: " .. tostring(err), vim.log.levels.ERROR)
      end
      local Snacks = require("xyno_rust.deps").snacks()
      if not Snacks then
        return
      end
      Snacks.picker({
        title = "Cargo targets - " .. rc.describe(rc.get(root)),
        items = M.target_items(root, meta),
        format = "text",
        layout = { preset = "select" },
        confirm = function(picker, item)
          picker:close()
          if item and item.tool and vim.fn.executable(item.tool) ~= 1 then
            vim.notify("xyno-rust: " .. TOOL_HINT[item.tool], vim.log.levels.ERROR)
          elseif item then
            term(item.cmd, root, item.text)
          end
        end,
      })
    end)
  end)
end

--- :RustNew [name]: cargo new (bin or lib) in the current directory and open it.
function M.new(name)
  local function create(n, kind)
    local args = { "cargo", "new", n }
    if kind == "lib" then
      table.insert(args, "--lib")
    end
    local cwd = vim.uv.cwd()
    require("xyno_rust.cargo").exec(args, { cwd = cwd, timeout = 30000 }, function(o)
      if o.code ~= 0 then
        return vim.notify(o.stderr, vim.log.levels.ERROR)
      end
      local dir = cwd .. "/" .. n
      vim.cmd.edit(dir .. "/src/" .. (kind == "lib" and "lib.rs" or "main.rs"))
      vim.notify("created " .. dir)
    end)
  end
  local function with_name(n)
    if not n or n == "" then
      return
    end
    if n:sub(1, 1) == "-" then -- cargo would take it as an option
      return vim.notify("crate name cannot start with '-': " .. n, vim.log.levels.ERROR)
    end
    vim.ui.select({ "bin", "lib" }, { prompt = "Crate type" }, function(kind)
      if kind then
        create(n, kind)
      end
    end)
  end
  if name and name ~= "" then
    with_name(name)
  else
    vim.ui.input({ prompt = "New crate name: " }, with_name)
  end
end

-- Workspace-wide tools (supply chain, size, build time). `flags` = builds the workspace, so the
-- stored features / target are appended. `id` is what setup{ tools = { hide = {...} } } names.
M.default_tools = {
  { id = "timings", text = "timings (cargo build --timings; report in target/cargo-timings)", cmd = { "cargo", "build", "--timings" }, flags = true },
  { id = "bloat_crates", text = "bloat by crate (release)", cmd = { "cargo", "bloat", "--release", "--crates" }, flags = true },
  { id = "bloat_functions", text = "bloat by function (release, top 30)", cmd = { "cargo", "bloat", "--release", "-n", "30" }, flags = true },
  { id = "machete", text = "unused dependencies (cargo machete)", cmd = { "cargo", "machete" } },
  { id = "deny_fetch", text = "deny: fetch advisory DB", cmd = { "cargo", "deny", "fetch" } },
  { id = "deny_check", text = "deny: check all", cmd = { "cargo", "deny", "check" } },
  { id = "audit", text = "audit (RustSec)", cmd = { "cargo", "audit" } },
  { id = "tree_dups", text = "duplicate dependency versions", cmd = { "cargo", "tree", "-d" } },
  { id = "llvm_cov", text = "coverage report (summary in terminal)", cmd = { "cargo", "llvm-cov", "--workspace", "--ignore-run-fail", "--summary-only" }, flags = true },
}

local tools_cfg = { hide = {}, extra = {} }

--- Check setup{ tools = { hide = { id, ... }, extra = { { text, cmd, flags? }, ... } } }.
--- Returns the problems; nothing is applied when there is one.
---@return string[]
function M.validate_tools(t)
  if type(t) ~= "table" then
    return { "tools must be a table" }
  end
  local problems = {}
  local ids = {}
  for _, d in ipairs(M.default_tools) do
    ids[d.id] = true
  end
  for k in pairs(t) do
    if k ~= "hide" and k ~= "extra" then
      problems[#problems + 1] = ("unknown tools option `%s`"):format(tostring(k))
    end
  end
  if t.hide ~= nil then
    if type(t.hide) ~= "table" or (next(t.hide) ~= nil and not vim.islist(t.hide)) then
      problems[#problems + 1] = "tools.hide must be a list of tool ids"
    else
      for _, id in ipairs(t.hide) do
        if not ids[id] then
          problems[#problems + 1] = ("tools.hide: unknown tool `%s` (known: %s)"):format(tostring(id), table.concat(vim.tbl_map(function(d) return d.id end, M.default_tools), ", "))
        end
      end
    end
  end
  if t.extra ~= nil then
    if type(t.extra) ~= "table" or (next(t.extra) ~= nil and not vim.islist(t.extra)) then
      problems[#problems + 1] = "tools.extra must be a list of { text, cmd, flags? }"
    else
      for i, e in ipairs(t.extra) do
        local p = ("tools.extra[%d]"):format(i)
        if type(e) ~= "table" then
          problems[#problems + 1] = p .. " must be a table"
        else
          for k in pairs(e) do
            if k ~= "text" and k ~= "cmd" and k ~= "flags" then
              problems[#problems + 1] = ("%s: unknown key `%s`"):format(p, tostring(k))
            end
          end
          if type(e.text) ~= "string" or e.text == "" or e.text:find("[\n\r]") then
            problems[#problems + 1] = p .. ".text must be a one-line string"
          end
          if e.flags ~= nil and type(e.flags) ~= "boolean" then
            problems[#problems + 1] = p .. ".flags must be a boolean"
          end
          if type(e.cmd) ~= "table" or not vim.islist(e.cmd) or #e.cmd == 0 then
            problems[#problems + 1] = p .. ".cmd must be a non-empty argv list (no shell string)"
          else
            for _, a in ipairs(e.cmd) do
              if type(a) ~= "string" or a == "" or a:find("%z") then
                problems[#problems + 1] = p .. ".cmd entries must be non-empty strings"
                break
              end
            end
          end
        end
      end
    end
  end
  return problems
end

--- Apply validated options (replaces the earlier ones; {} restores the defaults).
function M.set_tools(t)
  t = t or {}
  tools_cfg = { hide = {}, extra = {} }
  for _, id in ipairs(t.hide or {}) do
    tools_cfg.hide[id] = true
  end
  tools_cfg.extra = vim.deepcopy(t.extra or {})
end

--- The tools :RustTools lists: the defaults minus the hidden ones, then the extra ones.
function M.tool_list()
  local out = {}
  for _, d in ipairs(M.default_tools) do
    if not tools_cfg.hide[d.id] then
      out[#out + 1] = d
    end
  end
  for _, e in ipairs(tools_cfg.extra) do
    out[#out + 1] = e
  end
  return out
end

local function has_deny_config(root)
  for _, f in ipairs({ "deny.toml", ".deny.toml", ".cargo/deny.toml" }) do
    if vim.uv.fs_stat(root .. "/" .. f) then
      return true
    end
  end
  return false
end

function M.tools()
  rc.root_async(nil, function(root)
    if not root then
      return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
    end
    local items = vim.tbl_map(function(t)
      local cmd = t.cmd
      if t.flags then -- builds the workspace: same features/target as the diagnostics
        cmd = vim.list_extend(vim.deepcopy(cmd), ctx_flags(root))
      end
      -- no deny.toml: every dependency fails the (empty) licence allow list
      if t.id == "deny_check" and not has_deny_config(root) then
        return { text = t.text .. " (no deny.toml: licenses skipped)", cmd = { "cargo", "deny", "check", "advisories", "bans", "sources" } }
      end
      return { text = t.text, cmd = cmd }
    end, M.tool_list())
    local Snacks = require("xyno_rust.deps").snacks()
    if not Snacks then
      return
    end
    Snacks.picker({
      title = "Cargo tools",
      items = items,
      format = "text",
      layout = { preset = "select" },
      confirm = function(picker, item)
        picker:close()
        if item then
          term(item.cmd, root, item.text)
        end
      end,
    })
  end)
end

--- :ActJob - run the GitHub Actions job under the cursor locally with `act`.
function M.act_job()
  local file = vim.api.nvim_buf_get_name(0)
  local node = vim.treesitter.get_node()
  local job
  while node do
    if node:type() == "block_mapping_pair" then
      local pair_parent = node:parent() and node:parent():parent()
      local grand = pair_parent and pair_parent:parent()
      local gkey = grand and grand:type() == "block_mapping_pair" and grand:field("key")[1]
      if gkey and vim.treesitter.get_node_text(gkey, 0) == "jobs" then
        job = vim.treesitter.get_node_text(node:field("key")[1], 0)
        break
      end
    end
    node = node:parent()
  end
  if not job then
    return vim.notify("cursor is not inside a job under `jobs:`", vim.log.levels.WARN)
  end
  local root = vim.fs.root(file, ".git") or vim.uv.cwd()
  term({ "act", "-j", job, "-W", file }, root, "act job " .. job)
end

--- <leader>tD: neotest (nextest) cannot run doctests.
function M.doctests()
  rc.root_async(nil, function(root)
    if not root then
      return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
    end
    term(vim.list_extend({ "cargo", "test", "--doc", "--workspace" }, ctx_flags(root)), root, "cargo test --doc")
  end)
end

--- opts.commands = false: do not define :RustTargets, :RustTools, :ActJob, :RustNew.
function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  vim.api.nvim_create_user_command("RustTargets", M.targets, { desc = "Run/test/bench a cargo target" })
  vim.api.nvim_create_user_command("RustTools", M.tools, { desc = "Cargo tools: deny, audit, bloat, timings, ..." })
  vim.api.nvim_create_user_command("ActJob", M.act_job, { desc = "Run the GitHub Actions job under the cursor with act" })
  vim.api.nvim_create_user_command("RustNew", function(a)
    M.new(a.args)
  end, { nargs = "?", desc = "cargo new in the current directory" })
end

return M
