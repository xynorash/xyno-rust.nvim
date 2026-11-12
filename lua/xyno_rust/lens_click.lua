-- Click a code lens: rust-analyzer's "Run | Debug" (and "Run Test", references, implementations) line
-- above a function runs the command under the mouse. A click anywhere else is the normal click.
--
-- Neovim draws the lens as a virtual line above the code line (vim.lsp.codelens: spaces up to the first
-- lens, then the titles joined by " | "). A click on such a row is reported as a click on the code line
-- below it, so the handler tells the two apart by the screen row (above the line's own row = a virtual
-- line) and finds the lens by the screen column. Buffer-local `<LeftMouse>` in Rust buffers, set on
-- FileType; every other click falls through to Neovim's own handling.
--
-- Needs 'mouse' to include "n" (Neovim's default `nvi` does; this plugin does not change it).
local M = {}

M.SEP = " | "

--- The lenses of `row` (0-based) that have a command, in the order the virtual line shows them, each with the
--- display columns it covers: { lens, client_id, from, to } (from inclusive, to exclusive).
---@param entries { client_id: integer, lens: table }[] vim.lsp.codelens.get() results
---@param row integer
---@param first_col integer display columns before the first title (the indentation of the lens)
function M.spans(entries, row, first_col)
  local list = {}
  for _, e in ipairs(entries) do
    if e.lens.range.start.line == row and e.lens.command then
      list[#list + 1] = e
    end
  end
  table.sort(list, function(a, b)
    return a.lens.range.start.character < b.lens.range.start.character
  end)
  local out, col = {}, first_col
  for i, e in ipairs(list) do
    local w = vim.fn.strdisplaywidth(e.lens.command.title)
    out[#out + 1] = { lens = e.lens, client_id = e.client_id, from = col, to = col + w }
    col = col + w + (i < #list and vim.fn.strdisplaywidth(M.SEP) or 0)
  end
  return out
end

--- The span under display column `col`, or nil. A click on the separator is not a hit.
function M.hit(spans, col)
  for _, s in ipairs(spans) do
    if col >= s.from and col < s.to then
      return s
    end
  end
end

--- Where a mouse position is, relative to the lens of its line: returns the span hit, or nil.
---@param pos table vim.fn.getmousepos()
function M.under_mouse(pos)
  if not pos or pos.winid == 0 or pos.line == 0 then
    return nil
  end
  local win = pos.winid
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].filetype ~= "rust" or not (vim.lsp.codelens and vim.lsp.codelens.get) then
    return nil
  end
  local row = pos.line - 1
  local entries = vim.lsp.codelens.get({ bufnr = buf })
  if #entries == 0 then
    return nil
  end
  local line_screen = vim.fn.screenpos(win, pos.line, 1).row
  if line_screen == 0 or pos.screenrow >= line_screen then
    return nil -- the code line itself (or a folded / hidden one)
  end
  local info = vim.fn.getwininfo(win)[1]
  local leftcol = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview().leftcol
  end)
  local text = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local first
  for _, e in ipairs(entries) do
    if e.lens.range.start.line == row and e.lens.command and (not first or e.lens.range.start.character < first.lens.range.start.character) then
      first = e
    end
  end
  if not first then
    return nil
  end
  local client = vim.lsp.get_client_by_id(first.client_id)
  local enc = client and client.offset_encoding or "utf-16"
  local ok, bytecol = pcall(vim.str_byteindex, text, enc, first.lens.range.start.character, false)
  -- the lens line pads with that many SPACES (bytes), exactly as vim.lsp.codelens does
  local pad = ok and bytecol or first.lens.range.start.character
  local col = pos.wincol - 1 - info.textoff + leftcol
  return M.hit(M.spans(entries, row, pad), col)
end

--- Run a span's command (as vim.lsp.codelens.run does).
function M.exec(span, buf)
  local client = vim.lsp.get_client_by_id(span.client_id)
  if not client then
    return false
  end
  client:exec_cmd(span.lens.command, { bufnr = buf })
  return true
end

--- The <LeftMouse> mapping: returns "" after running a lens, else the key itself (normal click).
function M.click()
  local span = M.under_mouse(vim.fn.getmousepos())
  if span then
    local buf = vim.api.nvim_win_get_buf(vim.fn.getmousepos().winid)
    M.exec(span, buf)
    return ""
  end
  return "<LeftMouse>"
end

function M.setup(opts)
  local group = vim.api.nvim_create_augroup("xyno_rust_lens_click", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "rust",
    callback = function(ev)
      vim.keymap.set("n", "<LeftMouse>", function()
        return require("xyno_rust.lens_click").click()
      end, { buffer = ev.buf, expr = true, replace_keycodes = true, desc = "Click a code lens (Run / Debug); otherwise a normal click" })
    end,
  })
end

return M
