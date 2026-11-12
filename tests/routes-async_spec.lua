-- :RustRoutes scan: chunked on the main thread, shared between askers, cached per file, query compiled once.
local H = require("xyno_rust_test.helpers")
H.fake_snacks()
require("xyno_rust").setup()

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local function fresh()
  package.loaded["xyno_rust.rust_routes"] = nil
  return require("xyno_rust.rust_routes")
end

--- `n` source files of ~200 lines with `routes` routes each (generated, like a big service).
local function big_tree(n, routes)
  local root = H.tmpdir()
  local body = {}
  for i = 1, routes do
    body[#body + 1] = ('    .route("/api/v1/item%d/{id}", get(h%d).post(p%d))'):format(i, i, i)
  end
  for i = 1, 150 do
    body[#body + 1] = ("// filler line %d to give the parser something to chew on"):format(i)
  end
  local src = "fn router() -> Router {\n    Router::new()\n" .. table.concat(body, "\n") .. "\n}\n"
  for i = 1, n do
    write(("%s/crates/c%d/src/lib.rs"):format(root, i % 20), "")
    write(("%s/crates/c%d/src/m%d.rs"):format(root, i % 20, i), src)
  end
  return root
end

local function max_stall(body)
  local last, worst = vim.uv.hrtime(), 0
  local t = vim.uv.new_timer()
  t:start(2, 2, function()
    local now = vim.uv.hrtime()
    worst = math.max(worst, (now - last) / 1e6)
    last = now
  end)
  body()
  t:stop()
  t:close()
  return worst
end

describe("rust_routes.collect_async", function()
  before_each(function()
    H.need_parser("rust")
  end)

  it("finds the same routes as the synchronous collect", function()
    local R = fresh()
    local root = big_tree(12, 5)
    local want = R.collect(root)
    R.clear_cache()
    local got
    R.collect_async(root, function(items)
      got = items
    end)
    H.wait_for(function()
      return got
    end, 20000, "scan")
    table.sort(want, function(a, b)
      return a.text < b.text
    end)
    table.sort(got, function(a, b)
      return a.text < b.text
    end)
    H.eq(#want, #got)
    H.eq(want, got)
    H.eq(60, #got)
  end)

  it("keeps the main thread responsive: no stall beyond a few slices on a 300-file workspace", function()
    local R = fresh()
    local root = big_tree(300, 8)
    local got
    local stall = max_stall(function()
      R.collect_async(root, function(items)
        got = items
      end)
      H.wait_for(function()
        return got
      end, 60000, "scan")
    end)
    H.eq(2400, #got)
    H.ok(
      stall < 80,
      ("the main thread was held for %.0f ms in one go (slice budget %d ms)"):format(stall, R.config.slice_ms)
    )
    -- control: the unsliced walk does hold it for a long time on the same tree
    R.clear_cache()
    local t0 = vim.uv.hrtime()
    R.collect(root)
    local sync_stall = (vim.uv.hrtime() - t0) / 1e6 -- (nothing ticks while it runs: its whole duration is the stall)
    H.ok(sync_stall > stall * 2, ("control: sync %.0f ms vs async %.0f ms"):format(sync_stall, stall))
  end)

  it("a second request for the same root joins the running scan", function()
    local R = fresh()
    local root = big_tree(40, 4)
    local parses = 0
    local orig = R.scan_source
    R.scan_source = function(src)
      parses = parses + 1
      return orig(src)
    end
    local results = {}
    for _ = 1, 5 do
      R.collect_async(root, function(items)
        results[#results + 1] = #items
      end)
    end
    H.eq(1, R.pending())
    H.wait_for(function()
      return #results == 5
    end, 30000, "five callbacks")
    H.eq({ 160, 160, 160, 160, 160 }, results)
    H.eq(40, parses, "each file parsed once for five askers")
    H.eq(0, R.pending())
  end)

  it("a rescan parses only the files that changed", function()
    local R = fresh()
    local root = big_tree(30, 3)
    local parses = 0
    local orig = R.scan_source
    R.scan_source = function(src)
      parses = parses + 1
      return orig(src)
    end
    local function scan()
      local got
      R.collect_async(root, function(items)
        got = items
      end)
      H.wait_for(function()
        return got
      end, 30000, "scan")
      return got
    end
    H.eq(90, #scan())
    H.eq(30, parses)
    H.eq(90, #scan())
    H.eq(30, parses, "second scan came from the per-file cache")
    vim.uv.sleep(20)
    write(root .. "/crates/c1/src/m1.rs", '#[get("/only")]\nasync fn only() {}\n')
    local items = scan()
    H.eq(31, parses, "one changed file, one parse")
    H.eq(88, #items)
  end)

  it("compiles the treesitter query once, not once per file", function()
    local R = fresh()
    local root = big_tree(25, 2)
    local compiles = 0
    local orig = vim.treesitter.query.parse
    vim.treesitter.query.parse = function(...)
      compiles = compiles + 1
      return orig(...)
    end
    local ok, err = pcall(function()
      local got
      R.collect_async(root, function(items)
        got = items
      end)
      H.wait_for(function()
        return got
      end, 30000, "scan")
    end)
    vim.treesitter.query.parse = orig
    H.ok(ok, tostring(err))
    H.eq(1, compiles)
  end)

  it("skips generated files over the size limit", function()
    local R = fresh()
    local root = H.tmpdir()
    write(root .. "/small.rs", '#[get("/a")]\nfn a() {}\n')
    write(root .. "/huge.rs", '#[get("/b")]\nfn b() {}\n' .. string.rep("// x\n", 300000))
    local old = R.config.max_file_bytes
    R.config.max_file_bytes = 100000
    local items = R.collect(root)
    R.config.max_file_bytes = old
    H.eq(1, #items)
    H.eq("small.rs", items[1].rel)
  end)

  it(":RustRoutes picks without blocking: the picker opens after the scan", function()
    local R = fresh()
    R.setup()
    local root = big_tree(10, 2)
    vim.cmd.cd(vim.fn.fnameescape(root))
    write(root .. "/Cargo.toml", '[package]\nname = "big"\nversion = "0.1.0"\nedition = "2021"\n')
    vim.cmd.edit(vim.fn.fnameescape(root .. "/crates/c1/src/m1.rs"))
    local opened
    local orig = Snacks.picker
    Snacks.picker = function(opts)
      opened = opts
    end
    vim.cmd("RustRoutes")
    H.is_nil(opened, "the command returned before the scan finished")
    H.wait_for(function()
      return opened
    end, 20000, "picker")
    Snacks.picker = orig
    H.eq("Routes", opened.title)
    H.eq(20, #opened.items)
    vim.cmd("silent! %bwipeout!")
  end)
end)
