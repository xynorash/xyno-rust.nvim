-- Shared run configurations: .xynovim/run.toml is read only in a trusted workspace, merged with the
-- personal ones (personal wins on a name clash), sanitized like personal ones, written by :RustRunShare.
-- Also the mini TOML reader it uses.
local H = require("xyno_rust_test.helpers")
H.fake_snacks()
require("xyno_rust").setup()
local R = require("xyno_rust.run_configs")
local T = require("xyno_rust.toml_mini")
local trust = require("xyno_rust.trust")

after_each(function()
  pcall(vim.fn.delete, R.file())
  pcall(vim.fn.delete, trust.file())
end)

local function crate(toml)
  local dir = H.tmpdir()
  vim.fn.writefile({ '[package]', 'name = "shr"', 'version = "0.1.0"', 'edition = "2021"' }, dir .. "/Cargo.toml")
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile({ "fn main() {}" }, dir .. "/src/main.rs")
  vim.fn.mkdir(dir .. "/.xynovim", "p")
  if toml then
    vim.fn.writefile(vim.split(toml, "\n", { plain = true }), dir .. "/.xynovim/run.toml")
  end
  return dir
end

local FILE = [==[
# team configs
[[run]]
name = "serve"
cmd = "run"
bin = "server"
args = "--port 8080 'a b'"
cargo_args = "--release"
env = { RUST_LOG = "debug" }
profiler = "samply"

[[run]]
name = "unit"
cmd = "test"
args = "--nocapture"

[[run]]
name = "evil; rm -rf ~"
cmd = "sh"
args = "$(id)"
]==]

describe("toml_mini", function()
  it("reads tables, arrays of tables, inline tables, arrays, comments", function()
    local d = assert(T.parse('# c\n[[a]]\nx = "1" # t\ny = [1,\n 2, # k\n]\nz = { k = true, "q-r" = \'s\' }\n[a.sub]\nn = -3\n[[a]]\nx = "2"\n'))
    H.eq(2, #d.a)
    H.eq({ 1, 2 }, d.a[1].y)
    H.eq({ k = true, ["q-r"] = "s" }, d.a[1].z)
    H.eq(-3, d.a[1].sub.n)
    H.eq("2", d.a[2].x)
  end)
  it("rejects what it does not understand, with a line number", function()
    H.match(select(2, T.parse("a = 1.5")), "line 1: unsupported value", true)
    H.match(select(2, T.parse('a = 1\nb = "x')), "line 2: unterminated string", true)
    H.match(select(2, T.parse("a = 1\na = 2")), "set twice", true)
    H.match(select(2, T.parse("a b")), "expected", true)
    H.match(select(2, T.parse("a = 1 b")), "unexpected text", true)
    H.match(select(2, T.parse(("a = 1\n"):rep(20000))), "larger than", true)
  end)
  it("escapes survive a quote / parse round trip", function()
    local s = 'a "q" \\ b\tc'
    H.eq(s, T.parse("k = " .. T.quote(s)).k)
  end)
end)

describe("shared run configurations", function()
  it("an untrusted workspace lists nothing, but counts the entries", function()
    local dir = crate(FILE)
    local sh = R.load_shared(dir)
    H.ok(sh.exists)
    H.eq(false, sh.trusted)
    H.eq({}, sh.configs)
    H.eq(3, sh.count)
    H.eq({}, R.load_all(dir).configs)
  end)

  it("a trusted workspace gets them, sanitized, marked shared", function()
    local dir = crate(FILE)
    trust.trust(dir)
    local all = R.load_all(dir).configs
    H.eq(3, #all)
    local serve = all[1]
    H.eq("serve", serve.name)
    H.ok(serve.shared)
    H.eq("server", serve.bin)
    H.eq({ RUST_LOG = "debug" }, serve.env)
    H.eq("samply", serve.profiler)
    -- an unknown command falls back to `run`; the odd name stays a name (it is never executed)
    H.eq("run", all[3].cmd)
    -- built into an argv list: no shell, `$(id)` is one literal word
    local b = R.build(all[3], {}, nil)
    H.eq("cargo", b.argv[1])
    H.ok(vim.tbl_contains(b.argv, "$(id)"))
  end)

  it("a personal configuration with the same name overrides the shared one", function()
    local dir = crate(FILE)
    trust.trust(dir)
    R.save(dir, { name = "serve", cmd = "build" })
    local all = R.load_all(dir).configs
    local n = 0
    for _, c in ipairs(all) do
      if c.name == "serve" then
        n = n + 1
        H.eq("build", c.cmd)
        H.is_nil(c.shared)
      end
    end
    H.eq(1, n)
  end)

  it("a broken file is reported, not guessed", function()
    local dir = crate("[[run]]\nname = 'x'\nargs = $HOME\n")
    trust.trust(dir)
    local sh = R.load_shared(dir)
    H.eq({}, sh.configs)
    H.match(sh.err, ".xynovim/run.toml: line 3", true)
  end)

  it("no file: nothing changes", function()
    local dir = crate(nil)
    H.eq(false, R.load_shared(dir).exists)
    R.save(dir, { name = "mine", cmd = "check" })
    H.eq({ "mine" }, vim.tbl_map(function(c) return c.name end, R.load_all(dir).configs))
  end)

  it("share writes a personal configuration to the file and keeps the other entries; to_toml round-trips", function()
    local dir = crate(FILE)
    trust.trust(dir)
    R.save(dir, { name = "my 'job'", cmd = "run", bin = "x", args = [[--a "b c"]], env = { K = 'v"1' }, profiler = "flamegraph" })
    H.ok(R.share(dir, "my 'job'"))
    local all = R.load_all(dir).configs
    local names = vim.tbl_map(function(c) return c.name end, all)
    H.eq(4, #names, vim.inspect(names)) -- the personal one wins over its shared copy: still 4 distinct names
    local sh = R.load_shared(dir)
    H.eq(4, sh.count)
    local copy
    for _, c in ipairs(sh.configs) do
      if c.name == "my 'job'" then copy = c end
    end
    H.eq({ K = 'v"1' }, copy.env)
    H.eq("flamegraph", copy.profiler)
    H.eq([[--a "b c"]], copy.args)
    -- sharing again replaces, not duplicates
    H.ok(R.share(dir, "my 'job'"))
    H.eq(4, R.load_shared(dir).count)
    local _, err = R.share(dir, "nope")
    H.match(err, "no personal run configuration", true)
  end)

  it("share refuses to overwrite a file it can not read", function()
    local dir = crate("[[run]]\nname = \n")
    R.save(dir, { name = "a", cmd = "run" })
    local ok, err = R.share(dir, "a")
    H.is_nil(ok)
    H.match(err, "fix the file first", true)
  end)

  it(":RustRun: unknown while untrusted, runs as one argv list once trusted", function()
    H.need_rust()
    local terms = H.fake_snacks()
    local dir = crate(FILE)
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/src/main.rs"))
    local n = H.capture_notify()
    vim.cmd("RustRun unit")
    H.wait_for(function() return #n.list > 0 end, 15000, "notification")
    H.match(n.list[1].msg, "no run configuration", true)
    H.eq(0, #terms)
    trust.trust(dir)
    vim.cmd("RustRun unit")
    H.wait_for(function() return #terms > 0 end, 15000, "terminal")
    H.eq({ "cargo", "test", "--all-features", "--", "--nocapture" }, terms[1].cmd)
  end)
end)

describe("trust follows the shared file", function()
  it("a changed .xynovim/run.toml changes the workspace fingerprint (a pulled entry asks again)", function()
    local dir = crate(FILE)
    local a = trust.fingerprint(dir)
    vim.fn.writefile({ "[[run]]", 'name = "x"', 'cmd = "run"' }, dir .. "/.xynovim/run.toml")
    local b = trust.fingerprint(dir)
    H.ok(a.hash ~= b.hash)
    H.ok(b.files[".xynovim/run.toml"], vim.inspect(b.files))
  end)
end)
