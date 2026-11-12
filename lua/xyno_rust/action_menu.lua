-- Code actions with a diff preview, a refactor-only menu, and "fix all".
--
--   :RustActions     every code action at the cursor / selection, each with the diff it would make
--   :RustRefactor    only refactor.* (extract, inline, rewrite, ...), same preview
--   :RustFixAll      apply rust-analyzer's PREFERRED quick fixes for the diagnostics of this buffer,
--                    as one undo step (rust-analyzer has no source.fixAll; this is built from its
--                    per-diagnostic quick fixes)
--
-- The preview is computed from the action's own edit (after codeAction/resolve, which rust-analyzer
-- needs to fill the edit in): the edit is applied to a scratch copy of every file it touches and the
-- two texts are diffed, so what you see is what applying would do. An action that only runs a command
-- (no text edit) says so instead of showing a diff.
local ca = require("xyno_rust.code_actions")

local M = {}

-- ------------------------------------------------------------------- edits

--- A snippet text edit (insertTextFormat 2) as plain text: `${1:name}` -> `name`, `$0` / `${0}` / `$1` -> ``,
--- `\$` -> `$`. The client has no tab-stop support here, so applying keeps the default text.
---@param s string
function M.strip_snippet(s)
  s = s:gsub("\\([%$%}\\])", "\1%1\2") -- protect escapes
  s = s:gsub("%${%d+:([^}]*)}", "%1"):gsub("%${%d+}", ""):gsub("%$%d+", "")
  s = s:gsub("\1(.)\2", "%1")
  return s
end

--- Deep copy of `edit` with snippet text edits made plain (see strip_snippet).
function M.plain_edit(edit)
  local copy = vim.deepcopy(edit)
  local function fix(edits)
    for _, e in ipairs(edits or {}) do
      if e.insertTextFormat == 2 and type(e.newText) == "string" then
        e.newText = M.strip_snippet(e.newText)
      end
      e.insertTextFormat = nil
    end
  end
  for _, dc in ipairs(copy.documentChanges or {}) do
    fix(dc.edits)
  end
  for _, edits in pairs(copy.changes or {}) do
    fix(edits)
  end
  return copy
end

--- The lines of a file as it is now: the buffer when it is loaded, else the file ('' for a new file).
local function current_lines(uri)
  local buf = vim.uri_to_bufnr(uri)
  if vim.api.nvim_buf_is_loaded(buf) then
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, vim.uri_to_fname(uri))
  return ok and lines or {}
end

local function rel(path)
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  path = vim.fs.normalize(path)
  if path:sub(1, #cwd + 1) == cwd .. "/" then
    return path:sub(#cwd + 2)
  end
  return path
end

--- Text edits applied to `lines` in a scratch buffer; returns the new lines.
local function apply_to_lines(lines, edits, enc)
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, res = pcall(function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.lsp.util.apply_text_edits(edits, buf, enc)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end)
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  if not ok then
    error(res, 0)
  end
  return res
end

--- The unified diff of a WorkspaceEdit, one `--- / +++` block per file, plus a line for each file
--- operation (create / rename / delete). Returns nil when the edit changes nothing.
---@param edit table WorkspaceEdit
---@param enc? string offset encoding of the client that sent it
---@return string?
function M.edit_diff(edit, enc)
  enc = enc or "utf-16"
  edit = M.plain_edit(edit)
  local out = {}
  local per_file, order = {}, {}
  local function add(uri, edits)
    if not per_file[uri] then
      per_file[uri] = {}
      order[#order + 1] = uri
    end
    vim.list_extend(per_file[uri], edits)
  end
  for _, dc in ipairs(edit.documentChanges or {}) do
    if dc.kind == "create" then
      out[#out + 1] = "create " .. rel(vim.uri_to_fname(dc.uri))
    elseif dc.kind == "rename" then
      out[#out + 1] = ("rename %s -> %s"):format(rel(vim.uri_to_fname(dc.oldUri)), rel(vim.uri_to_fname(dc.newUri)))
    elseif dc.kind == "delete" then
      out[#out + 1] = "delete " .. rel(vim.uri_to_fname(dc.uri))
    elseif dc.textDocument and dc.edits then
      add(dc.textDocument.uri, dc.edits)
    end
  end
  for uri, edits in pairs(edit.changes or {}) do
    add(uri, edits)
  end
  table.sort(order)
  for _, uri in ipairs(order) do
    local old = current_lines(uri)
    local ok, new = pcall(apply_to_lines, old, per_file[uri], enc)
    local name = rel(vim.uri_to_fname(uri))
    if not ok then
      out[#out + 1] = ("(%s: the edit does not fit the file: %s)"):format(name, tostring(new))
    else
      local d = vim.diff(
        table.concat(old, "\n") .. "\n",
        table.concat(new, "\n") .. "\n",
        { result_type = "unified", ctxlen = 3 }
      )
      if d and d ~= "" then
        out[#out + 1] = ("--- a/%s\n+++ b/%s\n%s"):format(name, name, d:gsub("\n$", ""))
      end
    end
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out, "\n")
end

-- ------------------------------------------------------------------- items

--- Picker order: preferred fixes first, then by kind (quickfix, refactor.*, other), then as sent.
function M.sort(list)
  local function rank(a)
    local k = a.kind or ""
    return (k:find("^quickfix") and 0) or (k:find("^refactor") and 1) or 2
  end
  local idx = {}
  for i, a in ipairs(list) do
    idx[a] = i
  end
  table.sort(list, function(a, b)
    if a.is_preferred ~= b.is_preferred then
      return a.is_preferred
    end
    if rank(a) ~= rank(b) then
      return rank(a) < rank(b)
    end
    return idx[a] < idx[b]
  end)
  return list
end

local function title_of(a)
  return a.title:gsub("\n.*", "")
end

--- What the preview shows for an action, once resolved.
local function preview_text(a, client)
  if a.edit then
    local d = M.edit_diff(a.edit, client and client.offset_encoding)
    if d then
      return d
    end
  end
  if a.command and a.command.command then
    return "(no text change here: runs the server command `" .. a.command.command .. "`)"
  end
  return "(this action changes no text)"
end

--- The picker items of an action list.
function M.items(list)
  local items = {}
  for i, a in ipairs(list) do
    items[i] = {
      idx = i,
      text = title_of(a) .. " " .. (a.kind or ""),
      title = title_of(a),
      kind = a.kind or "",
      preferred = a.is_preferred,
      action = a,
    }
  end
  return items
end

-- --------------------------------------------------------------------- menu

--- Position of the selection or the cursor, as ca.request wants it.
local function current_range()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local a, b = vim.fn.getpos("v"), vim.fn.getpos(".")
    local s, e = { a[2] - 1, a[3] - 1 }, { b[2] - 1, b[3] - 1 }
    if s[1] > e[1] or (s[1] == e[1] and s[2] > e[2]) then
      s, e = e, s
    end
    if mode == "V" then
      s[2] = 0
      e[2] = #(vim.api.nvim_buf_get_lines(0, e[1], e[1] + 1, false)[1] or "")
    else
      e[2] = e[2] + 1
    end
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    return { start = s, ["end"] = e }
  end
  local c = vim.api.nvim_win_get_cursor(0)
  return { c[1] - 1, c[2] }
end

--- Diagnostics under the range, for the request context.
local function diagnostics_at(buf, range)
  local from = range.start or range
  local to = range["end"] or range
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(buf)) do
    local dend_l, dend_c = d.end_lnum or d.lnum, d.end_col or d.col
    local after_start = dend_l > from[1] or (dend_l == from[1] and dend_c >= from[2])
    local before_end = d.lnum < to[1] or (d.lnum == to[1] and d.col <= to[2])
    if after_start and before_end then
      out[#out + 1] = d
    end
  end
  return out
end

--- Apply a chosen action: its edit as plain text (see strip_snippet), then its command.
function M.apply(a, cb)
  ca.resolve_async(a, function(r, err)
    if not r then
      return cb(false, err)
    end
    local copy = vim.tbl_extend("force", {}, r)
    if copy.edit then
      copy.edit = M.plain_edit(copy.edit)
    end
    ca.apply_async(copy, cb)
  end)
end

--- Open the menu. opts: only (kind prefixes), title, range (default: selection or cursor),
--- filter (function(action) -> boolean), pick (testing: function(items, opts) instead of the picker).
function M.open(opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  local range = opts.range or current_range()
  ca.request(buf, range, { diagnostics = diagnostics_at(buf, range), only = opts.only }, function(list, errs)
    if opts.filter then
      list = vim.tbl_filter(opts.filter, list)
    end
    if #list == 0 then
      local busy = errs and errs[1] and errs[1].message
      return vim.notify(
        busy and ("xyno-rust: no code actions (%s)"):format(busy)
          or "xyno-rust: no " .. (opts.only and "refactorings" or "code actions") .. " here",
        vim.log.levels.INFO
      )
    end
    M.sort(list)
    local items = M.items(list)
    local picker_opts = {
      title = opts.title or "Code actions (preview: the diff)",
      items = items,
      format = function(item)
        return {
          { item.preferred and "* " or "  ", "DiagnosticOk" },
          { item.title },
          { "  " .. item.kind, "Comment" },
        }
      end,
      layout = { preset = "default", preview = true },
      preview = function(ctx)
        local item = ctx.item
        ctx.preview:reset()
        ctx.preview:minimal()
        ctx.preview:set_title(item.title)
        local function show(text)
          ctx.preview:set_lines(vim.split(text, "\n", { plain = true }))
          ctx.preview:highlight({ ft = "diff" })
        end
        if item.diff then
          return show(item.diff)
        end
        show("resolving ...")
        ca.resolve_async(item.action, function(r, err)
          item.diff = r and preview_text(r, vim.lsp.get_client_by_id(r.client_id))
            or ("(could not resolve: %s)"):format(tostring(err))
          if ctx.picker and not ctx.picker.closed and ctx.picker:current() == item then
            vim.schedule(function()
              if ctx.preview.win and ctx.preview.win:buf_valid() then
                show(item.diff)
              end
            end)
          end
        end)
      end,
      confirm = function(picker, item)
        picker:close()
        if not item then
          return
        end
        M.apply(item.action, function(ok, err)
          if not ok then
            vim.notify("xyno-rust: " .. item.title .. " failed: " .. tostring(err), vim.log.levels.ERROR)
          end
        end)
      end,
    }
    if opts.pick then
      return opts.pick(items, picker_opts)
    end
    local Snacks = require("xyno_rust.deps").snacks()
    if Snacks then
      Snacks.picker(picker_opts)
    end
  end)
end

function M.actions()
  M.open({})
end

function M.refactor()
  M.open({ only = { "refactor" }, title = "Refactor (preview: the diff)" })
end

-- ------------------------------------------------------------------ fix all

local function pos_cmp(a, b)
  if a.line ~= b.line then
    return a.line < b.line and -1 or 1
  end
  if a.character ~= b.character then
    return a.character < b.character and -1 or 1
  end
  return 0
end

--- Whether two sets of text edits overlap (touching ranges do not).
local function overlap(a, b)
  for _, x in ipairs(a) do
    for _, y in ipairs(b) do
      if pos_cmp(x.range.start, y.range["end"]) < 0 and pos_cmp(y.range.start, x.range["end"]) < 0 then
        return true
      end
      -- two insertions at one point would be applied in an arbitrary order
      if
        pos_cmp(x.range.start, x.range["end"]) == 0
        and pos_cmp(x.range.start, y.range.start) == 0
        and pos_cmp(y.range.start, y.range["end"]) == 0
      then
        return true
      end
    end
  end
  return false
end

--- The text edits of a resolved action when it is safe to merge: only this buffer, no file operations,
--- no command. nil otherwise.
local function buffer_edits(a, uri)
  if not a.edit or (a.command and a.command.command) then
    return nil
  end
  local edit = M.plain_edit(a.edit)
  local edits
  for _, dc in ipairs(edit.documentChanges or {}) do
    if dc.kind or not dc.textDocument or dc.textDocument.uri ~= uri then
      return nil
    end
    edits = vim.list_extend(edits or {}, dc.edits)
  end
  for u, e in pairs(edit.changes or {}) do
    if u ~= uri then
      return nil
    end
    edits = vim.list_extend(edits or {}, e)
  end
  return edits
end

local function same_edits(a, b)
  return vim.deep_equal(a, b)
end

-- Which diagnostics can be trusted right now. rust-analyzer answers a quick-fix request for a stale
-- diagnostic with an edit for the OLD positions (checked on a real server: three lines inserted above,
-- the fix deleted two of them). The diagnostics of `cargo check` (source "rustc", "clippy", bacon-ls)
-- describe the text that was last SAVED and checked; they do not move when you type. So:
--   * with unsaved changes only rust-analyzer's own diagnostics are used (it re-publishes on every change);
--   * the others wait for the save, and for the check that follows it (rust-analyzer's progress);
--   * the server must be idle ("RA ready" in the statusline component), else the command waits for it.
local NATIVE = { ["rust-analyzer"] = true }

--- cb(true) when rust-analyzer is idle (waits up to `timeout` ms, polling), cb(false) otherwise.
function M.wait_idle(buf, timeout, cb)
  local ok, status = pcall(require, "xyno_rust.lsp_status")
  local function idle()
    if not ok then
      return true
    end
    local s = status.rust_analyzer(buf)
    return s == nil or s:find("^RA ready") ~= nil
  end
  if idle() then
    return cb(true)
  end
  local waited = 0
  local timer = assert(vim.uv.new_timer())
  timer:start(100, 100, function()
    waited = waited + 100
    vim.schedule(function()
      if timer:is_closing() then
        return
      end
      if idle() or waited >= timeout then
        timer:stop()
        timer:close()
        cb(idle())
      end
    end)
  end)
end

--- A diagnostic for the request: nvim keeps diagnostics on extmarks, so lnum / col follow edits made
--- since the server published them, while the original LSP diagnostic (user_data.lsp) keeps the old
--- range. Same payload, current range.
local function fresh(d, buf, enc)
  local copy = vim.deepcopy(d)
  local lsp = type(copy.user_data) == "table" and (copy.user_data.lsp or copy.user_data)
  if type(lsp) == "table" and lsp.range then
    local function pos(l, c)
      local line = vim.api.nvim_buf_get_lines(buf, l, l + 1, false)[1] or ""
      c = math.min(c, #line)
      local ok, ch = pcall(vim.str_utfindex, line, enc, c, false)
      return { line = l, character = ok and ch or c }
    end
    lsp.range = { start = pos(d.lnum, d.col), ["end"] = pos(d.end_lnum or d.lnum, d.end_col or d.col) }
  end
  return copy
end

--- Apply the preferred quick fixes of every trustworthy diagnostic of `buf` (see above) whose edit
--- stays inside the buffer, as ONE text edit (one undo step). Identical fixes (rust-analyzer reports a
--- hint diagnostic next to the warning) are applied once, overlapping ones are left for a second run.
--- One round: after the edit the diagnostics are stale until rust-analyzer / cargo check publish
--- again, so chaining is running the command again. Nothing is applied if the buffer changes while
--- the fixes are being collected. cb({ applied, remaining, skipped, err? }): `skipped` counts the
--- diagnostics left out because they describe the saved text and the buffer has unsaved changes.
---@param buf integer
---@param opts? { severity?: integer, wait_ms?: integer }
---@param cb fun(res: { applied: integer, remaining: integer, skipped: integer, err?: string })
function M.fix_all(buf, opts, cb)
  opts = opts or {}
  local skipped = 0
  local function finish(n, err)
    cb({
      applied = n,
      remaining = vim.api.nvim_buf_is_valid(buf) and #vim.diagnostic.get(buf) or 0,
      skipped = skipped,
      err = err,
    })
  end
  M.wait_idle(buf, opts.wait_ms or 8000, function(idle)
    if not idle then
      return finish(0, "rust-analyzer is still working (see the statusline); try again when it says RA ready")
    end
    if not vim.api.nvim_buf_is_valid(buf) then
      return finish(0, "buffer is gone")
    end
    local uri = vim.uri_from_bufnr(buf)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local unsaved = vim.bo[buf].modified
    local diags = {}
    for _, d in ipairs(vim.diagnostic.get(buf)) do
      if not opts.severity or d.severity <= opts.severity then
        if unsaved and not NATIVE[d.source or ""] then
          skipped = skipped + 1
        else
          diags[#diags + 1] = d
        end
      end
    end
    if #diags == 0 then
      return finish(0)
    end
    local client = ca.clients(buf)[1]
    local enc = client and client.offset_encoding or "utf-16"
    local pending, picked, failed = #diags, {}, nil
    local function one_done()
      pending = pending - 1
      if pending > 0 then
        return
      end
      if not vim.api.nvim_buf_is_valid(buf) or vim.api.nvim_buf_get_changedtick(buf) ~= tick then
        return finish(0, "the buffer changed while the fixes were collected; run it again")
      end
      M._apply_round(buf, uri, picked, failed, finish)
    end
    for _, d in ipairs(diags) do
      local range = { start = { d.lnum, d.col }, ["end"] = { d.end_lnum or d.lnum, d.end_col or d.col } }
      ca.request(buf, range, { diagnostics = { fresh(d, buf, enc) }, only = { "quickfix" } }, function(list, errs)
        failed = failed or (errs and #list == 0 and errs[1] and errs[1].message) or nil
        local pref = vim.tbl_filter(function(a)
          return a.is_preferred
        end, list or {})
        if #pref == 0 then
          return one_done()
        end
        ca.resolve_async(pref[1], function(r)
          picked[#picked + 1] = r
          one_done()
        end)
      end)
    end
  end)
end

--- Merge the edits of `actions` (resolved) into one apply. cb(n_applied, err).
function M._apply_round(buf, uri, actions, failed, cb)
  local chosen, merged = {}, {}
  for _, a in ipairs(actions) do
    local edits = a and buffer_edits(a, uri)
    if edits then
      local dup, clash = false, false
      for _, c in ipairs(chosen) do
        if same_edits(c, edits) then
          dup = true
        elseif overlap(c, edits) then
          clash = true
        end
      end
      if not dup and not clash then
        chosen[#chosen + 1] = edits
        vim.list_extend(merged, edits)
      end
    end
  end
  if #chosen == 0 then
    return cb(0, failed)
  end
  local client = ca.clients(buf)[1]
  local ok, err = pcall(vim.lsp.util.apply_text_edits, merged, buf, client and client.offset_encoding or "utf-16")
  if not ok then
    return cb(0, tostring(err))
  end
  cb(#chosen)
end

--- :RustFixAll: report in one line. Writes nothing to disk.
function M.fix_all_cmd()
  local buf = vim.api.nvim_get_current_buf()
  if #ca.clients(buf) == 0 then
    return vim.notify("xyno-rust: rust-analyzer is not attached", vim.log.levels.WARN)
  end
  M.fix_all(buf, {}, function(res)
    if res.err then
      return vim.notify("xyno-rust: fix all: " .. res.err, vim.log.levels.WARN)
    end
    local left = ("%d diagnostic%s left"):format(res.remaining, res.remaining == 1 and "" or "s")
    if res.skipped > 0 then
      left = left
        .. ("; %d from cargo check skipped: they describe the saved text, save (:w) and run again"):format(res.skipped)
    end
    if res.applied == 0 then
      return vim.notify(
        ("xyno-rust: no preferred quick fix to apply (%s; <leader>ca lists their fixes)"):format(left),
        vim.log.levels.INFO
      )
    end
    vim.notify(
      ("xyno-rust: applied %d quick fix%s as one undo step (%s, some may disappear once rust-analyzer re-analyses; run it again to chain)"):format(
        res.applied,
        res.applied == 1 and "" or "es",
        left
      ),
      vim.log.levels.INFO
    )
  end)
end

function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  vim.api.nvim_create_user_command("RustActions", M.actions, { desc = "Code actions with a diff preview" })
  vim.api.nvim_create_user_command(
    "RustRefactor",
    M.refactor,
    { range = true, desc = "Refactorings with a diff preview" }
  )
  vim.api.nvim_create_user_command(
    "RustFixAll",
    M.fix_all_cmd,
    { desc = "Apply the preferred quick fixes of this buffer" }
  )
end

return M
