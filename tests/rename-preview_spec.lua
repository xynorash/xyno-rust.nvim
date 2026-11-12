-- xyno_rust.rename_preview: splitting and combining a WorkspaceEdit (pure), and :RustRename against a real
-- rust-analyzer on the rename-lab fixture: three files change, a file can be unticked, a module rename
-- brings its file operation.
local H = require("xyno_rust_test.helpers")
H.fake_snacks()
require("xyno_rust").setup()
local R = require("xyno_rust.rename_preview")

after_each(function()
  pcall(vim.cmd, "silent! %bwipeout!")
end)

local function edit_of(uri, n)
  local e = {}
  for i = 1, n do
    e[#e + 1] = { range = { start = { line = i - 1, character = 0 }, ["end"] = { line = i - 1, character = 1 } }, newText = "X" }
  end
  return e
end

describe("split / combine", function()
  it("one piece per file in uri order, file operations kept apart", function()
    local a, b = "file:///tmp/a.rs", "file:///tmp/b.rs"
    local files, ops = R.split({
      documentChanges = {
        { textDocument = { uri = b }, edits = edit_of(b, 2) },
        { kind = "rename", oldUri = a, newUri = "file:///tmp/c.rs" },
        { textDocument = { uri = a }, edits = edit_of(a, 1) },
      },
    })
    H.eq({ a, b }, { files[1].uri, files[2].uri })
    H.eq({ 1, 2 }, { files[1].count, files[2].count })
    H.eq("rename", ops.documentChanges[1].kind)
  end)
  it("combine drops unticked files, keeps operations, counts what it left out", function()
    local a, b = "file:///tmp/a.rs", "file:///tmp/b.rs"
    local items = {
      { uri = a, edit = { changes = { [a] = edit_of(a, 1) } }, count = 1 },
      { uri = b, edit = { changes = { [b] = edit_of(b, 1) } }, count = 1, excluded = true },
      { ops = true, edit = { documentChanges = { { kind = "create", uri = "file:///tmp/n.rs" } } }, count = 1 },
    }
    local out, skipped = R.combine(items)
    H.eq(1, skipped)
    H.ok(out.changes[a])
    H.is_nil(out.changes[b])
    H.eq("create", out.documentChanges[1].kind)
  end)
end)

describe(":RustRename (real rust-analyzer)", function()
  local function setup_buf()
    local dir, buf = H.open_fixture("rename-lab", "src/util.rs")
    H.start_ra(buf, dir)
    return dir, buf
  end

  local function wait_analysed(buf)
    H.wait_for(function()
      local r = vim.lsp.buf_request_sync(buf, "textDocument/references", {
        textDocument = vim.lsp.util.make_text_document_params(buf),
        position = { line = 0, character = 8 },
        context = { includeDeclaration = true },
      }, 5000)
      for _, x in pairs(r or {}) do
        if x.result and #x.result >= 5 then
          return true
        end
      end
    end, 90000, "analysis (references of helper)")
  end

  it("previews three files, applies only the ticked ones", function()
    local dir, buf = setup_buf()
    wait_analysed(buf)
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    local got
    R.rename("assist", { pick = function(items, popts) got = { items = items, popts = popts } end })
    H.wait_for(function() return got end, 60000, "rename edit")
    local names = vim.tbl_map(function(i) return i.text end, got.items)
    H.eq({ "src/lib.rs", "src/main.rs", "src/util.rs" }, names)
    local counts = {}
    for _, i in ipairs(got.items) do counts[i.text] = i.count end
    H.eq({ ["src/lib.rs"] = 2, ["src/main.rs"] = 1, ["src/util.rs"] = 2 }, counts)
    H.match(got.items[1].diff, "-    util::helper() + util::helper()", true)
    H.match(got.items[1].diff, "+    util::assist() + util::assist()", true)
    H.match(got.popts.title, "5 edit(s) in 3 file(s)", true)
    -- untick main.rs, apply
    for _, i in ipairs(got.items) do
      if i.text == "src/main.rs" then i.excluded = true end
    end
    local n = H.capture_notify()
    got.popts.confirm({ close = function() end }, nil)
    local function file(rel) return table.concat(vim.fn.readfile(dir .. "/" .. rel), "\n") end
    -- applied to buffers (not written): read the buffers
    local function buftext(rel)
      local b = vim.fn.bufnr(dir .. "/" .. rel)
      return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
    end
    H.match(buftext("src/lib.rs"), "util::assist() + util::assist()", true)
    H.match(buftext("src/util.rs"), "pub fn assist()", true)
    H.match(buftext("src/util.rs"), "assist() * 2", true)
    H.match(file("src/main.rs"), "util::helper()", true)
    H.eq(1, #vim.tbl_filter(function(x) return x.msg:find("1 file(s) were left out", 1, true) end, n.list))
  end)

  it("a module rename carries its file operation", function()
    local dir, buf = setup_buf()
    wait_analysed(buf)
    local lib = H.open(dir .. "/src/lib.rs")
    vim.lsp.buf_attach_client(lib, vim.lsp.get_clients({ bufnr = buf, name = "rust-analyzer" })[1].id)
    vim.api.nvim_win_set_cursor(0, { 1, 8 }) -- `util` in `pub mod util;`
    local got
    H.wait_for(function()
      if got then return true end
      R.rename("tools", { pick = function(items) got = items end })
      vim.wait(1500, function() return got ~= nil end)
      return got
    end, 90000, "module rename edit (retried until rust-analyzer has indexed the module)")
    local ops
    for _, i in ipairs(got) do
      if i.ops then ops = i end
    end
    H.ok(ops, "file operation entry: " .. vim.inspect(vim.tbl_map(function(i) return i.text end, got)))
    H.match(ops.diff, "rename ", true)
    H.match(ops.diff, "tools.rs", true)
    H.eq(lib ~= nil, true)
  end)

  it("without rust-analyzer it says so; with a name given there is no prompt", function()
    vim.cmd("enew")
    local n = H.capture_notify()
    vim.cmd("RustRename x")
    H.match(n.list[1].msg, "not attached", true)
  end)
end)
