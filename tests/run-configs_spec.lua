-- xyno_rust.run_configs: argument parsing, per-project storage, the command line of a configuration
-- (one argv list, nothing goes through a shell line the user typed), the :RustRun flow with a fake
-- picker / terminal, and one real cargo run that proves args and environment arrive.
local H = require("xyno_rust_test.helpers")
local terms = H.fake_snacks()
require("xyno_rust").setup()
local R = require("xyno_rust.run_configs")
local rc = require("xyno_rust.rust_context")

after_each(function()
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
  pcall(vim.uv.fs_unlink, R.file())
end)

describe("split_args / join_args", function()
  it("splits on blanks, groups quotes, expands nothing", function()
    H.eq({ "a", "--b", "c d", "e f", "g h" }, R.split_args([[a --b 'c d' "e f" g\ h]]))
    H.eq({ "$HOME", "`id`", ";", "rm", "-rf", "~" }, R.split_args("$HOME `id` ; rm -rf ~"))
    H.eq({ "" }, R.split_args("''"))
    H.eq({}, R.split_args("   "))
    H.eq({ [[a"b]] }, R.split_args([["a\"b"]]))
  end)
  it("reports an unterminated quote", function()
    local r, e = R.split_args("a 'b")
    H.is_nil(r)
    H.match(e, "unterminated", true)
  end)
  it("join_args round-trips", function()
    local words = { "a", "b c", "d'e", "", [[f"g]] }
    H.eq(words, R.split_args(R.join_args(words)))
  end)
end)

describe("parse_env / format_env", function()
  it("reads NAME=value words", function()
    H.eq({ RUST_LOG = "debug", A = "x y", E = "" }, R.parse_env("RUST_LOG=debug A='x y' E="))
    H.eq({}, R.parse_env(""))
  end)
  it("rejects what is not an assignment or a variable name", function()
    local e1 = select(2, R.parse_env("novalue"))
    H.match(e1, "NAME=value", true)
    local e2 = select(2, R.parse_env("1A=2"))
    H.match(e2, "valid variable name", true)
    local e3 = select(2, R.parse_env("A-B=2"))
    H.match(e3, "valid variable name", true)
  end)
  it("format_env is sorted and round-trips", function()
    local env = { B = "two words", A = "1", C = "" }
    H.eq("A=1 B='two words' C=''", R.format_env(env))
    H.eq(env, R.parse_env(R.format_env(env)))
  end)
end)

describe("sanitize", function()
  it("fixes what a hand-edited file may hold", function()
    H.is_nil(R.sanitize({ cmd = "run" }))
    H.is_nil(R.sanitize({ name = "  " }))
    H.is_nil(R.sanitize("x"))
    local c = R.sanitize({ name = " go ", cmd = "rm -rf", args = 5, env = { OK = "1", ["bad name"] = "2", N = 3 }, profiler = "dtrace", bin = "x", example = "y" })
    H.eq("go", c.name)
    H.eq("run", c.cmd)
    H.eq("", c.args)
    H.eq({ OK = "1" }, c.env)
    H.eq("none", c.profiler)
    H.eq("x", c.bin)
    H.is_nil(c.example, "one target")
  end)
end)

describe("storage", function()
  local root
  before_each(function()
    root = H.tmpdir()
  end)

  it("saves per project, keeps order, remembers the last, survives a reload", function()
    local other = H.tmpdir()
    H.ok(R.save(root, { name = "a", cmd = "run", bin = "x", env = { K = "v" } }))
    H.ok(R.save(root, { name = "b", cmd = "test" }))
    H.ok(R.save(other, { name = "c" }))
    R.set_last(root, "b")
    local cur = R.load(root)
    H.eq({ "a", "b" }, vim.tbl_map(function(c) return c.name end, cur.configs))
    H.eq("b", cur.last)
    H.eq({ K = "v" }, cur.configs[1].env)
    H.eq({ "c" }, vim.tbl_map(function(c) return c.name end, R.load(other).configs))
    -- the file is what a second nvim would read
    local raw = vim.json.decode(table.concat(vim.fn.readfile(R.file()), "\n"))
    H.eq(2, vim.tbl_count(raw))
  end)

  it("refuses a duplicate name, renames in place, deletes", function()
    R.save(root, { name = "a" })
    R.save(root, { name = "b" })
    local r, e = R.save(root, { name = "a", cmd = "test" })
    H.is_nil(r)
    H.match(e, "exists", true)
    R.set_last(root, "a")
    H.ok(R.save(root, { name = "z", cmd = "bench" }, "a"))
    local cur = R.load(root)
    H.eq({ "z", "b" }, vim.tbl_map(function(c) return c.name end, cur.configs))
    H.eq("z", cur.last, "last follows a rename")
    H.ok(R.delete(root, "z"))
    H.not_ok(R.delete(root, "z"))
    H.eq({ "b" }, vim.tbl_map(function(c) return c.name end, R.load(root).configs))
    H.is_nil(R.load(root).last)
  end)

  it("ignores a broken state file", function()
    vim.fn.mkdir(vim.fs.dirname(R.file()), "p")
    vim.fn.writefile({ "{not json" }, R.file())
    H.eq({}, R.load(root).configs)
    H.ok(R.save(root, { name = "a" }), "and writes over it")
  end)
end)

describe("build", function()
  it("a binary with program args, cargo args and the context features", function()
    local b = R.build({ name = "n", cmd = "run", package = "p", bin = "tool", cargo_args = "--release", args = "--port 80 'a b'", env = { A = "1" } }, { "--features", "x" })
    H.eq({ "cargo", "run", "-p", "p", "--bin", "tool", "--features", "x", "--release", "--", "--port", "80", "a b" }, b.argv)
    H.eq({ A = "1" }, b.env)
  end)
  it("a feature flag of the configuration replaces the context's", function()
    local b = R.build({ name = "n", cmd = "test", cargo_args = "--no-default-features --workspace" }, { "--all-features" })
    H.eq({ "cargo", "test", "--no-default-features", "--workspace" }, b.argv)
    b = R.build({ name = "n", cmd = "check", cargo_args = "-F foo" }, { "--all-features" })
    H.eq({ "cargo", "check", "-F", "foo" }, b.argv)
  end)
  it("typed shell syntax stays an argument", function()
    local b = R.build({ name = "n", cmd = "run", args = "; touch pwned && echo $(id)" }, {})
    H.eq({ "cargo", "run", "--", ";", "touch", "pwned", "&&", "echo", "$(id)" }, b.argv)
  end)
  it("lib / example / test / bench selectors", function()
    H.eq({ "cargo", "test", "--lib" }, R.build({ name = "n", cmd = "test", lib = true }, {}).argv)
    H.eq({ "cargo", "run", "--example", "ex" }, R.build({ name = "n", cmd = "run", example = "ex" }, {}).argv)
    H.eq({ "cargo", "test", "--test", "it" }, R.build({ name = "n", cmd = "test", test = "it" }, {}).argv)
    H.eq({ "cargo", "bench", "--bench", "bn" }, R.build({ name = "n", cmd = "bench", bench = "bn" }, {}).argv)
  end)
  it("reports unterminated quotes", function()
    local b, e = R.build({ name = "n", cmd = "run", args = "'x" }, {})
    H.is_nil(b)
    H.match(e, "program arguments", true)
  end)
  it("profilers: flamegraph argv and samply as an argv of sh with the program args separate", function()
    local meta = { target_directory = "/t", packages = { { name = "p", targets = { { name = "tool", kind = { "bin" } } } } } }
    local f = R.build({ name = "n", cmd = "run", package = "p", bin = "tool", args = "--x 1", profiler = "flamegraph" }, { "--features", "z" }, meta)
    H.eq("cargo-flamegraph", f.tool)
    H.eq({ "cargo", "flamegraph", "--profile", "profiling" }, vim.list_slice(f.argv, 1, 4))
    H.has(f.argv, 'profile.profiling.debug=true')
    H.eq({ "--", "--x", "1" }, vim.list_slice(f.argv, #f.argv - 2))
    local s = R.build({ name = "n", cmd = "run", package = "p", bin = "tool", args = "a; b", profiler = "samply" }, {}, meta)
    H.eq("samply", s.tool)
    H.eq("sh", s.argv[1])
    H.match(s.argv[3], "'cargo' 'build' '--profile' 'profiling'", true)
    H.match(s.argv[3], "exec samply record \"$@\"", true)
    H.eq({ "/t/profiling/tool", "a;", "b" }, vim.list_slice(s.argv, 5))
    H.not_ok(s.argv[3]:find("a;", 1, true), "program args are not part of the shell text")
  end)
  it("perf profiler: build, record into target/xyno-profile, convert; program args stay out of the shell text", function()
    local meta = { target_directory = "/t", packages = { { name = "p", targets = { { name = "tool", kind = { "bin" } } } } } }
    local s = R.build({ name = "n", cmd = "run", package = "p", bin = "tool", args = "a; $(id)", profiler = "perf" }, {}, meta)
    H.eq("perf", s.tool)
    H.match(s.argv[3], "perf record -F 999 --call-graph dwarf", true)
    H.match(s.argv[3], "'/t/xyno-profile'", true)
    H.match(s.argv[3], "perf script -i '/t/xyno-profile'/perf.data > '/t/xyno-profile'/perf.script", true)
    H.eq({ "/t/profiling/tool", "a;", "$(id)" }, vim.list_slice(s.argv, 5))
    H.not_ok(s.argv[3]:find("$(id)", 1, true))
    -- and the shell text parses (sh -n)
    local r = vim.system({ "sh", "-n", "-c", s.argv[3] }):wait()
    H.eq(0, r.code, r.stderr)
  end)
  it("profilers need a bin run", function()
    local b, e = R.build({ name = "n", cmd = "test", profiler = "samply" }, {}, {})
    H.is_nil(b)
    H.match(e, "binary", true)
  end)
end)

describe("defaults", function()
  it("one run per bin and example, plus test all", function()
    local meta = { packages = { { name = "p", targets = { { name = "tool", kind = { "bin" } }, { name = "ex", kind = { "example" } }, { name = "p", kind = { "lib" } } } } } }
    local d = R.defaults(meta)
    H.eq({ "run tool", "run ex", "test all" }, vim.tbl_map(function(c) return c.name end, d))
    H.eq("tool", d[1].bin)
    H.is_nil(d[1].package, "single package: no -p")
  end)
end)

describe(":RustRun", function()
  local function open_all()
    return H.open_fixture("rust-tasks-tools-all", "src/main.rs")
  end
  local function trust_once()
    local orig = vim.ui.select
    vim.ui.select = function(items, opts, cb)
      if type(opts.prompt) == "string" and opts.prompt:find("^Trust ") then
        for _, c in ipairs(items) do
          if c[2] == "once" then
            return cb(c)
          end
        end
      end
      return orig(items, opts, cb)
    end
    return function()
      vim.ui.select = orig
    end
  end

  it("defines its commands", function()
    for _, n in ipairs({ "RustRun", "RustRunLast", "RustRunEdit", "RustRunDelete" }) do
      H.ok(vim.api.nvim_get_commands({})[n], n)
    end
  end)

  it("opens a picker with defaults on first use, runs the choice with env in the project root", function()
    H.need_rust()
    local restore = trust_once()
    local dir = open_all()
    local picked
    local orig = Snacks.picker
    Snacks.picker = function(o)
      picked = o
    end
    vim.cmd("RustRun")
    H.wait_for(function() return picked end, 15000, "picker")
    Snacks.picker = orig
    local texts = vim.tbl_map(function(i) return i.text end, picked.items)
    H.ok(texts[1]:find("run tool", 1, true), vim.inspect(texts))
    H.ok(texts[#texts]:find("new configuration", 1, true))
    -- give the first one an env and arguments, then run it
    local cfg = picked.items[1].cfg
    cfg.env = { MY_VAR = "x y" }
    cfg.args = "--flag 'two words'"
    R.save(dir, cfg, cfg.name)
    local before = #terms
    vim.cmd("RustRun run tool")
    H.wait_for(function() return #terms > before end, 15000, "terminal")
    local t = terms[#terms]
    H.eq({ "cargo", "run", "--bin", "tool", "--all-features", "--", "--flag", "two words" }, t.cmd)
    H.eq({ MY_VAR = "x y" }, t.opts.env)
    H.eq(rc.canon(dir), rc.canon(t.opts.cwd))
    -- and :RustRunLast repeats it
    before = #terms
    vim.cmd("RustRunLast")
    H.wait_for(function() return #terms > before end, 15000, "terminal again")
    H.eq(t.cmd, terms[#terms].cmd)
    restore()
  end)

  it("says so when nothing was run yet / the name is unknown", function()
    H.need_rust()
    open_all()
    local n = H.capture_notify()
    vim.cmd("RustRunLast")
    H.wait_for(function() return #n.list > 0 end, 15000, "notification")
    H.match(n.list[1].msg, "nothing was run yet", true)
    vim.cmd("RustRun nope")
    H.wait_for(function() return #n.list > 1 end, 15000, "notification")
    H.match(n.list[2].msg, "no run configuration", true)
  end)

  it("a missing profiler is reported, nothing runs", function()
    H.need_rust()
    local dir = open_all()
    R.save(dir, { name = "prof", cmd = "run", bin = "tool", profiler = "samply" })
    local real = vim.fn.executable
    vim.fn.executable = function(x) return x == "samply" and 0 or real(x) end
    local n = H.capture_notify()
    local before = #terms
    vim.cmd("RustRun prof")
    local hit = H.wait_for(function()
      for _, x in ipairs(n.list) do
        if x.msg:find("not installed", 1, true) then return x end
      end
    end, 15000, "install hint")
    vim.fn.executable = real
    H.match(hit.msg, "cargo install samply", true)
    H.eq(before, #terms)
  end)

  it("the prompts build a configuration (target, command, args, cargo args, env, name)", function()
    local meta = { packages = { { name = "p", targets = { { name = "tool", kind = { "bin" } } } } } }
    local answers = { "--verbose 'a b'", "--release", "RUST_LOG=debug", "my run" }
    local o_sel, o_in = vim.ui.select, vim.ui.input
    vim.ui.select = function(items, opts, cb)
      if opts.prompt == "Target" then
        return cb(items[1])
      end
      if opts.prompt:find("^cargo command") then
        return cb("run")
      end
      if opts.prompt:find("^Profiler") then
        return cb("none")
      end
      error("unexpected select " .. opts.prompt)
    end
    vim.ui.input = function(opts, cb)
      local a = table.remove(answers, 1)
      cb(a)
    end
    local got
    R.prompt("/x", meta, nil, function(c) got = c end)
    vim.ui.select, vim.ui.input = o_sel, o_in
    H.eq("tool", got.bin)
    H.eq("--verbose 'a b'", got.args)
    H.eq("--release", got.cargo_args)
    H.eq({ RUST_LOG = "debug" }, got.env)
    H.eq("my run", got.name)
  end)

  it("really runs: cargo receives the arguments and the environment", function()
    H.need_rust()
    local dir = H.tmpdir()
    vim.fn.mkdir(dir .. "/src", "p")
    vim.fn.writefile({ '[package]', 'name = "echo_rc"', 'version = "0.1.0"', 'edition = "2021"' }, dir .. "/Cargo.toml")
    vim.fn.writefile({ 'fn main() { println!("ENV={} ARGS={:?}", std::env::var("RC_PROBE").unwrap_or_default(), std::env::args().skip(1).collect::<Vec<_>>()); }' }, dir .. "/src/main.rs")
    local b = R.build({ name = "e", cmd = "run", bin = "echo_rc", args = "one 'two words' '$HOME'", env = { RC_PROBE = "ok1" } }, {})
    local argv = vim.list_extend({ "cargo" }, vim.list_slice(b.argv, 2))
    table.insert(argv, 2, "--quiet")
    local r = vim.system(argv, { cwd = dir, env = b.env, text = true }):wait(120000)
    H.eq(0, r.code, r.stderr)
    H.match(r.stdout, 'ENV=ok1 ARGS=["one", "two words", "$HOME"]', true)
  end)

  it("the profiling profile is defined on the command line (no [profile.profiling] needed)", function()
    H.need_rust()
    local dir = H.tmpdir()
    vim.fn.mkdir(dir .. "/src", "p")
    vim.fn.writefile({ '[package]', 'name = "prof_rc"', 'version = "0.1.0"', 'edition = "2021"' }, dir .. "/Cargo.toml")
    vim.fn.writefile({ "fn main() {}" }, dir .. "/src/main.rs")
    local argv = { "cargo", "build", "--profile", "profiling" }
    vim.list_extend(argv, R.PROFILING_FLAGS)
    local r = vim.system(argv, { cwd = dir, text = true }):wait(180000)
    H.eq(0, r.code, r.stderr)
    H.ok(vim.uv.fs_stat(dir .. "/target/profiling/prof_rc"), "binary in target/profiling")
  end)
end)
