-- Rust navigation helpers that rust-analyzer has no single request for.
local M = {}

local function ra_client(buf)
  return vim.lsp.get_clients({ bufnr = buf, name = "rust-analyzer" })[1]
end

--- Go to super method (same idea as Ctrl+U in the JetBrains IDEs): from a method inside
--- `impl Trait for T`, jump to the same method in the trait definition.
function M.goto_super()
  local buf = vim.api.nvim_get_current_buf()
  local client = ra_client(buf)
  local node = vim.treesitter.get_node()
  while node and node:type() ~= "function_item" do
    node = node:parent()
  end
  if not (client and node) then
    return vim.notify("not inside a function", vim.log.levels.WARN)
  end
  local impl = node:parent()
  while impl and impl:type() ~= "impl_item" do
    impl = impl:parent()
  end
  local trait = impl and impl:field("trait")[1]
  if not trait then
    return vim.notify("not a trait impl method", vim.log.levels.WARN)
  end
  -- Land on the trait's own identifier: `fmt::Display`, `From<T>` -> `Display`, `From`.
  while trait:type() ~= "type_identifier" do
    local nxt = trait:field(trait:type() == "generic_type" and "type" or "name")[1]
    if not nxt then
      break
    end
    trait = nxt
  end
  local name = vim.treesitter.get_node_text(node:field("name")[1], buf)
  local row, col = trait:start()
  local params = {
    textDocument = vim.lsp.util.make_text_document_params(buf),
    position = { line = row, character = col },
  }
  client:request("textDocument/definition", params, function(err, res)
    -- a list (first entry) or a single Location; `{}` is "not found" (the
    -- `islist and res[1] or res` form returned the empty list itself)
    local loc = res
    if type(res) == "table" and vim.islist(res) then
      loc = res[1]
    end
    if err or not loc then
      return vim.notify("trait definition not found", vim.log.levels.WARN)
    end
    vim.lsp.util.show_document(loc, client.offset_encoding, { focus = true })
    -- skip doc comments that mention `fn name` (std's Display::fmt has them first)
    local pat = "\\<fn\\s\\+" .. name .. "\\>"
    vim.fn.search(pat, "cw")
    -- (by line text: the freshly shown buffer has no treesitter parser yet, so
    -- get_node() was nil and the first match was always kept)
    for _ = 1, 50 do
      if not vim.api.nvim_get_current_line():match("^%s*/[/*]") and not vim.api.nvim_get_current_line():match("^%s*%*") then
        break
      end
      if vim.fn.search(pat, "w") == 0 then
        break
      end
    end
    vim.cmd("normal! zz")
  end, buf)
end

--- Reads/writes of the symbol under the cursor in this file, labelled
--- [R]/[W], in the quickfix list (same idea as usage-type grouping in the JetBrains IDEs).
function M.local_usages()
  local buf = vim.api.nvim_get_current_buf()
  local client = ra_client(buf)
  if not client then
    return
  end
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  client:request("textDocument/documentHighlight", params, function(err, res)
    if err or not res or #res == 0 then
      return vim.notify("no usages in this file", vim.log.levels.INFO)
    end
    -- rust-analyzer sends no kind on the declaration (`let x`): that is a write
    local kind = { [1] = "T", [2] = "R", [3] = "W" }
    local items = {}
    for _, h in ipairs(res) do
      local lnum = h.range.start.line + 1
      items[#items + 1] = {
        bufnr = buf,
        lnum = lnum,
        col = h.range.start.character + 1,
        text = ("[%s] %s"):format(kind[h.kind or 3], vim.trim(vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or "")),
      }
    end
    table.sort(items, function(a, b)
      return a.lnum < b.lnum
    end)
    vim.fn.setqflist({}, " ", { title = "usages (this file)", items = items })
    vim.cmd("copen")
  end, buf)
end

-- ----------------------------------------------------- usages, grouped (project-wide)

M.GROUPS = { "code", "import", "tests", "docs" }

--- Which group a usage belongs to (the JetBrains Find window groups by usage type and by file kind):
--- `import` = a `use` line, `docs` = a doc comment line, `tests` = a file under tests/ or benches/
--- (or an example), else `code`.
---@param path string
---@param text string the source line
function M.usage_group(path, text)
  if text:match("^%s*///") or text:match("^%s*//!") then
    return "docs"
  elseif text:match("^%s*pub%s*%(?[%w%s]*%)?%s*use%s") or text:match("^%s*use%s") then
    return "import"
  elseif path:match("/tests/") or path:match("/benches/") or path:match("/examples/") or path:match("^tests/") then
    return "tests"
  end
  return "code"
end

--- Reference locations -> items sorted by group, file, line, and the summary line.
---@param locs table[] LSP Locations
---@param lines_of fun(uri: string): string[]  the lines of a file
---@param rel fun(path: string): string
function M.group_usages(locs, lines_of, rel)
  local items, counts, files = {}, {}, {}
  for _, g in ipairs(M.GROUPS) do
    counts[g] = 0
  end
  for _, l in ipairs(locs) do
    local uri = l.uri or l.targetUri
    local range = l.range or l.targetSelectionRange
    local path = rel(vim.uri_to_fname(uri))
    local text = (lines_of(uri)[range.start.line + 1] or "")
    local g = M.usage_group("/" .. path, text)
    counts[g] = counts[g] + 1
    files[path] = true
    items[#items + 1] = { group = g, path = path, lnum = range.start.line + 1, col = range.start.character, text = vim.trim(text), uri = uri, range = range }
  end
  local order = {}
  for i, g in ipairs(M.GROUPS) do
    order[g] = i
  end
  table.sort(items, function(a, b)
    if a.group ~= b.group then
      return order[a.group] < order[b.group]
    end
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.lnum < b.lnum
  end)
  local nfiles = vim.tbl_count(files)
  local parts = {}
  for _, g in ipairs(M.GROUPS) do
    if counts[g] > 0 then
      parts[#parts + 1] = ("%s %d"):format(g, counts[g])
    end
  end
  return items, ("%d usage(s) in %d file(s): %s"):format(#items, nfiles, table.concat(parts, ", "))
end

--- Specs replace these two.
function M.request_references(buf, client, cb)
  local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
  params.context = { includeDeclaration = false }
  client:request("textDocument/references", params, function(err, res)
    cb(res, err)
  end, buf)
end

function M.file_lines(uri)
  local b = vim.uri_to_bufnr(uri)
  if vim.api.nvim_buf_is_loaded(b) then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, vim.uri_to_fname(uri))
  return ok and lines or {}
end

--- :RustUsages - every usage in the workspace, grouped (code / imports / tests / docs), a picker with the
--- summary in its title. opts.pick (specs): function(items, picker_opts).
function M.all_usages(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local client = ra_client(buf)
  if not client then
    return vim.notify("xyno-rust: rust-analyzer is not attached to this buffer", vim.log.levels.WARN)
  end
  local word = vim.fn.expand("<cword>")
  M.request_references(buf, client, function(res, err)
    vim.schedule(function()
      if err or not res or #res == 0 then
        return vim.notify("xyno-rust: no usages found" .. (err and (": " .. tostring(err.message or err)) or ""), vim.log.levels.INFO)
      end
      local cwd = vim.fs.normalize(vim.fn.getcwd())
      local items, summary = M.group_usages(res, M.file_lines, function(p)
        p = vim.fs.normalize(p)
        return p:sub(1, #cwd + 1) == cwd .. "/" and p:sub(#cwd + 2) or p
      end)
      for _, it in ipairs(items) do
        it.file = vim.uri_to_fname(it.uri)
        it.pos = { it.lnum, it.col }
        it.line_text = it.text
        it.text = ("%s %s:%d %s"):format(it.group, it.path, it.lnum, it.line_text)
      end
      local picker_opts = {
        title = ("Usages of %s: %s"):format(word, summary),
        items = items,
        format = function(item)
          return {
            { ("%-6s "):format(item.group), item.group == "code" and "DiagnosticOk" or "Comment" },
            { item.path .. ":" .. item.lnum, "Directory" },
            { "  " .. item.line_text },
          }
        end,
        preview = "file",
        layout = { preset = "default", preview = true },
      }
      if opts.pick then
        return opts.pick(items, picker_opts, summary)
      end
      local Snacks = require("xyno_rust.deps").snacks()
      if Snacks then
        Snacks.picker(picker_opts)
      end
    end)
  end)
end

return M
