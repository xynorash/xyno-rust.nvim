-- xyno_rust.profiler: perf script and collapsed-stack parsing, aggregation, the view, jumping to source,
-- the file finder. Real `perf record` is not exercised: the host that ran these specs forbids
-- perf_event_open; the fixture is in the exact format `perf script` prints.
local H = require("xyno_rust_test.helpers")
require("xyno_rust").setup()
local P = require("xyno_rust.profiler")
local fx = H.fixtures .. "/profiles"

local function read(p)
  local f = assert(io.open(p, "rb"))
  local t = f:read("*a")
  f:close()
  return t
end

describe("names", function()
  it("drops the offset and the legacy hash, keeps generics", function()
    H.eq("hot::spin", P.clean("hot::spin::h1a2b3c4d5e6f7081+0x14"))
    H.eq("<alloc::vec::Vec<T> as core::ops::drop::Drop>::drop", P.clean("<alloc::vec::Vec<T> as core::ops::drop::Drop>::drop+0x1c"))
    H.eq("[unknown]", P.clean("  "))
  end)
  it("symbol_of finds the identifier to look up", function()
    H.eq({ "spin", "hot" }, { P.symbol_of("hot::spin") })
    H.eq({ "drop", nil }, { P.symbol_of("<alloc::vec::Vec<T> as core::ops::drop::Drop>::drop") })
    H.eq({ "run", "worker" }, { P.symbol_of("worker::run::{{closure}}") })
    H.is_nil(P.symbol_of("[unknown]"))
  end)
end)

describe("formats", function()
  it("detects perf script and collapsed stacks", function()
    H.eq("perf", P.detect(read(fx .. "/perf.script")))
    H.eq("collapsed", P.detect(read(fx .. "/sample.folded")))
    H.is_nil(P.detect("hello world\nnothing here\n"))
    H.is_nil(P.detect('{"meta":{"interval":1},"threads":[]}'))
  end)

  it("perf script and the folded file of the same run give the same profile", function()
    local a = assert(P.parse(read(fx .. "/perf.script")))
    local b = assert(P.parse(read(fx .. "/sample.folded")))
    H.eq(10, a.samples)
    H.eq(10, b.samples)
    -- the perf script has libc / _start frames above main; compare the function table of the hot code
    for _, name in ipairs({ "hot::spin", "hot::fib", "[unknown]" }) do
      H.eq(b.funcs[name], a.funcs[name], name)
    end
    H.eq({ self = 5, total = 5 }, a.funcs["hot::spin"])
    -- recursion: total counts a sample once per function, self is the leaf only
    H.eq({ self = 3, total = 3 }, a.funcs["hot::fib"])
    H.eq(10, a.funcs["hot::main"].total)
    H.eq(0, a.funcs["hot::main"].self)
  end)

  it("hot() orders by self samples", function()
    local p = assert(P.parse(read(fx .. "/perf.script")))
    local hot = P.hot(p, 3)
    H.eq({ "hot::spin", "hot::fib" }, { hot[1].name, hot[2].name })
    H.eq(3, #hot)
  end)

  it("the tree is root -> leaf with totals", function()
    local p = assert(P.parse(read(fx .. "/sample.folded")))
    local main = p.tree.children["main"]
    H.eq(10, main.total)
    H.eq(5, main.children["hot::spin"].total)
    H.eq(3, main.children["hot::fib"].children["hot::fib"].total)
    H.eq(2, main.children["hot::fib"].children["hot::fib"].children["hot::fib"].self)
  end)

  it("counts bad lines of a folded file instead of dying", function()
    local pr = P.parse_start("a;b 3\nnot a stack line\nc 2\n", "collapsed")
    pr:step()
    H.eq(1, pr.bad)
    H.eq(5, pr.samples)
  end)

  it("a perf script without header lines or with ragged blocks still parses", function()
    local p = assert(P.parse("x 1 1.0:  1 cpu-clock:u:\n\t  10 f+0x1 (/a)\n\t  20 g+0x2 (/a)\n\n\n\nx 1 1.1: 1 cpu-clock:u:\n\t  10 f+0x1 (/a)\n"))
    H.eq(2, p.samples)
    H.eq(2, p.funcs["f"].total)
    H.eq(2, p.funcs["f"].self)
    H.eq(0, p.funcs["g"].self)
  end)
end)

describe("incremental parsing", function()
  it("a 6 MB profile is parsed in slices that stay inside the budget", function()
    local parts = {}
    for i = 1, 60000 do
      parts[#parts + 1] = ("main;mod_%d::work;mod_%d::leaf_%d %d"):format(i % 50, i % 50, i % 200, (i % 7) + 1)
    end
    local text = table.concat(parts, "\n") .. "\n"
    H.ok(#text > 1.5e6, #text)
    local pr = P.parse_start(text, "collapsed")
    local slices, longest = 0, 0
    repeat
      local t0 = vim.uv.hrtime()
      local done = pr:step(P.BUDGET_NS)
      longest = math.max(longest, (vim.uv.hrtime() - t0) / 1e6)
      slices = slices + 1
    until done
    H.ok(slices > 3, "needed several slices: " .. slices)
    H.ok(longest < 60, "longest slice " .. longest .. " ms")
    local p = P.build(pr.stacks, pr.samples, "collapsed")
    H.ok(p.tree.total > 0)
  end)
end)

describe("view", function()
  local function show(file)
    local profile
    P.open_file(fx .. "/" .. file, function(p, err)
      profile = p
      H.is_nil(err)
    end)
    H.wait_for(function() return profile end, 5000, "profile loaded")
    return profile
  end

  it("renders the hot list and the folded tree; <CR> folds and unfolds", function()
    local profile = show("perf.script")
    local buf = P.show(profile, "perf.script")
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    H.match(text, "Hot functions", true)
    H.match(text, "50.0%%.-hot::spin")
    H.match(text, "Call tree", true)
    -- the tree opens the hot path; collapse everything with C, then open the root with <CR>
    vim.api.nvim_feedkeys("C", "x", false)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local at
    for i, l in ipairs(lines) do
      if l:find("▸", 1, true) and l:find("_start", 1, true) then at = i end
    end
    H.ok(at, "collapsed root _start:\n" .. table.concat(lines, "\n"))
    vim.api.nvim_win_set_cursor(0, { at, 0 })
    vim.api.nvim_feedkeys(vim.keycode("<CR>"), "x", false)
    local after = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    H.match(after, "▾ _start", true)
    vim.api.nvim_feedkeys("q", "x", false)
  end)

  it("jumping uses the workspace symbols: a unique match opens the file at the symbol", function()
    local dir = H.tmpdir()
    vim.fn.writefile({ "// a", "pub fn spin() {}" }, dir .. "/lib.rs")
    local orig = P.workspace_symbols
    local asked
    P.workspace_symbols = function(q, cb)
      asked = q
      cb({ { name = "spin", containerName = "hot", location = { uri = vim.uri_from_fname(dir .. "/lib.rs"), range = { start = { line = 1, character = 7 }, ["end"] = { line = 1, character = 11 } } } } })
    end
    local buf = P.show(show("sample.folded"), "sample.folded")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find("hot::spin", 1, true) then vim.api.nvim_win_set_cursor(0, { i, 0 }) break end
    end
    vim.api.nvim_feedkeys("o", "x", false)
    H.wait_for(function() return vim.api.nvim_buf_get_name(0):find("lib.rs", 1, true) end, 5000, "file opened")
    H.eq("spin", asked)
    H.eq({ 2, 7 }, vim.api.nvim_win_get_cursor(0))
    P.workspace_symbols = orig
  end)

  it("a file that is neither format says so; samply JSON points to `samply load`", function()
    local f = H.tmpdir() .. "/x.json"
    vim.fn.writefile({ '{"meta":{"version":24},"threads":[]}' }, f)
    local err
    P.open_file(f, function(_, e) err = e end)
    H.wait_for(function() return err end, 2000, "error")
    H.match(err, "samply load", true)
  end)

  it("find() lists profile-looking files under the root and target/, newest first", function()
    local d = H.tmpdir()
    vim.fn.mkdir(d .. "/target/xyno-profile", "p")
    vim.fn.writefile({ "a 1" }, d .. "/old.folded")
    vim.uv.fs_utime(d .. "/old.folded", 1000, 1000)
    vim.fn.writefile({ "a 1" }, d .. "/target/xyno-profile/perf.script")
    vim.fn.writefile({ "x" }, d .. "/notes.txt")
    local got = vim.tbl_map(function(f) return vim.fn.fnamemodify(f.path, ":t") end, P.find(d))
    H.eq({ "perf.script", "old.folded" }, got)
  end)

  it("perf.data is converted with `perf script` only after trust; a fake perf proves the call", function()
    local d = H.tmpdir()
    vim.fn.mkdir(d .. "/bin", "p")
    local fake = d .. "/bin/perf"
    vim.fn.writefile({ "#!/bin/sh", 'echo "$@" > ' .. d .. "/args", "cat " .. fx .. "/perf.script" }, fake)
    vim.fn.setfperm(fake, "rwxr-xr-x")
    local data = d .. "/perf.data"
    local fd = io.open(data, "wb")
    fd:write("PERFILE2" .. ("\0"):rep(64))
    fd:close()
    local old_path = vim.env.PATH
    vim.env.PATH = d .. "/bin:" .. old_path
    local trust = require("xyno_rust.trust")
    local orig = trust.require
    local asked
    trust.require = function(root, what, cb)
      asked = what
      cb(true)
    end
    local profile
    P.open_file(data, function(p) profile = p end)
    H.wait_for(function() return profile end, 5000, "converted")
    trust.require = orig
    vim.env.PATH = old_path
    H.match(asked, "perf script", true)
    H.eq("script -i " .. data, vim.trim(table.concat(vim.fn.readfile(d .. "/args"), "")))
    H.eq(10, profile.samples)
  end)
end)
