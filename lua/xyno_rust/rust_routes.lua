-- :RustRoutes - HTTP route picker for axum / actix / rocket projects
-- (inspired by the Endpoints tool window of the JetBrains IDEs, minimal). Pure treesitter, no LSP:
--   .route("/users/{id}", get(show).delete(remove))   axum, actix `web::get().to(h)`
--   #[get("/users")] async fn list() {}               actix-web, rocket, poem-style
--   #[actix_web::post("/users")]
local M = {}

local METHODS = { "get", "post", "put", "delete", "patch", "head", "options", "trace", "connect", "route" }

local QUERY = [[
((call_expression
   function: (field_expression field: (field_identifier) @_f)
   arguments: (arguments . (string_literal (string_content) @path) . (_) @handler))
 (#eq? @_f "route"))

(attribute_item
  (attribute
    [(identifier) @verb
     (scoped_identifier name: (identifier) @verb)]
    arguments: (token_tree . (string_literal (string_content) @path))))
]]

--- Parse `src` and return { { path, kind, detail, row, col } ... } (row 0-based).
-- The query is compiled once: parsing it again for every file was a large part of a scan.
local compiled
local function query_of()
  if not compiled then
    compiled = vim.treesitter.query.parse("rust", QUERY)
  end
  return compiled
end

function M.scan_source(src)
  local ok, parser = pcall(vim.treesitter.get_string_parser, src, "rust")
  if not ok then
    return {}
  end
  local tree = parser:parse()[1]
  local query = query_of()
  local out = {}
  for _, match in query:iter_matches(tree:root(), src, 0, -1) do
    local cap = {}
    for id, nodes in pairs(match) do
      cap[query.captures[id]] = nodes[#nodes]
    end
    if cap.verb then
      -- attribute: only HTTP verbs, and the route belongs to the fn that follows
      local verb = vim.treesitter.get_node_text(cap.verb, src)
      if vim.list_contains(METHODS, verb) then
        local fn = cap.verb
        while fn and fn:type() ~= "attribute_item" do
          fn = fn:parent()
        end
        local nxt = fn and fn:next_named_sibling()
        while nxt and nxt:type() == "attribute_item" do
          nxt = nxt:next_named_sibling()
        end
        local name = nxt and nxt:type() == "function_item" and vim.treesitter.get_node_text(nxt:field("name")[1], src)
        local row, col = cap.path:start()
        out[#out + 1] = {
          path = vim.treesitter.get_node_text(cap.path, src),
          kind = verb:upper(),
          detail = name or "?",
          row = row,
          col = col,
        }
      end
    elseif cap.handler then
      local row, col = cap.path:start()
      out[#out + 1] = {
        path = vim.treesitter.get_node_text(cap.path, src),
        kind = "ROUTE",
        -- `get(show).delete(remove)` / `web::get().to(h)` / `any(h)`, whitespace squeezed
        detail = (vim.treesitter.get_node_text(cap.handler, src):gsub("%s+", " ")),
        row = row,
        col = col,
      }
    end
  end
  table.sort(out, function(a, b)
    return a.row < b.row
  end)
  return out
end

local SKIP = { target = true, [".git"] = true, node_modules = true, ["bacon-ls-live"] = true }

M.config = {
  slice_ms = 8, -- the longest a scan holds the main thread before it yields to input and redraws
  max_file_bytes = 1024 * 1024, -- generated sources bigger than this are not routes files
}

-- file -> { stamp, routes } : a rescan reads and parses only the files that changed
local file_cache = {}

local function stamp_of(st)
  return ("%d:%d.%d"):format(st.size, st.mtime.sec, st.mtime.nsec)
end

--- The routes of one file, from the cache when its size and mtime are unchanged.
local function file_routes(file)
  local st = vim.uv.fs_stat(file)
  if not st or st.type ~= "file" or st.size > M.config.max_file_bytes then
    return {}
  end
  local stamp = stamp_of(st)
  local hit = file_cache[file]
  if hit and hit.stamp == stamp then
    return hit.routes
  end
  local f = io.open(file)
  local src = f and f:read("*a")
  if f then
    f:close()
  end
  -- cheap pre-filter before parsing
  local routes = src and (src:find(".route(", 1, true) or src:find("#[", 1, true)) and M.scan_source(src) or {}
  file_cache[file] = { stamp = stamp, routes = routes }
  return routes
end

local function to_items(root, name, routes, items)
  local file = root .. "/" .. name
  for _, r in ipairs(routes) do
    items[#items + 1] = {
      text = ("%s %s  %s  %s"):format(r.kind, r.path, r.detail, name),
      file = file,
      pos = { r.row + 1, r.col },
      kind = r.kind,
      route = r.path,
      detail = r.detail,
      rel = name,
    }
  end
end

local function walk(root)
  return vim.fs.dir(root, {
    depth = 12,
    skip = function(dir)
      return not SKIP[vim.fs.basename(dir)] -- dir is the path relative to root: nested target/ too
    end,
  })
end

local scanning = {} -- root -> { callbacks } : a second request joins the scan that runs

--- Scan the workspace's .rs files without holding the main thread longer than
--- config.slice_ms at a time: the walk and the parsing run in slices, with the event loop
--- (typing, redraw) in between. A scan already running for `root` is joined, and files
--- unchanged since the last scan come from the cache. cb(items) runs on the main loop.
function M.collect_async(root, cb)
  if scanning[root] then
    table.insert(scanning[root], cb)
    return
  end
  scanning[root] = { cb }
  local items = {}
  local iter = walk(root)
  local function step()
    local deadline = vim.uv.hrtime() + M.config.slice_ms * 1e6
    while true do
      local name, type = iter()
      if not name then
        local waiting = scanning[root]
        scanning[root] = nil
        for _, f in ipairs(waiting) do
          f(items)
        end
        return
      end
      if type == "file" and name:match("%.rs$") then
        to_items(root, name, file_routes(root .. "/" .. name), items)
      end
      if vim.uv.hrtime() > deadline then
        return vim.defer_fn(step, 1)
      end
    end
  end
  vim.schedule(step)
end

--- Number of scans running (for the specs).
function M.pending()
  return vim.tbl_count(scanning)
end

--- Every route in the workspace's .rs files, synchronously (no slicing). For callers that need the
--- list at once; the picker uses collect_async.
function M.collect(root)
  local items = {}
  for name, type in walk(root) do
    if type == "file" and name:match("%.rs$") then
      to_items(root, name, file_routes(root .. "/" .. name), items)
    end
  end
  return items
end

--- Forget the cached scans (all, or the files below `root`).
function M.clear_cache(root)
  if not root then
    file_cache = {}
    return
  end
  for f in pairs(file_cache) do
    if f:sub(1, #root + 1) == root .. "/" then
      file_cache[f] = nil
    end
  end
end

function M.pick()
  require("xyno_rust.rust_context").root_async(nil, function(root)
    if not root then
      return vim.notify("no Cargo.toml found", vim.log.levels.WARN)
    end
    -- a long scan says so (a small workspace never shows this)
    local slow = vim.defer_fn(function()
      vim.notify("scanning routes ...", vim.log.levels.INFO)
    end, 400)
    M.collect_async(root, function(items)
      if not slow:is_closing() then
        slow:stop()
        slow:close()
      end
      if #items == 0 then
        return vim.notify('no routes found (.route("/p", ..) or #[get("/p")])', vim.log.levels.INFO)
      end
      local Snacks = require("xyno_rust.deps").snacks()
      if not Snacks then
        return
      end
      Snacks.picker({
        title = "Routes",
        items = items,
        format = function(item)
          return {
            { ("%-7s"):format(item.kind), "XynoRustRouteKind" },
            { item.route .. "  ", "XynoRustRoutePath" },
            { item.detail .. "  ", "XynoRustRouteDetail" },
            { item.rel, "XynoRustRouteFile" },
          }
        end,
        preview = "file",
      })
    end)
  end)
end

--- opts.commands = false: do not define :RustRoutes.
function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  vim.api.nvim_create_user_command("RustRoutes", M.pick, { desc = "Pick an axum/actix/rocket route in the workspace" })
end

return M
