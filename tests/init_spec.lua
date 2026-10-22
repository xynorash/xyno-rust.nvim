-- xyno_rust.setup(): commands, module switches, keymaps and the missing-plugin messages.
local H = require("xyno_rust_test.helpers")
local rust = require("xyno_rust")

local COMMANDS = { "RustContext", "RustTargets", "RustTools", "ActJob", "RustNew", "RustRoutes", "RustRestart" }

local function clear_commands()
  for _, c in ipairs(COMMANDS) do
    pcall(vim.api.nvim_del_user_command, c)
  end
end

local function buf_map(buf, lhs)
  return vim.api.nvim_buf_call(buf, function()
    return vim.fn.maparg(lhs, "n", false, true)
  end)
end

local function rust_buf()
  local dir = H.tmpdir()
  vim.fn.writefile({ "fn main() {}" }, dir .. "/a.rs")
  vim.cmd.edit(vim.fn.fnameescape(dir .. "/a.rs"))
  vim.bo.filetype = "rust"
  return vim.api.nvim_get_current_buf()
end

describe("setup", function()
  before_each(clear_commands)
  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "xyno_rust_keymaps")
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("defines every documented command", function()
    rust.setup()
    for _, c in ipairs(COMMANDS) do
      H.eq(2, vim.fn.exists(":" .. c), c)
    end
  end)

  it("defines no command with commands = false, and sets no key by default", function()
    rust.setup({ commands = false })
    for _, c in ipairs(COMMANDS) do
      H.eq(0, vim.fn.exists(":" .. c), c)
    end
    rust.setup({ commands = false, keymaps = false })
    H.eq(false, pcall(vim.api.nvim_get_autocmds, { group = "xyno_rust_keymaps" }))
  end)

  it("modules = { x = false } leaves that module out", function()
    rust.setup({ modules = { routes = false, restart = false } })
    H.eq(0, vim.fn.exists(":RustRoutes"))
    H.eq(0, vim.fn.exists(":RustRestart"))
    H.eq(2, vim.fn.exists(":RustContext"))
  end)

  it("registers the autocmd groups of the status and restart modules", function()
    rust.setup()
    H.ok(#vim.api.nvim_get_autocmds({ group = "xyno_rust_lsp_status" }) >= 3)
    H.ok(#vim.api.nvim_get_autocmds({ group = "xyno_rust_restart" }) >= 3)
  end)

  it("calling setup() twice does not duplicate autocmds", function()
    rust.setup()
    local n = #vim.api.nvim_get_autocmds({ group = "xyno_rust_restart" })
    rust.setup()
    H.eq(n, #vim.api.nvim_get_autocmds({ group = "xyno_rust_restart" }))
  end)
end)

describe("keymaps", function()
  before_each(clear_commands)
  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, "xyno_rust_keymaps")
    pcall(vim.cmd, "silent! %bwipeout!")
  end)

  it("keymaps = true maps the defaults buffer-locally in Rust buffers only", function()
    rust.setup({ keymaps = true })
    local buf = rust_buf()
    for name, lhs in pairs(rust.default_keymaps) do
      local m = buf_map(buf, lhs)
      H.eq(1, m.buffer, name)
      H.ok(m.desc and m.desc ~= "", name .. " has a description")
    end
    H.eq("<cmd>rustcontext<cr>", buf_map(buf, rust.default_keymaps.context).rhs:lower())
    vim.cmd.enew()
    H.eq(0, buf_map(vim.api.nvim_get_current_buf(), rust.default_keymaps.context).buffer or 0)
  end)

  it("a table maps only the listed actions, with the keys given", function()
    rust.setup({ keymaps = { context = "<leader>zc", targets = false } })
    local buf = rust_buf()
    H.eq(1, buf_map(buf, "<leader>zc").buffer)
    H.eq(0, buf_map(buf, rust.default_keymaps.targets).buffer or 0)
    H.eq(0, buf_map(buf, rust.default_keymaps.context).buffer or 0)
  end)

  it("keymaps = false (the default) sets nothing", function()
    rust.setup()
    local buf = rust_buf()
    for _, lhs in pairs(rust.default_keymaps) do
      H.eq(0, buf_map(buf, lhs).buffer or 0, lhs)
    end
  end)
end)

describe("snacks.nvim is optional", function()
  it("a picker command without it is one error line, not a Lua error", function()
    local orig = rawget(_G, "Snacks")
    _G.Snacks = nil
    local cap = H.capture_notify()
    local ok, err = pcall(function()
      -- (this spec runs where snacks.nvim is not installed; skip if it is)
      if pcall(require, "snacks") then
        require("xyno_rust_test.harness").skip("snacks.nvim is installed here")
      end
      local dir = H.fixture("basic")
      vim.cmd.cd(vim.fn.fnameescape(dir))
      vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/lib.rs"))
      rust.setup()
      vim.cmd("RustTools")
    end)
    cap.restore()
    _G.Snacks = orig
    if not ok then
      error(err, 0)
    end
    local last = cap.list[#cap.list]
    H.eq(vim.log.levels.ERROR, last and last.level)
    H.eq("xyno-rust: snacks.nvim is required for pickers and terminals (folke/snacks.nvim)", last and last.msg)
  end)
end)
