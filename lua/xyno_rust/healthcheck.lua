-- The checks behind :checkhealth xyno-rust.
local M = {}

local health = vim.health

local function run(argv, ms)
  local ok, o = pcall(function()
    return vim.system(argv, { text = true }):wait(ms or 5000)
  end)
  if not ok or not o or o.code ~= 0 then
    return nil
  end
  return vim.trim(o.stdout or "")
end

local function exe(name, opts)
  opts = opts or {}
  if vim.fn.executable(name) ~= 1 then
    if opts.required then
      health.error(name .. " not found", opts.advice)
    else
      health.warn(name .. " not found (" .. (opts.used_by or "optional") .. ")", opts.advice)
    end
    return false
  end
  local v = opts.version and run(opts.version)
  health.ok(name .. (v and (": " .. v:gsub("\n.*", "")) or ""))
  return true
end

local function section_plugin()
  health.start("xyno-rust: plugin")
  local x = require("xyno_rust")
  health.ok(("version %s, api_version %s"):format(x.version, x.api_version))
  if vim.fn.has("nvim-0.12") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.12 or newer is required", "update Neovim")
  end
  local dependents = { "xyno_new", "xyno_imports", "xyno_crates", "xyno_macros" }
  local found = {}
  for _, d in ipairs(dependents) do
    if #vim.api.nvim_get_runtime_file("lua/" .. d .. "/init.lua", false) > 0 then
      found[#found + 1] = d:gsub("_", "-") .. ".nvim"
    end
  end
  health.info("dependents on the runtimepath: " .. (#found > 0 and table.concat(found, ", ") or "none"))
  for _, f in ipairs({ "crate_meta", "code_actions", "fsutil", "rust_context", "rust_restart" }) do
    local ok, err = pcall(require, "xyno_rust." .. f)
    if not ok then
      health.error("module xyno_rust." .. f .. " does not load: " .. tostring(err))
    end
  end
end

local function section_tools()
  health.start("xyno-rust: tools")
  exe(
    "cargo",
    { required = true, version = { "cargo", "--version" }, advice = { "install a Rust toolchain: https://rustup.rs" } }
  )
  exe("rustup", { used_by = "the :RustContext target list", version = { "rustup", "--version" } })
  exe(
    "rust-analyzer",
    { used_by = "language server; rustaceanvim can also use its own", version = { "rust-analyzer", "--version" } }
  )
  exe("bacon-ls", { used_by = "clippy tier of the diagnostics" })
  for _, t in ipairs({
    { "samply", ":RustTargets samply item" },
    { "cargo-flamegraph", ":RustTargets flamegraph item" },
    { "act", ":ActJob" },
    { "cargo-deny", ":RustTools deny" },
    { "cargo-audit", ":RustTools audit" },
    { "cargo-machete", ":RustTools unused dependencies" },
    { "cargo-bloat", ":RustTools bloat" },
    { "cargo-llvm-cov", ":RustTools coverage" },
  }) do
    exe(t[1], { used_by = t[2] })
  end
  local snacks = rawget(_G, "Snacks")
  if type(snacks) == "table" and snacks.picker then
    health.ok("snacks.nvim (pickers, terminals)")
  elseif pcall(require, "snacks") then
    health.ok("snacks.nvim (pickers, terminals)")
  else
    health.warn("snacks.nvim not found: the pickers and terminals need it (folke/snacks.nvim)")
  end
  if pcall(vim.treesitter.language.add, "rust") then
    health.ok("tree-sitter rust parser (:RustRoutes)")
  else
    health.warn("tree-sitter rust parser missing: :RustRoutes finds nothing", { "install it, e.g. :TSInstall rust" })
  end
end

local function section_state()
  health.start("xyno-rust: state")
  local dir = vim.fn.stdpath("state")
  local probe = dir .. "/.xyno-rust-health"
  vim.fn.mkdir(dir, "p")
  local f = io.open(probe, "w")
  if f then
    f:close()
    os.remove(probe)
    health.ok("state directory is writable: " .. dir)
  else
    health.error("state directory is not writable: " .. dir, "the Rust context and the trust list cannot be remembered")
  end
  local rc = require("xyno_rust.rust_context")
  local stored = rc.stored()
  local n, bad = 0, 0
  for root, ctx in pairs(stored) do
    n = n + 1
    local rej = rc.rejected(ctx)
    if #rej > 0 then
      bad = bad + 1
      health.warn(
        ("rust-context.json: %s holds invalid values that are ignored: %s"):format(root, table.concat(rej, ", ")),
        "run :RustContext reset in that workspace or edit the file"
      )
    end
  end
  health.ok(
    ("rust-context.json: %d workspace(s) with a stored context%s"):format(
      n,
      bad > 0 and (", " .. bad .. " with invalid values") or ""
    )
  )
end

-- (the health buffer is the current one: look at the working directory)
local function here()
  return vim.uv.cwd() .. "/x"
end

local function section_trust()
  health.start("xyno-rust: workspace trust")
  local trust = require("xyno_rust.trust")
  local list = trust.list()
  health.info(("trust file: %s (%d entr%s)"):format(trust.file(), #list, #list == 1 and "y" or "ies"))
  for _, e in ipairs(list) do
    health.info("  trusted: " .. e.root .. (e.recursive and "/**" or ""))
    if not vim.uv.fs_stat(e.root) then
      health.warn("  trusted directory no longer exists: " .. e.root, ":RustTrust revoke " .. e.root)
    end
  end
  local root = require("xyno_rust.rust_context").root(here(), { nowait = true })
  if root then
    if trust.is_trusted(root) then
      health.ok("current workspace is trusted: " .. root)
    else
      health.warn(
        "current workspace is NOT trusted: " .. root .. " (running targets/tools asks first)",
        ":RustTrust add"
      )
    end
  end
end

local function section_workspace()
  health.start("xyno-rust: current workspace")
  local rc = require("xyno_rust.rust_context")
  local root = rc.root(here())
  if not root then
    return health.info("no Cargo.toml above the current buffer")
  end
  health.ok("root: " .. root)
  local cargo = require("xyno_rust.cargo")
  local t0 = vim.uv.hrtime()
  local meta, err = cargo.metadata(root, { refresh = true })
  local ms = (vim.uv.hrtime() - t0) / 1e6
  if meta then
    health.ok(("cargo metadata --no-deps: %d package(s), %.0f ms"):format(#meta.packages, ms))
    if ms > 2000 then
      health.warn(
        "cargo metadata is slow here; it runs in the background but the targets picker waits for it",
        "rust-toolchain.toml with a toolchain that is not installed makes cargo download it"
      )
    end
  else
    health.error("cargo metadata failed: " .. tostring(err))
  end
  health.info("stored context: " .. rc.describe(rc.get(root)))
  local clients = {}
  for _, name in ipairs({ "rust-analyzer", "bacon_ls" }) do
    for _, c in ipairs(vim.lsp.get_clients({ name = name })) do
      clients[#clients + 1] = ("%s (%s)"):format(name, c.initialized and "initialized" or "starting")
    end
  end
  health.info("language servers: " .. (#clients > 0 and table.concat(clients, ", ") or "none running"))
  health.info(
    ("background requests: %d running; statusline state for %d client(s)"):format(
      cargo.pending(),
      require("xyno_rust.lsp_status")._state_size()
    )
  )
end

function M.check()
  section_plugin()
  section_tools()
  section_state()
  section_trust()
  section_workspace()
end

return M
