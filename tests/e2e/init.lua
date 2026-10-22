-- Minimal init for the end-to-end smoke test: lazy.nvim loads this checkout
-- through `dir =` and calls setup(). XYNO_LAZY is the path of a lazy.nvim clone.
-- Run:  XYNO_LAZY=/path/to/lazy.nvim nvim --headless -u tests/e2e/init.lua -c "luafile tests/e2e/smoke.lua"
local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
vim.o.swapfile = false
vim.opt.rtp:prepend(assert(vim.env.XYNO_LAZY, "XYNO_LAZY not set"))
require("lazy").setup({
  {
    dir = repo,
    name = "xyno-rust.nvim",
    lazy = false,
    opts = {},
    main = "xyno_rust",
  },
}, {
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  performance = { reset_packpath = false, rtp = { reset = false } },
})
