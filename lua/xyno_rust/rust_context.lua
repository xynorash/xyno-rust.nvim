-- Per-project Cargo "context" (features / target), inspired by the Cargo tool
-- window toggles. rust-analyzer and bacon-ls (the clippy tier) must agree on
-- both, otherwise mutually exclusive features give bogus errors from one tier.
-- Stored per workspace root in stdpath("state"); applied at server start
-- (rustaceanvim `server.settings`, bacon_ls `before_init`) and live by
-- :RustContext.
--
-- ctx = { all = boolean, no_default = boolean, features = string[], target = string? }
-- Default (nothing stored): all features, host target - i.e. the old behaviour.
local M = {}

local state_file = vim.fn.stdpath("state") .. "/rust-context.json"

local function read_all()
  return require("xyno_rust.statefile").read(state_file)
end

local function mtime(path)
  local st = path and vim.uv.fs_stat(path)
  return st and (st.mtime.sec .. "." .. st.mtime.nsec) or "-"
end

--- One spelling of a root per directory (the state file is keyed by it):
--- cargo prints backslashes and sometimes a \\?\ prefix, LSP gives file URIs with
--- a lowercase drive letter. Only on Windows; elsewhere the path is untouched.
local function canon(p)
  if p and vim.fn.has("win32") == 1 then
    p = vim.fs.normalize((p:gsub("^\\\\%?\\", "")), { expand_env = false })
    p = p:gsub("^(%a):", function(d)
      return d:lower() .. ":"
    end)
  end
  return p
end

M.canon = canon

--- Workspace root (dir holding the top Cargo.toml) for a path.
---
--- This is the synchronous form, for callers that cannot take a callback (the
--- other xyno plugins). Cargo's answer (`cargo locate-project --workspace`: it knows
--- `members` and `exclude`) is cached per directory and manifest mtimes, so only the
--- first, cold call waits for cargo - at most cargo.config.wait_ms, then the
--- file-system answer is returned and the late cargo answer fills the cache. The
--- plugin warms that cache when a Rust buffer is entered (see `warm`) and its own
--- commands use `root_async`. `opts.nowait = true` never waits: the cached cargo
--- answer if there is one, else the file-system answer (and cargo is asked in
--- the background).
---@param opts? { nowait?: boolean }
function M.root(path, opts)
  return canon(M._root(path, opts))
end

--- The workspace manifest the file-system fallback picks, and what cargo would
--- be asked: { fallback = dir, dir = cwd for cargo, stamp = string } or nil outside a crate.
local function plan(path)
  path = path or vim.api.nvim_buf_get_name(0)
  local start = vim.fs.dirname(path)
  local found = vim.fs.find("Cargo.toml", { upward = true, path = start })
  if not found[1] then
    return nil
  end
  -- Fallback when cargo cannot answer (no cargo, a manifest that does not
  -- parse): walk up to the outermost Cargo.toml that declares a [workspace]
  local top
  for _, f in ipairs(vim.fs.find("Cargo.toml", { upward = true, path = start, limit = math.huge })) do
    local fh = io.open(f)
    if fh then
      local txt = fh:read("*a")
      fh:close()
      if txt:find("%[workspace") then
        top = f
      end
    end
  end
  return { fallback = vim.fs.dirname(top or found[1]), dir = start, stamp = mtime(found[1]) .. "|" .. mtime(top) }
end

function M._root(path, opts)
  local p = plan(path)
  if not p then
    return nil
  end
  local cargo = require("xyno_rust.cargo")
  local known = cargo.located(p.dir, p.stamp)
  if known ~= nil then
    return known or p.fallback
  end
  if opts and opts.nowait then
    cargo.locate_async(p.dir, p.stamp, function() end)
    return p.fallback
  end
  return cargo.locate(p.dir, p.stamp) or p.fallback
end

--- Asynchronous root(): cb(root) on a later loop iteration (nil outside a crate).
function M.root_async(path, cb)
  local p = plan(path)
  if not p then
    return vim.schedule(function()
      cb(nil)
    end)
  end
  require("xyno_rust.cargo").locate_async(p.dir, p.stamp, function(root)
    cb(canon(root or p.fallback))
  end)
end

--- Ask cargo about the workspace of every Rust buffer entered, in the background, so the
--- synchronous root() finds its answer in the cache.
function M.warm()
  local group = vim.api.nvim_create_augroup("xyno_rust_warm", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
    group = group,
    pattern = { "*.rs", "Cargo.toml", "rust" },
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name ~= "" and vim.bo[ev.buf].buftype == "" then
        M.root_async(name, function() end)
      end
    end,
  })
end

--- Feature names and target triples end up in cargo's argv (`--features a,b`, `--target t`) and in
--- rust-analyzer's settings. The state file is hand-editable and written by every nvim, so a value is
--- checked where it is read: a name starting with "-" would be taken for an option by cargo
--- (`"features": ["--config=build.rustc-wrapper=..."]`), and a comma or space splits one entry in two.
--- Cargo's own rule for feature names is XID characters plus - + . and the `dep:` / `pkg/feat` /
--- `pkg?/feat` forms; a triple is letters, digits, _ - and .
function M.valid_feature(f)
  return type(f) == "string" and #f <= 200 and f:match("^[%w_][%w_%-%+%.:/%?]*$") ~= nil
end

function M.valid_target(t)
  return type(t) == "string" and #t <= 100 and t:match("^[%w_][%w_%-%.]*$") ~= nil
end

local warned = {}

--- A hand-edited state file may hold anything (`{"features":5,"target":[]}` raised in describe()
--- and ra_cargo()): drop the fields of the wrong type and the values that are not valid feature
--- names / target triples (once-per-session warning), keep the rest as stored.
local function sanitize(ctx, root)
  if type(ctx) ~= "table" then
    return nil
  end
  local out = vim.deepcopy(ctx)
  local rejected = {}
  for _, k in ipairs({ "all", "no_default" }) do
    if type(out[k]) ~= "boolean" then
      out[k] = nil
    end
  end
  if type(out.features) == "table" then
    out.features = vim.tbl_filter(function(f)
      if M.valid_feature(f) then
        return true
      end
      if type(f) == "string" and f ~= "" then
        rejected[#rejected + 1] = f
      end
      return false
    end, vim.islist(out.features) and out.features or {})
  else
    out.features = nil
  end
  if type(out.target) == "string" and out.target ~= "" and not M.valid_target(out.target) then
    rejected[#rejected + 1] = out.target
    out.target = nil
  elseif type(out.target) ~= "string" or out.target == "" then
    out.target = nil
  end
  if #rejected > 0 and root and not warned[root] then
    warned[root] = true
    vim.schedule(function()
      vim.notify(
        ("xyno-rust: ignored invalid feature/target value(s) in the context of %s: %s"):format(
          root,
          table.concat(rejected, ", ")
        ),
        vim.log.levels.WARN
      )
    end)
  end
  return out
end

M.sanitize = sanitize

--- The feature / target strings of a stored context that sanitize() drops (for the health check).
function M.rejected(ctx)
  local out = {}
  if type(ctx) ~= "table" then
    return out
  end
  if type(ctx.features) == "table" then
    for _, f in ipairs(ctx.features) do
      if type(f) == "string" and f ~= "" and not M.valid_feature(f) then
        out[#out + 1] = f
      end
    end
  end
  if type(ctx.target) == "string" and ctx.target ~= "" and not M.valid_target(ctx.target) then
    out[#out + 1] = ctx.target
  end
  return out
end

--- All stored contexts, raw (for the health check).
function M.stored()
  return read_all()
end

function M.get(root)
  root = canon(root)
  return root and sanitize(read_all()[root], root) or nil
end

--- Settings.cargo table for rust-analyzer.
function M.ra_cargo(ctx)
  if not ctx then
    return nil
  end
  ctx = sanitize(ctx) -- (callers other than get() pass tables of their own)
  return {
    allFeatures = ctx.all == true,
    noDefaultFeatures = ctx.no_default == true,
    features = (ctx.all and {}) or ctx.features or {},
    target = ctx.target,
  }
end

--- Feature/target CLI flags of a context (nil = the defaults: all features,
--- host target), for the cargo commands the config runs itself.
function M.cargo_flags(ctx)
  ctx = ctx and sanitize(ctx)
  local f = {}
  if not ctx or ctx.all then
    f[#f + 1] = "--all-features"
  else
    if ctx.no_default then
      f[#f + 1] = "--no-default-features"
    end
    if ctx.features and #ctx.features > 0 then
      vim.list_extend(f, { "--features", table.concat(ctx.features, ",") })
    end
  end
  if ctx and ctx.target then
    vim.list_extend(f, { "--target", ctx.target })
  end
  return f
end

--- cargo extraArgs for bacon-ls (replaces the hardcoded --all-features).
function M.bacon_args(ctx)
  return vim.list_extend(vim.list_extend({ "--workspace" }, M.cargo_flags(ctx)), { "--no-deps", "--keep-going" })
end

--- Human-readable summary, e.g. "features: ssr,csr | target: wasm32-unknown-unknown".
function M.describe(ctx)
  if not ctx or (ctx.all and not ctx.target) then
    return "all features, host target"
  end
  local parts = {}
  if ctx.all then
    parts[#parts + 1] = "all features"
  else
    parts[#parts + 1] = "features: "
      .. ((ctx.features and #ctx.features > 0) and table.concat(ctx.features, ",") or "(none)")
    if ctx.no_default then
      parts[#parts + 1] = "no default"
    end
  end
  parts[#parts + 1] = "target: " .. (ctx.target or "host")
  return table.concat(parts, " | ")
end

--- Push ctx into the running rust-analyzer and restart bacon-ls with matching args.
--- `ctx == nil` resets to the defaults (all features, host target) and forgets the stored choice.
--- Whether a client serves the workspace `root`: its root_dir, or any workspace
--- folder (rustaceanvim attaches a further workspace's buffers to the ONE
--- running rust-analyzer as an added folder; its root_dir stays the first's).
local function serves(c, root)
  root = canon(root)
  local function is(dir)
    return dir ~= nil and M.root(dir .. "/x") == root
  end
  if is(c.config.root_dir) then
    return true
  end
  for _, wf in ipairs(c.workspace_folders or {}) do
    if is(wf.uri and vim.uri_to_fname(wf.uri)) then
      return true
    end
  end
  return false
end

--- Read, set one key, write, under a lock file (statefile.lua): two nvims applying at once each
--- read the old file and the later rename dropped the other's key (8 nvims x 20 applies kept 79 of 160).
local function store(root, ctx)
  root = canon(root)
  require("xyno_rust.statefile").update(state_file, function(all)
    all[root] = ctx
  end)
end

function M.apply(root, ctx)
  ctx = ctx and sanitize(ctx)
  store(root, ctx)
  local eff = ctx or { all = true, features = {} }
  for _, c in ipairs(vim.lsp.get_clients({ name = "rust-analyzer" })) do
    if serves(c, root) then
      local ra = c.settings["rust-analyzer"]
      ra.cargo = vim.tbl_extend("force", ra.cargo or {}, M.ra_cargo(eff))
      ra.cargo.target = eff.target -- nil clears it
      c:notify("workspace/didChangeConfiguration", { settings = c.settings })
    end
  end
  vim.schedule(function()
    pcall(vim.cmd.RustLsp, "reloadWorkspace")
    for _, c in ipairs(vim.lsp.get_clients({ name = "bacon_ls" })) do
      if serves(c, root) then
        vim.cmd("lsp restart bacon_ls")
        break
      end
    end
  end)
  vim.notify("Rust context: " .. M.describe(eff))
end

--- Interactive picker: features (multi-select with <Tab>), then target. Nothing blocks: cargo
--- metadata (cached) and `rustup target list` (cached) are asked in the background.
function M.pick()
  M.root_async(nil, function(root)
    if not root then
      return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
    end
    require("xyno_rust.cargo").metadata_async(root, function(meta, err)
      if not meta then
        return vim.notify("cargo metadata failed: " .. tostring(err), vim.log.levels.ERROR)
      end
      M._pick_features(root, meta)
    end)
  end)
end

function M._pick_features(root, meta)
  local cur = M.get(root) or { all = true }
  local items = {
    { text = "* all features", special = "all" },
    { text = "* default features only (clears the list)", special = "default" },
    { text = "* no-default-features", special = "nodefault" },
  }
  local multi = #meta.packages > 1
  for _, p in ipairs(meta.packages) do
    local names = vim.tbl_keys(p.features)
    table.sort(names)
    for _, f in ipairs(names) do
      if f ~= "default" then
        local q = multi and (p.name .. "/" .. f) or f
        if M.valid_feature(q) then
          items[#items + 1] = { text = q, feature = q }
        end
      end
    end
  end
  local Snacks = require("xyno_rust.deps").snacks()
  if not Snacks then
    return
  end
  Snacks.picker({
    title = "Cargo features (<Tab> multi-select) - now: " .. M.describe(cur),
    items = items,
    format = "text",
    layout = { preset = "select" },
    confirm = function(picker)
      local sel = picker:selected({ fallback = true })
      picker:close()
      local ctx = { all = false, no_default = false, features = {}, target = cur.target }
      for _, it in ipairs(sel) do
        if it.special == "all" then
          ctx.all = true
        elseif it.special == "nodefault" then
          ctx.no_default = true
        elseif it.feature then
          ctx.features[#ctx.features + 1] = it.feature
        end
      end
      require("xyno_rust.cargo").installed_targets_async(function(installed, terr)
        local targets = { "(host default)" }
        for _, t in ipairs(installed or {}) do
          if M.valid_target(t) then
            targets[#targets + 1] = t
          end
        end
        if terr then
          vim.notify("xyno-rust: rustup targets unavailable: " .. terr, vim.log.levels.WARN)
        end
        vim.ui.select(targets, { prompt = "Target (currently " .. (cur.target or "host") .. ")" }, function(choice)
          if choice then
            ctx.target = choice ~= "(host default)" and choice or nil
            M.apply(root, ctx)
          end
        end)
      end)
    end,
  })
end

function M.reset()
  M.root_async(nil, function(root)
    if not root then
      return vim.notify("no Cargo.toml found: nothing to reset", vim.log.levels.WARN)
    end
    M.apply(root, nil)
  end)
end

--- opts.commands = false: do not define :RustContext.
function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  vim.api.nvim_create_user_command("RustContext", function(a)
    if a.args == "reset" then
      M.reset()
    elseif a.args == "show" then
      M.root_async(nil, function(root)
        if not root then
          return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
        end
        vim.notify("Rust context: " .. M.describe(M.get(root)))
      end)
    elseif a.args ~= "" then
      vim.notify(
        "RustContext: unknown argument '" .. a.args .. "' (use show or reset, or no argument for the picker)",
        vim.log.levels.WARN
      )
    else
      M.pick()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "show", "reset" }
    end,
    desc = "Pick cargo features / target for rust-analyzer + bacon-ls",
  })
end

return M
