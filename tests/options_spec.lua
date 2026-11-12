-- setup() options: validation, the :RustTools list and the highlight groups.
local H = require("xyno_rust_test.helpers")
local X = require("xyno_rust")
local tasks = require("xyno_rust.rust_tasks")
local ui = require("xyno_rust.ui")

local function setup_capture(opts)
  local notes, orig = {}, vim.notify
  vim.notify = function(msg, level)
    notes[#notes + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(X.setup, opts)
  vim.notify = orig
  H.ok(ok, tostring(err))
  return notes
end

after_each(function()
  tasks.set_tools({})
end)

local function texts()
  return vim.tbl_map(function(t)
    return t.id or t.text
  end, tasks.tool_list())
end

describe("tools option", function()
  it("the default list is the nine built-in tools", function()
    H.eq({ "timings", "bloat_crates", "bloat_functions", "machete", "deny_fetch", "deny_check", "audit", "tree_dups", "llvm_cov" }, texts())
  end)

  it("hide removes by id, extra appends", function()
    local notes = setup_capture({ tools = { hide = { "audit", "machete" }, extra = { { text = "typos", cmd = { "typos" } }, { text = "doc", cmd = { "cargo", "doc" }, flags = true } } } })
    H.eq(0, #notes)
    H.eq({ "timings", "bloat_crates", "bloat_functions", "deny_fetch", "deny_check", "tree_dups", "llvm_cov", "typos", "doc" }, texts())
  end)

  it("a second setup() replaces the first one's tools", function()
    setup_capture({ tools = { hide = { "audit" } } })
    setup_capture({})
    H.eq(9, #tasks.tool_list())
  end)

  it("bad tools give one warning and the default list stays", function()
    local notes = setup_capture({ tools = { hide = { "nope" }, extra = { { text = "x", cmd = "cargo doc" }, { text = "y\nz", cmd = { "a" } }, { cmd = { "a" }, shell = true } }, bogus = 1 } })
    H.eq(1, #notes)
    for _, frag in ipairs({ "unknown tool `nope`", "extra[1].cmd must be a non-empty argv list", "extra[2].text must be a one-line string", "extra[3]: unknown key `shell`", "unknown tools option `bogus`" }) do
      H.match(notes[1].msg, frag, true)
    end
    H.eq(9, #tasks.tool_list())
  end)
end)

describe("other options are validated too", function()
  it("wrong types and unknown modules: one warning, the valid parts apply", function()
    local notes = setup_capture({ commands = "yes", modules = { routes = "no", nothing = true }, keymaps = 3 })
    H.eq(1, #notes)
    for _, frag in ipairs({ "commands must be a boolean", "module `routes` must be a boolean", "unknown module `nothing`", "keymaps must be false, true or a table" }) do
      H.match(notes[1].msg, frag, true)
    end
    setup_capture({})
  end)
end)

describe("highlight groups", function()
  it("are linked to theme groups, survive :colorscheme and never overwrite the user's", function()
    setup_capture({})
    for name, target in pairs(ui.groups) do
      H.eq(target, vim.api.nvim_get_hl(0, { name = name, link = true }).link, name)
    end
    vim.api.nvim_set_hl(0, "XynoRustRouteFile", { fg = "#abcdef" })
    ui.define()
    H.eq(0xabcdef, vim.api.nvim_get_hl(0, { name = "XynoRustRouteFile" }).fg)
    vim.cmd("hi clear")
    vim.api.nvim_exec_autocmds("ColorScheme", {})
    H.eq("Keyword", vim.api.nvim_get_hl(0, { name = "XynoRustRouteKind", link = true }).link)
  end)
end)
