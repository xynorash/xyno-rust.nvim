-- xyno-rust.nvim: Rust project plumbing. setup() wires the modules together;
-- every module can also be required on its own (xyno_rust.rust_context, ...).
local M = {}

M.defaults = {
  commands = true, -- :RustContext :RustTargets :RustTools :ActJob :RustNew :RustRoutes :RustRestart
  keymaps = false, -- false | true | { context = lhs, targets = lhs, ... } (buffer-local in Rust files)
  modules = {
    context = true, -- xyno_rust.rust_context: per-project features / target
    tasks = true, -- xyno_rust.rust_tasks: targets, tools, :RustNew, :ActJob
    routes = true, -- xyno_rust.rust_routes: HTTP route picker
    status = true, -- xyno_rust.lsp_status: readiness indicator (event driven)
    restart = true, -- xyno_rust.rust_restart: server supervision
  },
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
---@param opts? { commands?: boolean, keymaps?: boolean|table<string, string|false>, modules?: table<string, boolean> }
function M.setup(opts)
  opts = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if vim.fn.has("nvim-0.12") ~= 1 then
    vim.notify("xyno-rust: Neovim 0.12 or newer is required", vim.log.levels.ERROR)
    return
  end
  local sub = { commands = opts.commands }
  local m = opts.modules
  if m.context then
    require("xyno_rust.rust_context").setup(sub)
  end
  if m.tasks then
    require("xyno_rust.rust_tasks").setup(sub)
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
