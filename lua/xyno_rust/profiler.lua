-- An in-editor profile view: hot functions and a foldable call tree, built from what a profiler wrote to disk.
--
--   :RustProfile [file]      open `file`, or pick one of the profiles found under the project
--   :RustProfile record      (see run_configs: profiler = "perf") how the file is made
--
-- Formats read (detected from the content, no external tool needed for these two):
--   * `perf script` output (what `perf script -i perf.data` prints: one block per sample, frames callee first)
--   * collapsed ("folded") stacks, one `a;b;c 123` line per distinct stack: the input of flamegraph.pl,
--     what inferno-collapse-* and `cargo flamegraph`'s folded files contain
--   * `perf.data` itself: converted with `perf script -i` (needs perf; the workspace must be trusted, because
--     perf parses a file that came with the repository)
-- NOT read: samply's JSON (it is symbolicated by `samply load` in a browser UI; no stable symbol-bearing
-- format was available here to test against), callgrind, pprof.
--
-- Parsing is incremental (a time budget per slice), so a profile of tens of megabytes does not freeze the
-- editor. Times are sample counts; with `perf record -F N` that is proportional to CPU time.
local M = {}

M.MAX_BYTES = 512 * 1024 * 1024
M.BUDGET_NS = 8 * 1e6 -- one parsing slice

-- ----------------------------------------------------------------- names

--- A frame name as a human wants it: no `+0x1f` offset, no `::h0123456789abcdef` legacy hash.
function M.clean(name)
  name = name:gsub("%+0x%x+$", "")
  name = name:gsub("::h%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$", "")
  name = vim.trim(name)
  if name == "" then
    return "[unknown]"
  end
  return (name:gsub(";", ":"))
end

-- ----------------------------------------------------------------- formats

--- "collapsed" | "perf" | nil, from the first lines.
function M.detect(text)
  local lines = {}
  for line in text:gmatch("[^\n]+") do
    lines[#lines + 1] = line
    if #lines >= 60 then
      break
    end
  end
  for _, line in ipairs(lines) do
    if line:match("^%s+%x+%s+%S.*") and line:match("%(.-%)%s*$") then
      return "perf"
    end
  end
  for _, line in ipairs(lines) do
    if line:match("^%S.* %d+$") and not line:match("^#") then
      return "collapsed"
    end
  end
  return nil
end

--- Incremental parser: `parse_start(text, kind)` returns an object whose `:step(budget_ns)` returns true when
--- done; `.stacks` maps "root;...;leaf" to a count.
local Parser = {}
Parser.__index = Parser

function M.parse_start(text, kind)
  return setmetatable({ text = text, kind = kind, pos = 1, stacks = {}, samples = 0, frames = nil, bad = 0 }, Parser)
end

function Parser:flush()
  local f = self.frames
  if f and #f > 0 then
    -- callee first in perf script: reverse into root -> leaf
    local rev = {}
    for i = #f, 1, -1 do
      rev[#rev + 1] = f[i]
    end
    local key = table.concat(rev, ";")
    self.stacks[key] = (self.stacks[key] or 0) + 1
    self.samples = self.samples + 1
  end
  self.frames = nil
end

function Parser:step(budget_ns)
  local t0 = vim.uv.hrtime()
  local text, kind = self.text, self.kind
  local n = #text
  local count = 0
  while self.pos <= n do
    local e = text:find("\n", self.pos, true) or n + 1
    local line = text:sub(self.pos, e - 1)
    self.pos = e + 1
    if kind == "collapsed" then
      local stack, c = line:match("^(.-)%s+(%d+)%s*$")
      if stack and stack ~= "" then
        local parts = {}
        for fr in stack:gmatch("[^;]+") do
          parts[#parts + 1] = M.clean(fr)
        end
        local key = table.concat(parts, ";")
        local w = tonumber(c)
        self.stacks[key] = (self.stacks[key] or 0) + w
        self.samples = self.samples + w
      elseif line:match("%S") and not line:match("^#") then
        self.bad = self.bad + 1
      end
    else
      if line:match("^%s*$") then
        self:flush()
      elseif line:match("^%s") then
        local sym = line:match("^%s+%x+%s+(.-)%s+%(.-%)%s*$") or line:match("^%s+%x+%s+(.-)%s*$")
        if sym then
          self.frames = self.frames or {}
          self.frames[#self.frames + 1] = M.clean(sym)
        end
      else
        self:flush()
        self.frames = {} -- header of a sample
      end
    end
    count = count + 1
    if count % 256 == 0 and budget_ns and vim.uv.hrtime() - t0 > budget_ns then
      return false
    end
  end
  if kind ~= "collapsed" then
    self:flush()
  end
  return true
end

--- Parse everything at once (specs, small inputs).
function M.parse(text, kind)
  kind = kind or M.detect(text)
  if not kind then
    return nil, "not a perf script or collapsed-stacks profile"
  end
  local p = M.parse_start(text, kind)
  p:step(nil)
  return M.build(p.stacks, p.samples, kind)
end

-- ------------------------------------------------------------- aggregation

---@class XynoProfile
---@field samples integer
---@field kind string
---@field funcs table<string, { self: integer, total: integer }>
---@field tree table

function M.build(stacks, samples, kind)
  local root = { name = "(all)", total = 0, self = 0, children = {}, depth = 0 }
  local funcs = {}
  for key, c in pairs(stacks) do
    local seen = {}
    local node = root
    node.total = node.total + c
    local last
    for fr in key:gmatch("[^;]+") do
      local ch = node.children[fr]
      if not ch then
        ch = { name = fr, total = 0, self = 0, children = {}, depth = node.depth + 1, parent = node }
        node.children[fr] = ch
      end
      ch.total = ch.total + c
      node = ch
      last = fr
      if not seen[fr] then
        seen[fr] = true
        local f = funcs[fr] or { self = 0, total = 0 }
        funcs[fr] = f
        f.total = f.total + c
      end
    end
    if last then
      node.self = node.self + c
      funcs[last].self = funcs[last].self + c
    end
  end
  return { samples = samples or root.total, kind = kind, funcs = funcs, tree = root }
end

--- The n hottest functions by self samples (ties: total, then name).
function M.hot(profile, n)
  local list = {}
  for name, f in pairs(profile.funcs) do
    list[#list + 1] = { name = name, self = f.self, total = f.total }
  end
  table.sort(list, function(a, b)
    if a.self ~= b.self then
      return a.self > b.self
    end
    if a.total ~= b.total then
      return a.total > b.total
    end
    return a.name < b.name
  end)
  if n and #list > n then
    return vim.list_slice(list, 1, n)
  end
  return list
end

local function sorted_children(node)
  local out = {}
  for _, c in pairs(node.children) do
    out[#out + 1] = c
  end
  table.sort(out, function(a, b)
    if a.total ~= b.total then
      return a.total > b.total
    end
    return a.name < b.name
  end)
  return out
end
M.sorted_children = sorted_children

--- Open the nodes that carry at least `min` of the samples, down to `depth`.
function M.auto_open(profile, min, depth)
  local total = math.max(profile.tree.total, 1)
  local function go(node)
    node.open = node.depth < depth and (node.total / total >= min) and next(node.children) ~= nil
    for _, c in pairs(node.children) do
      go(c)
    end
  end
  go(profile.tree)
end

-- --------------------------------------------------------------- rendering

local function pct(x, total)
  return total > 0 and 100 * x / total or 0
end

--- Lines of the view and, per line, what it stands for: { kind = "hot"|"node", name, node }.
function M.render(profile, opts)
  opts = opts or {}
  local total = math.max(profile.tree.total, 1)
  local lines, meta = {}, {}
  local function add(text, m)
    lines[#lines + 1] = text
    meta[#lines] = m or {}
  end
  add(
    ("Profile: %s   %d samples   (%s)"):format(
      opts.title or "?",
      profile.samples,
      profile.kind == "perf" and "perf script" or "collapsed stacks"
    )
  )
  add("<CR> fold / jump to source   o jump   E expand all   C collapse   t toggle hot list   q close")
  add("")
  if opts.show_hot ~= false then
    add("Hot functions (self time)", { kind = "head" })
    add(("%7s %7s  %s"):format("self", "total", "function"), { kind = "head" })
    for _, f in ipairs(M.hot(profile, opts.top or 25)) do
      add(
        ("%6.1f%% %6.1f%%  %s"):format(pct(f.self, total), pct(f.total, total), f.name),
        { kind = "hot", name = f.name, self = f.self }
      )
    end
    add("")
  end
  add("Call tree (total time, callers above callees)", { kind = "head" })
  local function walk(node, indent)
    for _, c in ipairs(sorted_children(node)) do
      local mark = next(c.children) and (c.open and "▾ " or "▸ ") or "  "
      add(
        ("%6.1f%% %s%s%s"):format(pct(c.total, total), indent, mark, c.name)
          .. (c.self > 0 and (" (self %.1f%%)"):format(pct(c.self, total)) or ""),
        { kind = "node", name = c.name, node = c, self = c.self }
      )
      if c.open then
        walk(c, indent .. "  ")
      end
    end
  end
  walk(profile.tree, "")
  return lines, meta
end

-- ------------------------------------------------------------------ jumping

--- The identifier to look up for a frame name: last path segment that is a name (not a closure / impl).
function M.symbol_of(name)
  local segs = {}
  -- split on :: outside <...> and {{...}}
  local depth, cur = 0, {}
  local i = 1
  while i <= #name do
    local c = name:sub(i, i)
    if c == "<" or c == "{" or c == "(" or c == "[" then
      depth = depth + 1
    elseif c == ">" or c == "}" or c == ")" or c == "]" then
      depth = math.max(depth - 1, 0)
    end
    if depth == 0 and name:sub(i, i + 1) == "::" then
      segs[#segs + 1] = table.concat(cur)
      cur = {}
      i = i + 1
    else
      cur[#cur + 1] = c
    end
    i = i + 1
  end
  segs[#segs + 1] = table.concat(cur)
  for j = #segs, 1, -1 do
    local s = segs[j]
    if s:match("^[%a_][%w_]*$") then
      return s, segs[j - 1] and segs[j - 1]:match("^[%a_][%w_]*$") and segs[j - 1] or nil
    end
  end
end

--- workspace/symbol through the first Rust client; `cb(items)` with LSP SymbolInformation. Specs replace it.
function M.workspace_symbols(query, cb)
  local clients = vim.lsp.get_clients({ name = "rust-analyzer" })
  local client = clients[1]
  if not client then
    return cb(nil, "rust-analyzer is not running")
  end
  client:request("workspace/symbol", { query = query }, function(err, res)
    cb(res, err and err.message)
  end)
end

function M.jump(name)
  local sym, container = M.symbol_of(name)
  if not sym then
    return vim.notify(("xyno-rust: no source location for %q"):format(name), vim.log.levels.INFO)
  end
  M.workspace_symbols(sym, function(res, err)
    vim.schedule(function()
      local hits = {}
      for _, s in ipairs(res or {}) do
        if s.name == sym then
          hits[#hits + 1] = s
        end
      end
      if #hits == 0 then
        return vim.notify(
          ("xyno-rust: %q not found in the workspace%s"):format(sym, err and (" (" .. err .. ")") or ""),
          vim.log.levels.INFO
        )
      end
      if container then
        local pref = vim.tbl_filter(function(s)
          return s.containerName == container
        end, hits)
        if #pref > 0 then
          hits = pref
        end
      end
      local function go(s)
        local loc = s.location
        -- jump in a window that is not the profile view
        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.bo[vim.api.nvim_win_get_buf(w)].filetype ~= "xyno-profile" then
            vim.api.nvim_set_current_win(w)
            break
          end
        end
        vim.cmd("edit " .. vim.fn.fnameescape(vim.uri_to_fname(loc.uri)))
        pcall(vim.api.nvim_win_set_cursor, 0, { loc.range.start.line + 1, loc.range.start.character })
        vim.cmd("normal! zz")
      end
      if #hits == 1 then
        return go(hits[1])
      end
      vim.ui.select(hits, {
        prompt = ("%s: %d matches"):format(sym, #hits),
        format_item = function(s)
          return ("%s  %s:%d"):format(
            s.containerName or "",
            vim.fn.fnamemodify(vim.uri_to_fname(s.location.uri), ":~:."),
            s.location.range.start.line + 1
          )
        end,
      }, function(s)
        if s then
          go(s)
        end
      end)
    end)
  end)
end

-- --------------------------------------------------------------------- view

local ns = vim.api.nvim_create_namespace("xyno_profile")

local function paint(buf, lines, meta)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for i, m in ipairs(meta) do
    if m.kind == "head" then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, { line_hl_group = "Title" })
    elseif m.kind == "hot" or m.kind == "node" then
      local p = tonumber(lines[i]:match("^%s*([%d%.]+)%%")) or 0
      vim.api.nvim_buf_set_extmark(
        buf,
        ns,
        i - 1,
        0,
        { end_col = 7, hl_group = p >= 25 and "DiagnosticError" or p >= 10 and "DiagnosticWarn" or "Comment" }
      )
    end
  end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = "Comment" })
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { line_hl_group = "Comment" })
end

--- Show a profile in a new window. Returns the buffer.
---@param profile XynoProfile
function M.show(profile, title)
  M.auto_open(profile, 0.05, 6)
  local state = { show_hot = true }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "xyno-profile"
  vim.api.nvim_buf_set_name(buf, "xyno-profile://" .. (title or "profile") .. "#" .. buf)
  vim.cmd("botright vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, math.min(math.max(80, math.floor(vim.o.columns * 0.45)), vim.o.columns - 20))
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].cursorline = true
  local meta
  local function redraw(keep)
    local cur = keep and vim.api.nvim_win_get_cursor(win)
    local lines
    lines, meta = M.render(profile, { title = title, show_hot = state.show_hot })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    paint(buf, lines, meta)
    if cur then
      pcall(vim.api.nvim_win_set_cursor, win, { math.min(cur[1], #lines), 0 })
    end
  end
  redraw()
  M._views = M._views or {}
  M._views[buf] = {
    profile = profile,
    redraw = redraw,
    state = state,
    meta = function()
      return meta
    end,
  }
  local function at()
    return meta[vim.api.nvim_win_get_cursor(win)[1]] or {}
  end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "xyno-rust profile: " .. desc })
  end
  local function toggle()
    local m = at()
    if m.kind == "node" and next(m.node.children) then
      m.node.open = not m.node.open
      redraw(true)
    elseif m.name then
      M.jump(m.name)
    end
  end
  map("<CR>", toggle, "fold / jump")
  map("<Tab>", toggle, "fold / jump")
  map("o", function()
    local m = at()
    if m.name then
      M.jump(m.name)
    end
  end, "jump to source")
  map("E", function()
    local function all(n)
      n.open = next(n.children) ~= nil
      for _, c in pairs(n.children) do
        all(c)
      end
    end
    all(profile.tree)
    redraw(true)
  end, "expand all")
  map("C", function()
    local function none(n)
      n.open = false
      for _, c in pairs(n.children) do
        none(c)
      end
    end
    none(profile.tree)
    redraw(true)
  end, "collapse all")
  map("t", function()
    state.show_hot = not state.show_hot
    redraw()
  end, "toggle the hot list")
  map("q", function()
    vim.cmd("close")
  end, "close")
  return buf
end

-- ------------------------------------------------------------------ loading

--- Read a profile file and show it. `perf.data` goes through `perf script` (trust-gated).
---@param path string
---@param cb? fun(profile: XynoProfile?, err: string?)  called instead of showing (specs)
function M.open_file(path, cb)
  path = vim.fs.normalize(path)
  local st = vim.uv.fs_stat(path)
  if not st or st.type ~= "file" then
    return vim.notify(("xyno-rust: %s is not a file"):format(path), vim.log.levels.ERROR)
  end
  if st.size > M.MAX_BYTES then
    return vim.notify(("xyno-rust: %s is larger than %d MB"):format(path, M.MAX_BYTES / 1048576), vim.log.levels.ERROR)
  end
  local title = vim.fn.fnamemodify(path, ":t")
  local function from_text(text)
    local kind = M.detect(text)
    if not kind then
      local msg = ("%s is neither perf script output nor collapsed stacks (samply JSON is not read: use `samply load`)"):format(
        title
      )
      if cb then
        return cb(nil, msg)
      end
      return vim.notify("xyno-rust: " .. msg, vim.log.levels.ERROR)
    end
    local parser = M.parse_start(text, kind)
    local function slice()
      if parser:step(M.BUDGET_NS) then
        local profile = M.build(parser.stacks, parser.samples, kind)
        if profile.tree.total == 0 then
          local msg = title .. " holds no samples"
          if cb then
            return cb(nil, msg)
          end
          return vim.notify("xyno-rust: " .. msg, vim.log.levels.WARN)
        end
        if cb then
          return cb(profile)
        end
        M.show(profile, title)
      else
        vim.defer_fn(slice, 1)
      end
    end
    slice()
  end
  local fd = io.open(path, "rb")
  if not fd then
    return vim.notify("xyno-rust: cannot read " .. path, vim.log.levels.ERROR)
  end
  local head = fd:read(8)
  if head == "PERFILE2" then
    fd:close()
    if vim.fn.executable("perf") ~= 1 then
      return vim.notify("xyno-rust: perf.data needs the `perf` tool to be read (perf script)", vim.log.levels.ERROR)
    end
    local root = require("xyno_rust.rust_context").root(path, { nowait = true }) or vim.fs.dirname(path)
    return require("xyno_rust.trust").require(root, "perf script on " .. title, function(go)
      if not go then
        return
      end
      vim.system({ "perf", "script", "-i", path }, { text = true, timeout = 120000 }, function(r)
        vim.schedule(function()
          if r.code ~= 0 then
            local msg = "perf script failed: " .. vim.trim((r.stderr or ""):sub(1, 300))
            if cb then
              return cb(nil, msg)
            end
            return vim.notify("xyno-rust: " .. msg, vim.log.levels.ERROR)
          end
          from_text(r.stdout or "")
        end)
      end)
    end)
  end
  fd:seek("set", 0)
  local text = fd:read("*a")
  fd:close()
  from_text(text)
end

local NAMES = { "%.folded$", "%.collapsed$", "%.perf$", "^perf%.script$", "^perf%.data$", "%.stacks$" }

--- Profile files worth offering, newest first: the output of the "perf" run profiler, then loose files
--- named like profiles in the project root and target/.
function M.find(root)
  local out = {}
  local function scan(dir, depth)
    local h = vim.uv.fs_scandir(dir)
    while h do
      local name, typ = vim.uv.fs_scandir_next(h)
      if not name then
        break
      end
      local p = dir .. "/" .. name
      if typ == "file" then
        for _, pat in ipairs(NAMES) do
          if name:find(pat) then
            local st = vim.uv.fs_stat(p)
            out[#out + 1] = { path = p, mtime = st and st.mtime.sec or 0, size = st and st.size or 0 }
            break
          end
        end
      elseif
        typ == "directory"
        and depth < 2
        and (name == "target" or name == "xyno-profile" or name == "profile" or name == "profiles")
      then
        scan(p, depth + 1)
      end
    end
  end
  scan(root, 0)
  table.sort(out, function(a, b)
    return a.mtime > b.mtime
  end)
  return out
end

function M.command(args)
  local a = vim.trim(args or "")
  if a ~= "" then
    return M.open_file(vim.fn.expand(a))
  end
  local rc = require("xyno_rust.rust_context")
  rc.root_async(nil, function(root)
    root = root or vim.uv.cwd()
    local found = M.find(root)
    if #found == 0 then
      return vim.notify(
        "xyno-rust: no profile found under "
          .. root
          .. ' (perf.data, perf.script, *.folded, *.collapsed; make one with a run configuration whose profiler is "perf", or :RustProfile <file>)',
        vim.log.levels.INFO
      )
    end
    if #found == 1 then
      return M.open_file(found[1].path)
    end
    vim.ui.select(found, {
      prompt = "Profile",
      format_item = function(f)
        return ("%s  (%s, %d KB)"):format(
          vim.fn.fnamemodify(f.path, ":~:."),
          os.date("%Y-%m-%d %H:%M", f.mtime),
          f.size / 1024
        )
      end,
    }, function(f)
      if f then
        M.open_file(f.path)
      end
    end)
  end)
end

function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  vim.api.nvim_create_user_command("RustProfile", function(a)
    M.command(a.args)
  end, { nargs = "?", complete = "file", desc = "In-editor profile view (perf script / collapsed stacks / perf.data)" })
end

return M
