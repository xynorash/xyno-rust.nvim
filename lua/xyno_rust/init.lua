-- xyno-rust.nvim: Rust project plumbing. setup() wires the modules together;
-- every module can also be required on its own (xyno_rust.rust_context, ...).
local M = {}

--- The contract other xyno plugins (xyno-new, xyno-imports, xyno-crates, xyno-macros) code against,
--- as "major.minor". The major number changes when a module function they call is removed or changes
--- meaning; the minor number when functions are added. `M.version` is the plugin release.
---   1.0  the modules as they were extracted from xynovim
---   1.2  run_configs.lua (:RustRun and friends), action_menu.lua (:RustActions, :RustRefactor, :RustFixAll);
---        nothing older changed
---   1.1  async cargo layer (cargo.lua), trust.lua, rust_context.root_async / root(path, { nowait }),
---        rust_routes.collect_async; every older function keeps its signature and result
M.api_version = "1.3"
M.version = "0.3.0"

--- Whether this plugin satisfies a dependent's needs: `compatible("1.1")` is true for any 1.x with x >= 1.
--- Returns false plus a one-line reason otherwise (a dependent prints it instead of failing later).
---@param want string "major.minor"
---@return boolean ok, string? why
function M.compatible(want)
  local wmaj, wmin = tostring(want):match("^(%d+)%.(%d+)$")
  if not wmaj then
    return false, ("xyno-rust: unreadable api version %q (want \"major.minor\")"):format(tostring(want))
  end
  local maj, min = M.api_version:match("^(%d+)%.(%d+)$")
  if tonumber(wmaj) ~= tonumber(maj) then
    return false, ("xyno-rust api %s is installed, API %s was asked for (another major version)"):format(M.api_version, want)
  end
  if tonumber(wmin) > tonumber(min) then
    return false, ("xyno-rust api %s is installed, %s or newer is needed: update xyno-rust.nvim"):format(M.api_version, want)
  end
  return true
end

M.defaults = {
  commands = true, -- :RustContext :RustTargets :RustTools :ActJob :RustNew :RustRoutes :RustRestart :RustTrust
  keymaps = false, -- false | true | { context = lhs, targets = lhs, ... } (buffer-local in Rust files)
  modules = {
    context = true, -- xyno_rust.rust_context: per-project features / target
    tasks = true, -- xyno_rust.rust_tasks: targets, tools, :RustNew, :ActJob
    routes = true, -- xyno_rust.rust_routes: HTTP route picker
    status = true, -- xyno_rust.lsp_status: readiness indicator (event driven)
    restart = true, -- xyno_rust.rust_restart: server supervision
    runs = true, -- xyno_rust.run_configs: :RustRun, :RustRunLast, :RustRunEdit, :RustRunDelete (saved per project)
    actions = true, -- xyno_rust.action_menu: :RustActions, :RustRefactor (diff preview), :RustFixAll
    profile = true, -- xyno_rust.profiler: :RustProfile (in-editor hot functions / call tree)
    tokio = true, -- xyno_rust.tokio: :TokioConsole (project check, launch), the async debugging hint
    trust = true, -- xyno_rust.trust: :RustTrust (the trust API works without it; this only defines the command)
  },
  tools = {}, -- :RustTools list: { hide = { "audit", ... }, extra = { { text = "...", cmd = { "cargo", ... }, flags = false } } }
}

--- Default keys of `keymaps = true`. An entry set to false in a table is skipped.
M.default_keymaps = {
  context = "<leader>rF",
  targets = "<leader>rX",
  tools = "<leader>rZ",
  routes = "<leader>rN",
  goto_super = "<leader>ru",
  local_usages = "<leader>rl",
  doctests = "<leader>tD",
}

local ACTIONS = {
  context = { "<cmd>RustContext<cr>", "Cargo features / target" },
  targets = { "<cmd>RustTargets<cr>", "Cargo targets: run / test / bench" },
  tools = { "<cmd>RustTools<cr>", "Cargo tools (deny, audit, bloat, timings, ...)" },
  routes = { "<cmd>RustRoutes<cr>", "HTTP routes (axum / actix / rocket)" },
  goto_super = {
    function()
      require("xyno_rust.rust_nav").goto_super()
    end,
    "Go to super method (trait item)",
  },
  local_usages = {
    function()
      require("xyno_rust.rust_nav").local_usages()
    end,
    "Usages in file (R/W)",
  },
  doctests = {
    function()
      require("xyno_rust.rust_tasks").doctests()
    end,
    "Doctests (cargo test --doc)",
  },
}

local function map_keys(keymaps)
  local keys = keymaps == true and M.default_keymaps or keymaps
  local group = vim.api.nvim_create_augroup("xyno_rust_keymaps", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "rust",
    callback = function(ev)
      for name, lhs in pairs(keys) do
        local action = ACTIONS[name]
        if action and type(lhs) == "string" then
          vim.keymap.set("n", lhs, action[1], { buffer = ev.buf, desc = action[2] })
        end
      end
    end,
  })
  -- a Rust buffer that is already open
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "rust" then
      vim.api.nvim_exec_autocmds("FileType", { group = group, buffer = buf })
    end
  end
end

--- Configure and start the plugin. Safe to call again (autocmd groups are cleared and redefined).
---@param opts? { commands?: boolean, keymaps?: boolean|table<string, string|false>, modules?: table<string, boolean>, tools?: { hide?: string[], extra?: table[] } }
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify("xyno-rust: Neovim 0.12 or newer is required", vim.log.levels.ERROR)
    return
  end
  local problems = {}
  if type(opts.commands) ~= "boolean" then
    problems[#problems + 1] = "commands must be a boolean"
    opts.commands = true
  end
  if opts.keymaps ~= false and opts.keymaps ~= true and type(opts.keymaps) ~= "table" then
    problems[#problems + 1] = "keymaps must be false, true or a table"
    opts.keymaps = false
  end
  if type(opts.modules) ~= "table" then
    problems[#problems + 1] = "modules must be a table"
    opts.modules = vim.deepcopy(M.defaults.modules)
  else
    for k, v in pairs(opts.modules) do
      if M.defaults.modules[k] == nil then
        problems[#problems + 1] = ("unknown module `%s`"):format(tostring(k))
        opts.modules[k] = nil
      elseif type(v) ~= "boolean" then
        problems[#problems + 1] = ("module `%s` must be a boolean"):format(k)
        opts.modules[k] = M.defaults.modules[k]
      end
    end
  end
  local tasks = require("xyno_rust.rust_tasks")
  local tp = tasks.validate_tools(opts.tools)
  if #tp == 0 then
    tasks.set_tools(opts.tools)
  else
    vim.list_extend(problems, tp)
    tasks.set_tools({}) -- the default list stays
  end
  if #problems > 0 then
    vim.notify("xyno-rust: invalid options ignored:\n  " .. table.concat(problems, "\n  "), vim.log.levels.WARN)
  end
  require("xyno_rust.ui").setup()
  local sub = { commands = opts.commands }
  local m = opts.modules
  if m.context then
    require("xyno_rust.rust_context").setup(sub)
    require("xyno_rust.rust_context").warm()
  end
  if m.trust then
    require("xyno_rust.trust").setup(sub)
  end
  if m.tasks then
    require("xyno_rust.rust_tasks").setup(sub)
  end
  if m.actions then
    require("xyno_rust.action_menu").setup(sub)
  end
  if m.runs then
    require("xyno_rust.run_configs").setup(sub)
  end
  if m.profile then
    require("xyno_rust.profiler").setup(sub)
  end
  if m.tokio then
    require("xyno_rust.tokio").setup(sub)
  end
  if m.routes then
    require("xyno_rust.rust_routes").setup(sub)
  end
  if m.status then
    require("xyno_rust.lsp_status").setup()
  end
  if m.restart then
    require("xyno_rust.rust_restart").setup(sub)
  end
  if opts.keymaps then
    map_keys(opts.keymaps)
  end
end

return M
