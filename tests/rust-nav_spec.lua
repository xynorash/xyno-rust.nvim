-- xyno_rust.rust_nav (goto_super, local_usages). One real rust-analyzer
-- session on tests/fixtures/keymaps-rust-crate is shared by the tests; the rest
-- of the behaviour is checked with stubs of the client's requests (restored in
-- after_each) so no test depends on rust-analyzer's timing. Needs rust-analyzer
-- and the tree-sitter rust parser; skips with a message without them.
local H = require("xyno_rust_test.helpers")
local nav = require("xyno_rust.rust_nav")

local S -- shared session { dir, buf, client }
local undo = {}

--- Replace t[k] by v until after_each.
local function stub(t, k, v)
  local old = rawget(t, k)
  undo[#undo + 1] = function()
    rawset(t, k, old)
  end
  rawset(t, k, v)
end

local function session()
  H.need_rust()
  H.need_parser("rust")
  if S then
    vim.cmd("silent! only")
    vim.api.nvim_set_current_buf(S.buf)
    -- the tree must follow the buffer reset of after_each (get_node does not reparse)
    vim.treesitter.get_parser(S.buf, "rust"):parse(true)
    return S
  end
  local dir, buf = H.open_fixture("nav-crate")
  vim.treesitter.start(buf, "rust")
  local client = H.start_ra(buf, dir)
  S = { dir = dir, buf = buf, client = client }
  return S
end

local function find(pat)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  local l = vim.fn.search("\\V" .. pat, "cw")
  H.ok(l > 0, "pattern not found in the fixture: " .. pat)
  return l
end

local function lines()
  return vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
end

local ORIGINAL
local function remember()
  ORIGINAL = ORIGINAL or lines()
end
local function reset_buffer()
  if ORIGINAL then
    vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, ORIGINAL)
    vim.bo[S.buf].modified = false
  end
end

local function notifications()
  local cap = H.capture_notify()
  undo[#undo + 1] = cap.restore
  return cap.list
end

after_each(function()
  for i = #undo, 1, -1 do
    pcall(undo[i])
  end
  undo = {}
  if S then
    pcall(vim.cmd, "silent! only")
    pcall(vim.api.nvim_set_current_buf, S.buf)
    pcall(reset_buffer)
  end
end)

describe("rust_nav", function()
  before_each(function()
    session()
    remember()
  end)

  local function stub_definition(reply)
    local seen = {}
    local orig = S.client.request
    stub(S.client, "request", function(self, method, params, cb, ...)
      if method ~= "textDocument/definition" and method ~= "textDocument/documentHighlight" then
        return orig(self, method, params, cb, ...) -- semantic tokens etc. stay real
      end
      seen[#seen + 1] = { method = method, params = params }
      cb(reply and reply.err, reply and reply.res)
      return true, 1
    end)
    return seen
  end

  it("outside a function: WARN 'not inside a function'", function()
    local n = notifications()
    find("use std::fmt")
    nav.goto_super()
    H.eq({ { msg = "not inside a function", level = vim.log.levels.WARN } }, n)
  end)

  it("inside a plain impl: WARN 'not a trait impl method'", function()
    local n = notifications()
    local l = find("pub fn plain")
    vim.api.nvim_win_set_cursor(0, { l + 1, 8 })
    nav.goto_super()
    H.eq({ { msg = "not a trait impl method", level = vim.log.levels.WARN } }, n)
  end)

  it("no definition: WARN 'trait definition not found'", function()
    local n = notifications()
    local l = find("fn area(&self) -> f64 {")
    vim.api.nvim_win_set_cursor(0, { l + 1, 8 })
    stub_definition({ res = nil })
    nav.goto_super()
    H.eq({ { msg = "trait definition not found", level = vim.log.levels.WARN } }, n)
  end)

  it("an empty definition list also gives 'trait definition not found'", function()
    local n = notifications()
    local l = find("fn area(&self) -> f64 {")
    vim.api.nvim_win_set_cursor(0, { l + 1, 8 })
    stub_definition({ res = {} })
    nav.goto_super()
    H.eq({ { msg = "trait definition not found", level = vim.log.levels.WARN } }, n)
  end)

  it("fmt::Display (scoped path) and From<i32> (generic type) ask for the trait identifier", function()
    local function ask_at(fn_pat, trait_pat, word)
      local l = find(fn_pat)
      vim.api.nvim_win_set_cursor(0, { l + 1, 8 })
      local seen = stub_definition({ res = nil })
      nav.goto_super()
      H.eq("textDocument/definition", seen[1].method)
      local tl = find(trait_pat)
      local want = lines()[tl]:find(word, 1, true) - 1
      H.eq({ line = tl - 1, character = want }, seen[1].params.position, word)
    end
    ask_at("fn fmt(&self", "impl fmt::Display", "Display")
    ask_at("fn from(v", "impl From<i32>", "From")
    ask_at("fn area(&self) -> f64 {", "impl Shape for Square", "Shape")
  end)

  it("a definition response puts the cursor on `fn area` and centres it (zz)", function()
    local dir = H.tmpdir()
    local file = dir .. "/long.rs"
    local body = {}
    for i = 1, 150 do
      body[i] = ("// filler %d"):format(i)
    end
    body[100] = "pub trait Shape {"
    body[101] = "    fn other(&self);"
    body[102] = "    fn area(&self) -> f64;"
    body[103] = "}"
    vim.fn.writefile(body, file)
    local l = find("fn area(&self) -> f64 {")
    vim.api.nvim_win_set_cursor(0, { l + 1, 8 })
    stub_definition({
      res = { {
        uri = vim.uri_from_fname(file),
        range = { start = { line = 99, character = 0 }, ["end"] = { line = 99, character = 5 } },
      } },
    })
    nav.goto_super()
    H.eq(file, vim.api.nvim_buf_get_name(0))
    H.eq(102, vim.api.nvim_win_get_cursor(0)[1])
    H.match(vim.api.nvim_get_current_line(), "fn area", true)
    local h = vim.api.nvim_win_get_height(0)
    H.ok(math.abs(vim.fn.winline() - math.ceil(h / 2)) <= 1, ("centred: winline %d of %d"):format(vim.fn.winline(), h))
    vim.cmd("bwipeout!")
  end)

  it("a doc comment mentioning `fn area` before the method is skipped", function()
    local dir = H.tmpdir()
    local file = dir .. "/doc.rs"
    vim.fn.writefile({
      "pub trait Shape {",
      "    /// Call it as `fn area(&self)` to get the area.",
      "    /// See also fn area elsewhere.",
      "    fn area(&self) -> f64;",
      "}",
    }, file)
    local l = find("fn area(&self) -> f64 {")
    vim.api.nvim_win_set_cursor(0, { l + 1, 8 })
    stub_definition({
      res = { {
        uri = vim.uri_from_fname(file),
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
      } },
    })
    nav.goto_super()
    H.eq(file, vim.api.nvim_buf_get_name(0))
    H.eq(4, vim.api.nvim_win_get_cursor(0)[1], "landed on the doc comment, not the method")
    vim.cmd("bwipeout!")
  end)

  it("the doc-comment skip does not depend on a treesitter parser (field test: std's Display::fmt, `///` line)", function()
    local dir = H.tmpdir()
    local file = dir .. "/nots.rs"
    vim.fn.writefile({
      "pub trait Shape {",
      "    /// Formats like `fn area(&self)` does.",
      "    // fn area is also mentioned here",
      "    /* fn area */",
      "    fn area(&self) -> f64;",
      "}",
    }, file)
    local l = find("fn area(&self) -> f64 {")
    vim.api.nvim_win_set_cursor(0, { l + 1, 8 })
    -- a freshly shown buffer has no parser yet: get_node() gave nil and the first match stuck
    local orig_get_node = vim.treesitter.get_node
    stub(vim.treesitter, "get_node", function(...)
      if vim.api.nvim_buf_get_name(0) == file then
        return nil
      end
      return orig_get_node(...)
    end)
    stub_definition({
      res = { {
        uri = vim.uri_from_fname(file),
        range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 5 } },
      } },
    })
    nav.goto_super()
    H.eq(file, vim.api.nvim_buf_get_name(0))
    H.eq(5, vim.api.nvim_win_get_cursor(0)[1], "landed on a comment line, not the method")
    vim.cmd("bwipeout!")
  end)

  it("real rust-analyzer: from `impl Shape for Square` to the trait's `fn area`", function()
    local l = find("fn area(&self) -> f64 {")
    local want = find("fn area(&self) -> f64;")
    -- rust-analyzer answers "not found" while it still loads the crate: ask again
    H.wait_for(function()
      vim.api.nvim_set_current_buf(S.buf)
      vim.api.nvim_win_set_cursor(0, { l + 1, 8 })
      nav.goto_super()
      return vim.wait(1500, function()
        return vim.api.nvim_win_get_cursor(0)[1] == want
      end, 50)
    end, 90000, "cursor on the trait's fn area")
    H.match(vim.api.nvim_get_current_line(), "fn area(&self) -> f64;", true)
  end)

  describe("local_usages", function()
    local function range(l, c)
      return { start = { line = l, character = c }, ["end"] = { line = l, character = c + 1 } }
    end

    it("quickfix 'usages (this file)' with [R]/[W]/[T], sorted by line, copen", function()
      local l = find("let total")
      vim.api.nvim_win_set_cursor(0, { l, 8 })
      stub_definition({
        res = {
          { range = range(l + 1, 28), kind = 2 }, -- read: println line
          { range = range(l - 1, 8), kind = 3 }, -- write: the let
          { range = range(l, 5), kind = 1 }, -- text (name_wrdx line)
        },
      })
      vim.fn.setqflist({}, "r")
      nav.local_usages()
      local qf = vim.fn.getqflist({ title = true, items = true })
      H.eq("usages (this file)", qf.title)
      H.eq(3, #qf.items)
      local lnums = vim.tbl_map(function(i)
        return i.lnum
      end, qf.items)
      H.eq({ l, l + 1, l + 2 }, lnums)
      H.match(qf.items[1].text, "^%[W%] let total")
      H.match(qf.items[2].text, "^%[T%] let name_wrdx")
      H.match(qf.items[3].text, "^%[R%] println!")
      H.eq(S.buf, qf.items[1].bufnr)
      H.eq(9, qf.items[1].col)
      -- rust-analyzer sends no kind on a declaration: labelled [W], not [T]
      stub_definition({ res = { { range = range(l - 1, 8) } } })
      nav.local_usages()
      H.match(vim.fn.getqflist({ items = true }).items[1].text, "^%[W%] let total")
      local has_qf = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        has_qf = has_qf or vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "quickfix"
      end
      H.ok(has_qf, "copen opened the quickfix window")
      vim.fn.setqflist({}, "r")
    end)

    it("no usages: INFO 'no usages in this file', no quickfix", function()
      local n = notifications()
      vim.fn.setqflist({}, "r")
      for _, res in ipairs({ {}, false }) do
        n[1] = nil
        stub_definition({ res = res })
        nav.local_usages()
        H.eq({ { msg = "no usages in this file", level = vim.log.levels.INFO } }, n)
      end
      H.eq(0, #vim.fn.getqflist())
    end)

    it("real rust-analyzer: usages of `total` are labelled", function()
      local l = find("let total")
      vim.api.nvim_win_set_cursor(0, { l, 8 })
      nav.local_usages()
      local qf = H.wait_for(function()
        local q = vim.fn.getqflist({ title = true, items = true })
        return q.title == "usages (this file)" and q
      end, 60000, "usages quickfix")
      H.eq(2, #qf.items)
      for _, it in ipairs(qf.items) do
        H.match(it.text, "^%[[TRW]%] ")
      end
      H.match(qf.items[2].text, "^%[R%] println!")
      vim.fn.setqflist({}, "r")
    end)
  end)
end)

