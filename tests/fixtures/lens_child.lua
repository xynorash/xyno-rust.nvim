-- Child nvim of lens-click_spec: a Rust buffer with an in-process language server that answers
-- textDocument/codeLens with "▶︎ Run | Debug" over `fn main`, and commands that write marker files.
-- argv: <plugin repo> <marker dir> <file>
local repo, out, file = arg and arg[1], arg and arg[2], arg and arg[3]
repo, out, file = repo or vim.env.LC_REPO, out or vim.env.LC_OUT, file or vim.env.LC_FILE
vim.opt.rtp:prepend(repo)
vim.o.swapfile = false
vim.o.mouse = "a"
vim.o.number = true
vim.o.signcolumn = "yes"
require("xyno_rust.lens_click").setup()
local function server()
  return function(dispatchers)
    local closing = false
    local srv = {}
    function srv.request(method, params, cb)
      if method == "initialize" then
        cb(nil, { capabilities = { codeLensProvider = { resolveProvider = false } } })
      elseif method == "textDocument/codeLens" then
        local function lens(title, cmd, char)
          return { range = { start = { line = 2, character = char }, ["end"] = { line = 2, character = char + 2 } }, command = { title = title, command = cmd } }
        end
        cb(nil, { lens("▶︎ Run", "xyno.test.run", 0), lens("Debug", "xyno.test.debug", 0) })
      elseif method == "shutdown" then
        cb(nil, nil)
      else
        cb(nil, nil)
      end
      return true, 1
    end
    function srv.notify() end
    function srv.is_closing() return closing end
    function srv.terminate() closing = true end
    return srv
  end
end
for _, which in ipairs({ "run", "debug" }) do
  vim.lsp.commands["xyno.test." .. which] = function()
    local f = io.open(out .. "/" .. which, "w")
    f:write("clicked")
    f:close()
  end
end
vim.cmd.edit(vim.fn.fnameescape(file))
vim.bo.filetype = "rust"
vim.lsp.start({ name = "fake-ra", cmd = server(), root_dir = vim.fs.dirname(file) }, { bufnr = 0 })
vim.lsp.codelens.enable(true)
