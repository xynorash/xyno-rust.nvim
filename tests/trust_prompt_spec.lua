-- The trust question as a wrapped float (xyno_rust.trust_prompt): the whole text is visible at 60 / 80 / 120
-- columns, the choices are keys, and the mode (normal / insert) the editor was in comes back.
local H = require("xyno_rust_test.helpers")
H.fake_snacks()
require("xyno_rust").setup()
local trust = require("xyno_rust.trust")
local prompt = require("xyno_rust.trust_prompt")

local function visible_text(win)
  local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
  return table.concat(lines, "\n")
end

local function open(dir)
  local got = { n = 0 }
  trust.float_prompt = true
  trust.ask(dir, "rust-analyzer (build scripts, proc macros) and clippy", function(a)
    got.n, got.answer = got.n + 1, a
  end)
  trust.float_prompt = nil
  return got
end

local function float_win()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative == "editor" then
      return w
    end
  end
end

describe("trust prompt float", function()
  local saved_cols, saved_lines
  before_each(function()
    saved_cols, saved_lines = vim.o.columns, vim.o.lines
  end)
  after_each(function()
    vim.o.columns, vim.o.lines = saved_cols, saved_lines
    trust.float_prompt = nil
    trust.revoke_all()
    pcall(vim.cmd, "stopinsert")
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(w).relative == "editor" then
        pcall(vim.api.nvim_win_close, w, true)
      end
    end
  end)

  for _, cols in ipairs({ 60, 80, 120 }) do
    it(
      ("at %d columns the whole question fits in the float, wrapped, and every choice is visible"):format(cols),
      function()
        vim.o.columns, vim.o.lines = cols, 40
        local dir = H.tmpdir() .. "/a/rather/long/workspace/path/that/does/not/fit/a/narrow/terminal/line/at/all/xyz"
        vim.fn.mkdir(dir, "p")
        local got = open(dir)
        local win = float_win()
        H.ok(win, "a float is open")
        local cfg = vim.api.nvim_win_get_config(win)
        H.ok(cfg.col >= 0 and cfg.col + cfg.width <= cols, "inside the grid horizontally")
        H.ok(cfg.row >= 0 and cfg.row + cfg.height <= 40, "inside the grid vertically")
        H.ok(vim.wo[win].wrap, "wrapping is on")
        local text = visible_text(win)
        H.match(text, "Trust ", true)
        H.match(text, "xyz", true) -- the end of the path
        H.match(text, "can run code from it", true)
        for _, label in ipairs({ "Trust this workspace", "Trust everything under", "Run this once", "Do not run" }) do
          H.match(text, label, true)
        end
        -- the window is tall enough for every wrapped line (nothing scrolled out of view)
        H.eq(vim.api.nvim_win_text_height(win, {}).all, cfg.height)
        vim.api.nvim_feedkeys("4", "x", false)
        H.eq(1, got.n)
        H.eq(false, got.answer)
        H.is_nil(float_win(), "closed")
      end
    )
  end

  it("restores normal mode, and insert mode when the editor was in it", function()
    local dir = H.tmpdir()
    local got = open(dir)
    vim.api.nvim_feedkeys("3", "x", false)
    H.eq(true, got.answer)
    H.eq("n", vim.api.nvim_get_mode().mode)
    -- headless nvim -l does not enter insert mode from a mapping: record what the prompt asks for
    local calls = {}
    rawset(vim.cmd, "startinsert", function()
      calls[#calls + 1] = "startinsert"
    end)
    local orig_mode = vim.api.nvim_get_mode
    vim.api.nvim_get_mode = function()
      return { mode = "i", blocking = false }
    end
    local got2 = open(dir)
    vim.api.nvim_get_mode = orig_mode
    H.ok(float_win())
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)
    rawset(vim.cmd, "startinsert", nil)
    H.eq(false, got2.answer)
    H.eq({ "startinsert" }, calls, "insert mode is asked for again when it was insert before")
  end)

  it("<CR> chooses the line under the cursor, j/k move, 1 trusts and remembers", function()
    local dir = H.tmpdir()
    local got = open(dir)
    vim.api.nvim_feedkeys("jj", "x", false) -- third choice: run once
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    H.eq(true, got.answer)
    H.not_ok(trust.is_trusted(dir), "run once remembers nothing")
    local got2 = open(dir)
    vim.api.nvim_feedkeys("1", "x", false)
    H.eq(true, got2.answer)
    H.ok(trust.is_trusted(dir))
  end)

  it("leaving the float cancels it (no answer is left hanging)", function()
    local dir = H.tmpdir()
    local got = open(dir)
    vim.cmd("wincmd p")
    H.wait_for(function()
      return got.n == 1
    end, 2000, "cancel")
    H.eq(false, got.answer)
  end)
end)
