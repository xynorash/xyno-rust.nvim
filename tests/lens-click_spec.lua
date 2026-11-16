-- xyno_rust.lens_click: where the lenses of a line are (pure), and a click on a real code lens in a real
-- terminal UI (tmux; a child nvim with an in-process language server that offers "Run | Debug" over a fn).
-- A click on the code line keeps its normal meaning (the cursor moves, no lens runs).
local H = require("xyno_rust_test.helpers")
local L = require("xyno_rust.lens_click")

local function e(title, char, line)
  return {
    client_id = 1,
    lens = { range = { start = { line = line or 3, character = char } }, command = { title = title } },
  }
end

describe("spans / hit", function()
  it("lays the titles out like the virtual line: indentation, title, ' | ', title", function()
    local sp = L.spans({ e("▶︎ Run", 4), e("Debug", 4), e("other line", 0, 9) }, 3, 4)
    H.eq(2, #sp)
    local w = vim.fn.strdisplaywidth("▶︎ Run")
    H.eq({ 4, 4 + w }, { sp[1].from, sp[1].to })
    H.eq({ 4 + w + 3, 4 + w + 3 + 5 }, { sp[2].from, sp[2].to })
  end)
  it("orders by the position in the line and skips lenses without a command", function()
    local late = e("B", 20)
    local early = e("A", 5)
    local unresolved = { client_id = 1, lens = { range = { start = { line = 3, character = 0 } } } }
    local sp = L.spans({ late, unresolved, early }, 3, 5)
    H.eq(
      { "A", "B" },
      vim.tbl_map(function(s)
        return s.lens.command.title
      end, sp)
    )
  end)
  it("the separator and the indentation are not hits", function()
    local sp = L.spans({ e("Run", 2), e("Debug", 2) }, 3, 2)
    H.is_nil(L.hit(sp, 0))
    H.is_nil(L.hit(sp, 5)) -- ' | '
    H.eq("Run", L.hit(sp, 2).lens.command.title)
    H.eq("Debug", L.hit(sp, 8).lens.command.title)
    H.is_nil(L.hit(sp, 13))
  end)
end)

describe("a real click in a terminal", function()
  local session = "xrlc" .. vim.fn.getpid()
  local function tmux(...)
    return vim.system(vim.list_extend({ "tmux", "-L", session }, { ... }), { text = true }):wait(10000)
  end
  local function screen()
    return tmux("capture-pane", "-p").stdout
  end
  local function click(col, row)
    tmux("send-keys", "-l", ("\27[<0;%d;%dM"):format(col, row))
    tmux("send-keys", "-l", ("\27[<0;%d;%dm"):format(col, row))
  end
  after_each(function()
    tmux("kill-server")
  end)

  it("clicking Run runs it, clicking Debug debugs, clicking code does neither", function()
    if vim.fn.executable("tmux") ~= 1 then
      return H.skip_file("tmux is not installed")
    end
    local dir = H.tmpdir()
    vim.fn.writefile({ "// one", "", "fn main() {", "    println!();", "}" }, dir .. "/main.rs")
    local repo = H.repo
    local r = tmux(
      "new-session",
      "-d",
      "-x",
      "80",
      "-y",
      "24",
      "-e",
      "LC_REPO=" .. repo,
      "-e",
      "LC_OUT=" .. dir,
      "-e",
      "LC_FILE=" .. dir .. "/main.rs",
      "nvim --clean -n -c 'luafile " .. repo .. "/tests/fixtures/lens_child.lua'"
    )
    H.eq(0, r.code, r.stderr)
    -- wait for the lens to be drawn
    H.wait_for(function()
      return screen():find("Debug", 1, true)
    end, 15000, "the lens line on screen")
    local lines = vim.split(screen(), "\n", { plain = true })
    local lens_row, code_row
    for i, l in ipairs(lines) do
      if l:find("Debug", 1, true) then
        lens_row = i
      end
      if l:find("fn main", 1, true) then
        code_row = i
      end
    end
    H.ok(lens_row and code_row and lens_row == code_row - 1, "lens line above the code line: " .. screen())
    local text = lines[lens_row]
    -- terminal columns (1-based) of the titles; the line is ASCII except the play sign
    local function col_of(word)
      local b = text:find(word, 1, true)
      return vim.fn.strdisplaywidth(text:sub(1, b - 1)) + 1
    end
    -- click the code line first: nothing runs
    click(col_of("Debug") + 1, code_row)
    vim.wait(500)
    H.is_nil(vim.uv.fs_stat(dir .. "/run"))
    H.is_nil(vim.uv.fs_stat(dir .. "/debug"))
    -- click the separator: nothing
    click(col_of("Debug") - 2, lens_row)
    vim.wait(500)
    H.is_nil(vim.uv.fs_stat(dir .. "/run"))
    click(col_of("Run") + 1, lens_row)
    H.wait_for(function()
      return vim.uv.fs_stat(dir .. "/run")
    end, 8000, "Run command executed")
    H.is_nil(vim.uv.fs_stat(dir .. "/debug"))
    click(col_of("Debug") + 1, lens_row)
    H.wait_for(function()
      return vim.uv.fs_stat(dir .. "/debug")
    end, 8000, "Debug command executed")
  end)
end)
