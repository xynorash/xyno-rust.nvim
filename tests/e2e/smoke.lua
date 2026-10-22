-- End-to-end smoke test (see tests/e2e/init.lua): the plugin is loaded by lazy.nvim,
-- setup() ran, every documented command exists, :help xyno-rust resolves, and a few
-- commands run in a scratch crate.
local failures = {}
local function check(name, ok, detail)
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", name, (not ok and detail) and (": " .. tostring(detail)) or ""))
  if not ok then
    failures[#failures + 1] = name
  end
end

check("lazy.nvim loaded xyno_rust", package.loaded["xyno_rust"] ~= nil)
for _, c in ipairs({ "RustContext", "RustTargets", "RustTools", "ActJob", "RustNew", "RustRoutes", "RustRestart" }) do
  check("command :" .. c, vim.fn.exists(":" .. c) == 2)
end
check("autocmd group xyno_rust_lsp_status", #vim.api.nvim_get_autocmds({ group = "xyno_rust_lsp_status" }) >= 3)
check("autocmd group xyno_rust_restart", #vim.api.nvim_get_autocmds({ group = "xyno_rust_restart" }) >= 3)
for _, m in ipairs({ "fsutil", "rust_context", "code_actions", "crate_meta", "lsp_status", "rust_restart", "rust_tasks", "rust_routes", "rust_nav" }) do
  check("require xyno_rust." .. m, (pcall(require, "xyno_rust." .. m)))
end

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
vim.cmd("helptags " .. vim.fn.fnameescape(repo .. "/doc"))
for _, tag in ipairs({ "xyno-rust", "xyno-rust-api", "xyno-rust-setup", ":RustContext", ":RustRestart" }) do
  local ok, err = pcall(vim.cmd, "help " .. tag)
  check(":help " .. tag, ok, err)
end
vim.cmd("only")

-- a scratch crate: :RustContext show reports the default, a stored choice round-trips
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/src", "p")
vim.fn.writefile({ '[package]', 'name = "smoke"', 'version = "0.1.0"', 'edition = "2021"' }, dir .. "/Cargo.toml")
vim.fn.writefile({ "fn main() {}" }, dir .. "/src/main.rs")
vim.cmd.edit(vim.fn.fnameescape(dir .. "/src/main.rs"))
local notes = {}
local orig = vim.notify
vim.notify = function(msg)
  notes[#notes + 1] = msg
end
vim.cmd("RustContext show")
check(":RustContext show", notes[#notes] == "Rust context: all features, host target", notes[#notes])
local rc = require("xyno_rust.rust_context")
check("rust_context.root", rc.root() == dir, tostring(rc.root()))
check("component() is a string", type(require("xyno_rust.lsp_status").component()) == "string")
vim.notify = orig
vim.fn.delete(dir, "rf")

if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
