-- Rename with a preview of every file it touches (VS Code's Refactor Preview idea): the new name is typed,
-- the server's WorkspaceEdit is fetched but NOT applied, and a picker lists the files with their diffs.
--
--   :RustRename [new_name]
--
--   picker:  <CR> apply the files that are ticked     <Tab> / <C-space> untick / tick the file under the cursor
--            the preview is the diff the edit makes to that file; file operations (a module rename moves
--            its file) are listed as their own entry and always apply.
--
-- Unticked files keep their old text, which can leave the code not compiling (the picker says how many
-- files it left out). Applying is one vim.lsp.util.apply_workspace_edit call; undo per buffer as usual.
-- inc-rename (a live preview in the buffer) is still the better tool for a rename inside one file;
-- this is for "what exactly will change in the other files".
local am = require("xyno_rust.action_menu")

local M = {}

M.client_name = "rust-analyzer"

--- Specs replace this to fake a server.
function M.client(buf)
  return vim.lsp.get_clients({ bufnr = buf, name = M.client_name })[1]
end

--- Split a WorkspaceEdit into one piece per file plus the file operations.
---@return { uri: string, edit: table, count: integer }[], table? ops  (ops is a WorkspaceEdit of file operations only)
function M.split(edit)
  local per, order = {}, {}
  local ops = {}
  local function add(uri, edits)
    if not per[uri] then
      per[uri] = {}
      order[#order + 1] = uri
    end
    vim.list_extend(per[uri], edits)
  end
  for _, dc in ipairs(edit.documentChanges or {}) do
    if dc.kind then
      ops[#ops + 1] = dc
    elseif dc.textDocument and dc.edits then
      add(dc.textDocument.uri, dc.edits)
    end
  end
  for uri, edits in pairs(edit.changes or {}) do
    add(uri, edits)
  end
  table.sort(order)
  local files = {}
  for _, uri in ipairs(order) do
    files[#files + 1] = { uri = uri, count = #per[uri], edit = { changes = { [uri] = per[uri] } } }
  end
  return files, (#ops > 0) and { documentChanges = ops } or nil
end

--- Items of the picker. `diff` is computed now: a rename touches a handful of files.
function M.items(edit, enc)
  local files, ops = M.split(edit)
  local items = {}
  local function rel(uri)
    local p = vim.fs.normalize(vim.uri_to_fname(uri))
    local cwd = vim.fs.normalize(vim.fn.getcwd())
    return p:sub(1, #cwd + 1) == cwd .. "/" and p:sub(#cwd + 2) or p
  end
  for _, f in ipairs(files) do
    items[#items + 1] = {
      text = rel(f.uri),
      uri = f.uri,
      edit = f.edit,
      count = f.count,
      diff = am.edit_diff(f.edit, enc) or "(no change)",
    }
  end
  if ops then
    items[#items + 1] = { text = "file operations", ops = true, edit = ops, count = #ops.documentChanges, diff = am.edit_diff(ops, enc) or "(none)" }
  end
  return items
end

--- The WorkspaceEdit made of the items that are not excluded (file operations always stay).
function M.combine(items)
  local out = { changes = {}, documentChanges = nil }
  local dcs = {}
  local skipped = 0
  for _, it in ipairs(items) do
    if it.ops then
      vim.list_extend(dcs, it.edit.documentChanges)
    elseif it.excluded then
      skipped = skipped + 1
    else
      for uri, edits in pairs(it.edit.changes) do
        out.changes[uri] = edits
      end
    end
  end
  if #dcs > 0 then
    out.documentChanges = dcs
  end
  return out, skipped
end

function M.apply(edit, enc)
  vim.lsp.util.apply_workspace_edit(edit, enc or "utf-16")
end

--- Show the preview picker. opts.pick (specs): function(items, picker_opts) instead of Snacks.
function M.preview(edit, enc, name, opts)
  opts = opts or {}
  local items = M.items(edit, enc)
  if #items == 0 then
    return vim.notify("xyno-rust: the rename changes nothing", vim.log.levels.INFO)
  end
  local total = 0
  local nfiles = 0
  for _, it in ipairs(items) do
    if not it.ops then
      total = total + it.count
      nfiles = nfiles + 1
    end
  end
  local function title()
    return ("Rename to %s: %d edit(s) in %d file(s)  (<Tab> untick, <CR> apply)"):format(name, total, nfiles)
  end
  local function confirm(picker, _)
    if picker and picker.close then
      picker:close()
    end
    local combined, skipped = M.combine(items)
    if skipped > 0 then
      vim.notify(("xyno-rust: rename applied; %d file(s) were left out"):format(skipped), vim.log.levels.WARN)
    end
    M.apply(combined, enc)
  end
  local picker_opts = {
    title = title(),
    items = items,
    format = function(item)
      return {
        { item.ops and "   " or (item.excluded and "[ ]" or "[x]"), item.excluded and "Comment" or "DiagnosticOk" },
        { " " .. item.text },
        { item.ops and "" or ("  %d edit(s)"):format(item.count), "Comment" },
      }
    end,
    layout = { preset = "default", preview = true },
    preview = function(ctx)
      ctx.preview:reset()
      ctx.preview:minimal()
      ctx.preview:set_title(ctx.item.text)
      ctx.preview:set_lines(vim.split(ctx.item.diff, "\n", { plain = true }))
      ctx.preview:highlight({ ft = "diff" })
    end,
    confirm = confirm,
    actions = {
      rn_toggle = function(picker, item)
        item = item or picker:current()
        if item and not item.ops then
          item.excluded = not item.excluded
          pcall(function()
            picker.list:update({ force = true })
            picker.list:render()
          end)
        end
      end,
    },
    win = {
      input = { keys = { ["<Tab>"] = { "rn_toggle", mode = { "i", "n" } }, ["<C-Space>"] = { "rn_toggle", mode = { "i", "n" } } } },
      list = { keys = { ["<Tab>"] = "rn_toggle", ["<C-Space>"] = "rn_toggle" } },
    },
  }
  if opts.pick then
    return opts.pick(items, picker_opts)
  end
  local Snacks = require("xyno_rust.deps").snacks()
  if Snacks then
    Snacks.picker(picker_opts)
  end
end

--- :RustRename
---@param new? string
---@param opts? { pick?: function }
function M.rename(new, opts)
  local buf = vim.api.nvim_get_current_buf()
  local client = M.client(buf)
  if not client then
    return vim.notify("xyno-rust: rust-analyzer is not attached to this buffer", vim.log.levels.WARN)
  end
  local enc = client.offset_encoding or "utf-16"
  local win = vim.api.nvim_get_current_win()
  local params = vim.lsp.util.make_position_params(win, enc)
  local function go(name)
    if not name or name == "" then
      return
    end
    params.newName = name
    client:request("textDocument/rename", params, function(err, edit)
      vim.schedule(function()
        if err then
          return vim.notify("xyno-rust: rename: " .. tostring(err.message or err), vim.log.levels.ERROR)
        end
        if not edit then
          return vim.notify("xyno-rust: nothing to rename here", vim.log.levels.INFO)
        end
        M.preview(edit, enc, name, opts)
      end)
    end, buf)
  end
  if new and new ~= "" then
    return go(new)
  end
  local function ask(default)
    vim.ui.input({ prompt = "Rename to: ", default = default }, go)
  end
  client:request("textDocument/prepareRename", params, function(err, res)
    vim.schedule(function()
      if err then
        return vim.notify("xyno-rust: cannot rename here: " .. tostring(err.message or err), vim.log.levels.INFO)
      end
      local default = vim.fn.expand("<cword>")
      if type(res) == "table" then
        if res.placeholder then
          default = res.placeholder
        else
          local r = res.range or res
          if r.start and r["end"] and r.start.line == r["end"].line then
            local line = vim.api.nvim_buf_get_lines(buf, r.start.line, r.start.line + 1, false)[1] or ""
            local s = vim.str_byteindex(line, enc, r.start.character, false)
            local e = vim.str_byteindex(line, enc, r["end"].character, false)
            default = line:sub(s + 1, e)
          end
        end
      end
      ask(default)
    end)
  end, buf)
end

function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  vim.api.nvim_create_user_command("RustRename", function(a)
    M.rename(a.args)
  end, { nargs = "?", desc = "Rename with a per-file diff preview (untick files, then apply)" })
end

return M
