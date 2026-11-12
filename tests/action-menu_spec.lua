-- xyno_rust.action_menu: diff previews of code actions, the refactor menu and :RustFixAll, against a
-- real rust-analyzer on the fix-lab fixture, plus the merge rules of fix-all on a fake server.
local H = require("xyno_rust_test.helpers")
H.fake_snacks()
require("xyno_rust").setup()
local M = require("xyno_rust.action_menu")
local ca = require("xyno_rust.code_actions")

-- The statusline component needs serverStatus notifications (rustaceanvim advertises them, a bare
-- vim.lsp.start does not): the real component is used, with "ready" fed by the spec.
local status = require("xyno_rust.lsp_status")
local real_status = status.rust_analyzer
before_each(function()
  status.rust_analyzer = function()
    return "RA ready"
  end
end)

after_each(function()
  status.rust_analyzer = real_status
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
end)

local function text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

describe("snippets", function()
  it("strip_snippet keeps defaults and drops tab stops", function()
    H.eq("let name = x;", M.strip_snippet("let ${1:name} = $0${2}x;"))
    H.eq("a$b}", M.strip_snippet([[a\$b\}]]))
    H.eq("x", M.strip_snippet("x"))
  end)
  it("plain_edit only touches snippet edits and leaves the original alone", function()
    local e = {
      documentChanges = {
        {
          textDocument = { uri = "file:///x" },
          edits = { { newText = "${1:a}", insertTextFormat = 2, range = {} }, { newText = "$1", range = {} } },
        },
      },
    }
    local p = M.plain_edit(e)
    H.eq("a", p.documentChanges[1].edits[1].newText)
    H.eq("$1", p.documentChanges[1].edits[2].newText, "plain text is plain")
    H.eq("${1:a}", e.documentChanges[1].edits[1].newText)
  end)
end)

describe("edit_diff", function()
  it("diffs a documentChanges edit against the buffer, and shows file operations", function()
    local dir = H.fixture("fix-lab")
    local file = dir .. "/src/lib.rs"
    local uri = vim.uri_from_fname(file)
    local d = M.edit_diff({
      documentChanges = {
        {
          textDocument = { uri = uri },
          edits = {
            { range = { start = { line = 0, character = 0 }, ["end"] = { line = 1, character = 0 } }, newText = "" },
          },
        },
        { kind = "create", uri = vim.uri_from_fname(dir .. "/src/new.rs") },
        { kind = "rename", oldUri = uri, newUri = vim.uri_from_fname(dir .. "/src/b.rs") },
      },
    })
    H.match(d, "-use std::collections::HashMap;", true)
    H.match(d, "@@", true)
    H.match(d, "create ", true)
    H.match(d, "b.rs", true)
  end)
  it("an edit that changes nothing is nil; a misfit edit is reported, not thrown", function()
    local dir = H.fixture("fix-lab")
    local uri = vim.uri_from_fname(dir .. "/src/lib.rs")
    H.is_nil(M.edit_diff({
      changes = {
        [uri] = {
          { range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } }, newText = "" },
        },
      },
    }))
    local d = M.edit_diff({
      changes = {
        [uri] = {
          { range = { start = { line = 999, character = 0 }, ["end"] = { line = 999, character = 5 } }, newText = "x" },
        },
      },
    })
    H.ok(d == nil or d:find("does not fit", 1, true) or d:find("x", 1, true))
  end)
end)

describe("menu on a real rust-analyzer", function()
  local dir, buf
  local function ready()
    H.need_rust()
    dir, buf = H.open_fixture("fix-lab", "src/lib.rs")
    H.start_ra(buf, dir)
    H.wait_for(function()
      return #vim.diagnostic.get(buf) >= 2
    end, 90000, "diagnostics")
  end

  --- Run `fn(items, picker_opts)` when the menu has its items.
  local function menu(open_opts)
    local got
    open_opts.pick = function(items, o)
      got = { items = items, opts = o }
    end
    M.open(open_opts)
    H.wait_for(function()
      return got
    end, 60000, "menu")
    return got
  end

  it("refactor menu: Extract is offered, previewed as a diff, applied on confirm", function()
    ready()
    vim.api.nvim_win_set_cursor(0, { 14, 16 })
    local m = menu({ only = { "refactor" }, range = { start = { 13, 16 }, ["end"] = { 13, 21 } } })
    local titles = vim.tbl_map(function(i)
      return i.title
    end, m.items)
    H.has(titles, "Extract into variable")
    for _, i in ipairs(m.items) do
      H.match(i.kind, "^refactor")
    end
    -- preview: the picker's preview function with a fake ctx
    local item
    for _, i in ipairs(m.items) do
      if i.title == "Extract into variable" then
        item = i
      end
    end
    local shown
    local ctx = {
      item = item,
      picker = {
        closed = false,
        current = function()
          return item
        end,
      },
      preview = {
        reset = function() end,
        minimal = function() end,
        set_title = function() end,
        set_lines = function(_, l)
          shown = l
        end,
        highlight = function() end,
        win = {
          buf_valid = function()
            return true
          end,
        },
      },
    }
    ctx.preview.set_lines = function(_, l)
      shown = l
    end
    m.opts.preview(ctx)
    H.wait_for(function()
      return shown and shown[1] ~= "resolving ..."
    end, 20000, "diff to show")
    local diff = table.concat(shown, "\n")
    H.match(diff, "--- a/src/lib.rs", true)
    H.match(diff, "+++ b/src/lib.rs", true)
    H.match(diff, "var_name", true)
    -- the buffer is untouched until confirm
    H.not_ok(text(buf):find("var_name", 1, true))
    local closed
    m.opts.confirm({
      close = function()
        closed = true
      end,
    }, item)
    H.wait_for(function()
      return text(buf):find("var_name", 1, true)
    end, 20000, "the edit")
    H.ok(closed)
  end)

  it("the actions menu lists the preferred quick fix of a diagnostic first", function()
    ready()
    local m = menu({ range = { 0, 5 } })
    H.eq(true, m.items[1].preferred)
    H.match(m.items[1].kind, "^quickfix")
    H.match(m.items[1].title, "`use` item", true) -- rust-analyzer: "remove the whole `use` item"
  end)

  it(":RustFixAll applies the preferred quick fixes of the buffer as one undo step", function()
    ready()
    local before = text(buf)
    H.match(before, "use std::collections::HashMap;", true)
    local done
    M.fix_all(buf, {}, function(r)
      done = r
    end)
    H.wait_for(function()
      return done
    end, 90000, "fix all")
    H.is_nil(done.err)
    H.ok(done.applied >= 2, "applied " .. tostring(done.applied) .. " " .. vim.inspect(done))
    local after = text(buf)
    H.not_ok(after:find("use std::collections::HashMap;", 1, true))
    H.not_ok(after:find("use std::fmt::Debug;", 1, true))
    H.match(after, "pub fn total", true, "the rest of the file is kept")
    H.match(after, "let doubled = a * 2;", true, "no fix landed on a line it was not meant for")
    vim.cmd("silent! undo")
    H.eq(before, text(buf), "one undo step restores the file")
  end)
end)

describe("fix-all after an edit", function()
  it("does not trust cargo-check diagnostics for unsaved text, and works after the save", function()
    H.need_rust()
    local dir, buf = H.open_fixture("fix-lab", "src/lib.rs")
    H.start_ra(buf, dir)
    H.wait_for(function()
      return #vim.diagnostic.get(buf) >= 2
    end, 90000, "diagnostics")
    local original = text(buf)
    -- three lines go in above everything: every cargo-check range is now stale
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "// a", "// b", "// c" })
    local edited = text(buf)
    local done
    M.fix_all(buf, {}, function(r)
      done = r
    end)
    H.wait_for(function()
      return done
    end, 90000, "fix all")
    H.is_nil(done.err)
    H.eq(0, done.applied)
    H.ok(done.skipped > 0, "skipped " .. tostring(done.skipped))
    H.eq(edited, text(buf), "nothing was touched")
    -- save: cargo check runs again and publishes the new positions
    vim.cmd("silent write")
    H.wait_for(function()
      for _, d in ipairs(vim.diagnostic.get(buf)) do
        if d.lnum >= 3 and (d.message:find("unused import", 1, true)) then
          return true
        end
      end
    end, 90000, "diagnostics for the saved text")
    done = nil
    M.fix_all(buf, {}, function(r)
      done = r
    end)
    H.wait_for(function()
      return done
    end, 90000, "fix all after save")
    H.is_nil(done.err)
    local after = text(buf)
    H.ok(done.applied >= 2, vim.inspect(done))
    H.match(after, "// a\n// b\n// c\n", true)
    H.not_ok(after:find("use std::fmt::Debug;", 1, true), "the unused import went")
    H.match(after, "pub fn total", true)
    H.match(after, "let doubled = a * 2;", true)
  end)
end)

describe("fix-all merging (fake edits)", function()
  local function r(l1, c1, l2, c2)
    return { start = { line = l1, character = c1 }, ["end"] = { line = l2, character = c2 } }
  end
  local function act(uri, edits, extra)
    return vim.tbl_extend(
      "force",
      { title = "t", edit = { documentChanges = { { textDocument = { uri = uri }, edits = edits } } } },
      extra or {}
    )
  end
  local function scratch(lines)
    local f = H.tmpdir() .. "/a.rs"
    vim.fn.writefile(lines, f)
    vim.cmd.edit(vim.fn.fnameescape(f))
    return vim.api.nvim_get_current_buf()
  end

  it("applies disjoint fixes once, drops identical duplicates and overlapping ones", function()
    local buf = scratch({ "aaa", "bbb", "ccc" })
    local uri = vim.uri_from_bufnr(buf)
    local one = act(uri, { { range = r(0, 0, 0, 3), newText = "A" } })
    local dup = act(uri, { { range = r(0, 0, 0, 3), newText = "A" } })
    local two = act(uri, { { range = r(2, 0, 2, 3), newText = "C" } })
    local over = act(uri, { { range = r(0, 1, 0, 2), newText = "x" } })
    local res
    M._apply_round(buf, uri, { one, dup, two, over }, nil, function(n, err)
      res = { n, err }
    end)
    H.eq(2, res[1])
    H.eq({ "A", "bbb", "C" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("skips fixes that touch another file, run a command or create files", function()
    local buf = scratch({ "aaa" })
    local uri = vim.uri_from_bufnr(buf)
    local other = act("file:///elsewhere.rs", { { range = r(0, 0, 0, 1), newText = "z" } })
    local cmd = act(uri, { { range = r(0, 0, 0, 1), newText = "z" } }, { command = { command = "x" } })
    local file_op = { title = "t", edit = { documentChanges = { { kind = "create", uri = "file:///n.rs" } } } }
    local res
    M._apply_round(buf, uri, { other, cmd, file_op }, "boom", function(n, err)
      res = { n, err }
    end)
    H.eq(0, res[1])
    H.eq("boom", res[2])
    H.eq({ "aaa" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)

describe("commands", function()
  it("are defined", function()
    for _, n in ipairs({ "RustActions", "RustRefactor", "RustFixAll" }) do
      H.ok(vim.api.nvim_get_commands({})[n], n)
    end
  end)
  it("RustFixAll says so without rust-analyzer", function()
    local n = H.capture_notify()
    vim.cmd("RustFixAll")
    H.match(n.list[1].msg, "not attached", true)
  end)
end)

describe("wait_idle", function()
  it("waits for the statusline state to be ready, gives up after the timeout", function()
    local state = "RA cargo check 40%"
    status.rust_analyzer = function()
      return state
    end
    local res
    M.wait_idle(0, 3000, function(ok)
      res = ok
    end)
    vim.defer_fn(function()
      state = "RA ready"
    end, 300)
    H.wait_for(function()
      return res ~= nil
    end, 5000, "idle")
    H.eq(true, res)
    state = "RA loading"
    res = nil
    M.wait_idle(0, 300, function(ok)
      res = ok
    end)
    H.wait_for(function()
      return res ~= nil
    end, 5000, "timeout")
    H.eq(false, res)
  end)
end)
