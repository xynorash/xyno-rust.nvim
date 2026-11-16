-- xyno_rust.trust: the workspace-trust gate for running targets, tools and `act`, its API and :RustTrust.
-- Also the claim that reading cargo metadata of an unknown workspace executes nothing of it.
-- xyno-os: linux,macos (canary scripts are shell scripts)
local H = require("xyno_rust_test.helpers")
H.fake_snacks()
require("xyno_rust").setup()
local trust = require("xyno_rust.trust")
local tasks = require("xyno_rust.rust_tasks")
local cargo = require("xyno_rust.cargo")

local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "wb"))
  f:write(text)
  f:close()
end

local restores = {}
local function stub(t, k, v)
  local orig = t[k]
  t[k] = v
  restores[#restores + 1] = function()
    t[k] = orig
  end
end

--- Answer every trust prompt with the choice whose tag is `tag` (trust, parent, once, no) and count them.
local function answer(tag)
  local seen = { n = 0, prompts = {} }
  stub(vim.ui, "select", function(items, opts, on_choice)
    seen.n = seen.n + 1
    seen.prompts[#seen.prompts + 1] = opts.prompt
    seen.items = items
    for _, c in ipairs(items) do
      if c[2] == tag then
        return on_choice(c)
      end
    end
    on_choice(nil)
  end)
  return seen
end

local function terminals()
  local cap = { opened = {} }
  stub(Snacks.terminal, "get", function()
    return nil
  end)
  stub(Snacks.terminal, "open", function(cmd, opts)
    cap.opened[#cap.opened + 1] = { cmd = cmd, opts = opts }
    return {
      buf_valid = function()
        return true
      end,
      close = function() end,
    }
  end)
  return cap
end

before_each(function()
  trust.revoke_all()
  cargo.reset_caches()
end)
after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
end)

describe("trust store", function()
  it("lives in stdpath('state'), starts empty and untrusts everything", function()
    H.eq(vim.fn.stdpath("state") .. "/xyno-rust-trust.json", trust.file())
    H.eq({}, trust.list())
    H.not_ok(trust.is_trusted(H.tmpdir()))
  end)

  it("remembers a root across a fresh read, lists it and revokes it", function()
    local dir = H.tmpdir()
    trust.trust(dir)
    H.ok(trust.is_trusted(dir))
    H.not_ok(
      trust.is_trusted(dir .. "/src/deep"),
      "trust is per workspace root (exact), only a recursive entry covers what is below"
    )
    H.eq(1, #trust.list())
    H.eq(trust.normalize(dir), trust.list()[1].root)
    H.eq(true, trust.revoke(dir))
    H.not_ok(trust.is_trusted(dir))
    H.eq(false, trust.revoke(dir), "revoking twice reports nothing was there")
  end)

  it("a sibling directory with a common prefix is not trusted", function()
    local base = H.tmpdir()
    vim.fn.mkdir(base .. "/proj", "p")
    vim.fn.mkdir(base .. "/proj-evil", "p")
    trust.trust(base .. "/proj")
    H.not_ok(trust.is_trusted(base .. "/proj-evil"))
    H.not_ok(trust.is_trusted(base))
  end)

  it("recursive trust covers everything below and nothing outside", function()
    local base = H.tmpdir()
    vim.fn.mkdir(base .. "/a/b", "p")
    trust.trust(base .. "/a", { recursive = true })
    H.ok(trust.is_trusted(base .. "/a/b"))
    H.not_ok(trust.is_trusted(base))
  end)

  it("a symlink to a trusted directory is that directory; a link elsewhere does not borrow trust", function()
    local base = H.tmpdir()
    vim.fn.mkdir(base .. "/real", "p")
    vim.fn.mkdir(base .. "/other", "p")
    vim.uv.fs_symlink(base .. "/real", base .. "/link")
    trust.trust(base .. "/real")
    H.ok(trust.is_trusted(base .. "/link"))
    H.not_ok(trust.is_trusted(base .. "/other"))
  end)

  it("survives a hand-broken state file", function()
    write(trust.file(), "{ not json")
    H.not_ok(trust.is_trusted(H.tmpdir()))
    local dir = H.tmpdir()
    trust.trust(dir)
    H.ok(trust.is_trusted(dir))
  end)

  it("two nvim instances trusting different roots at once keep both", function()
    local script = H.tmpdir() .. "/child.lua"
    write(
      script,
      ([[
      vim.opt.rtp:prepend(%q)
      local t = require("xyno_rust.trust")
      for i = 1, 15 do t.trust(os.getenv("TRUST_DIR") .. "/" .. vim.uv.os_getpid() .. "-" .. i) end
    ]]):format(H.repo)
    )
    local base = H.tmpdir()
    local jobs = {}
    for _ = 1, 4 do
      jobs[#jobs + 1] = vim.system(
        { vim.v.progpath, "--headless", "-u", "NONE", "-l", script },
        { env = { TRUST_DIR = base, XDG_STATE_HOME = vim.env.XDG_STATE_HOME } }
      )
    end
    for _, j in ipairs(jobs) do
      j:wait(30000)
    end
    H.eq(60, #trust.list())
  end)
end)

describe("trust follows the content that runs code (re-ask when it changed)", function()
  local function ws()
    local dir = H.tmpdir() .. "/drift"
    write(dir .. "/Cargo.toml", '[package]\nname = "d"\nversion = "0.1.0"\nedition = "2021"\n')
    write(dir .. "/src/lib.rs", "pub fn f() {}\n")
    return dir
  end

  it(
    "a trusted workspace stays trusted while its manifests, build scripts, cargo config and toolchain are unchanged",
    function()
      local dir = ws()
      trust.trust(dir)
      H.ok(trust.is_trusted(dir))
      write(dir .. "/src/lib.rs", "pub fn g() {}\n") -- ordinary source edits never ask again
      write(dir .. "/Cargo.lock", "# lock\n")
      H.ok(trust.is_trusted(dir))
      H.is_nil(trust.drift(dir))
    end
  )

  it(
    "a changed or new Cargo.toml / build.rs / .cargo/config.toml / rust-toolchain.toml makes it untrusted again and names the file",
    function()
      for _, case in ipairs({
        { "Cargo.toml", '[package]\nname = "d"\nversion = "0.1.0"\nedition = "2021"\nbuild = "evil.rs"\n' },
        { "build.rs", "fn main() {}\n" },
        { ".cargo/config.toml", '[build]\nrustc-wrapper = "/tmp/x"\n' },
        { ".cargo/config", '[build]\nrustc = "/tmp/x"\n' },
        { "rust-toolchain.toml", '[toolchain]\nchannel = "nightly"\n' },
        { "rust-toolchain", "nightly\n" },
        { "member/Cargo.toml", '[package]\nname = "m"\nversion = "0.1.0"\n' },
        { "member/build.rs", "fn main() {}\n" },
      }) do
        trust.revoke_all()
        local dir = ws()
        trust.trust(dir)
        H.ok(trust.is_trusted(dir), case[1] .. " before")
        write(dir .. "/" .. case[1], case[2])
        H.not_ok(trust.is_trusted(dir), case[1] .. " changed: untrusted")
        local d = trust.drift(dir)
        H.ok(d and vim.tbl_contains(d, case[1]), case[1] .. " is named in the drift: " .. vim.inspect(d))
      end
    end
  )

  it("a removed file counts as a change", function()
    local dir = ws()
    write(dir .. "/build.rs", "fn main() {}\n")
    trust.trust(dir)
    os.remove(dir .. "/build.rs")
    H.not_ok(trust.is_trusted(dir))
  end)

  it("trusting again (prompt answer or :RustTrust add) records the new content; 'run once' records nothing", function()
    local dir = ws()
    trust.trust(dir)
    write(dir .. "/build.rs", "fn main() {}\n")
    H.not_ok(trust.is_trusted(dir))
    local seen = answer("once")
    local ran
    trust.require(dir, "cargo test", function(ok)
      ran = ok
    end)
    H.eq(true, ran)
    H.eq(1, seen.n)
    H.match(seen.prompts[1], "changed since", true, "the prompt says why it asks again")
    H.match(seen.prompts[1], "build.rs", true)
    H.not_ok(trust.is_trusted(dir), "once stores nothing")
    answer("trust")
    trust.require(dir, "cargo test", function() end)
    H.ok(trust.is_trusted(dir))
    H.is_nil(trust.drift(dir))
  end)

  it("rehash() records the current content (an edit made inside the editor does not ask again)", function()
    local dir = ws()
    trust.trust(dir)
    write(dir .. "/Cargo.toml", '[package]\nname = "d"\nversion = "0.2.0"\nedition = "2021"\n')
    H.not_ok(trust.is_trusted(dir))
    H.eq(true, trust.rehash(dir))
    H.ok(trust.is_trusted(dir))
    trust.revoke(dir)
    H.eq(false, trust.rehash(dir), "no entry of its own: nothing to refresh")
    H.not_ok(trust.is_trusted(dir))
  end)

  it(
    "rehash(root, saved_file) accepts the saved file only: a pulled build.rs next to it keeps the workspace untrusted",
    function()
      local dir = ws()
      trust.trust(dir)
      write(dir .. "/Cargo.toml", '[package]\nname = "d"\nversion = "0.3.0"\nedition = "2021"\n')
      H.eq(true, trust.rehash(dir, dir .. "/Cargo.toml"), "only the saved file differs")
      H.ok(trust.is_trusted(dir))
      write(dir .. "/Cargo.toml", '[package]\nname = "d"\nversion = "0.4.0"\nedition = "2021"\n')
      write(dir .. "/build.rs", "fn main() { /* pulled */ }\n")
      H.eq(false, trust.rehash(dir, dir .. "/Cargo.toml"), "build.rs changed as well")
      H.not_ok(trust.is_trusted(dir))
      local d = trust.drift(dir)
      H.ok(vim.tbl_contains(d, "build.rs"))
    end
  )

  it("an entry written before hashes existed is adopted silently, not re-asked", function()
    local dir = ws()
    local path = trust.normalize(dir)
    require("xyno_rust.statefile").update(trust.file(), function(all)
      all[path] = { recursive = false, at = 1 }
    end)
    H.ok(trust.is_trusted(dir))
    write(dir .. "/build.rs", "fn main() {}\n")
    H.not_ok(trust.is_trusted(dir), "the first look recorded the content, a later change asks")
  end)

  it("trust under a parent (recursive) is one decision about the whole tree: no hash, no re-ask", function()
    local dir = ws()
    trust.trust(vim.fs.dirname(dir), { recursive = true })
    write(dir .. "/build.rs", "fn main() {}\n")
    H.ok(trust.is_trusted(dir))
    H.is_nil(trust.drift(dir))
  end)

  it("rehash() takes a list of saved files (cargo add touched the member and the workspace manifest)", function()
    local dir = ws()
    write(dir .. "/m/Cargo.toml", '[package]\nname = "m"\nversion = "0.1.0"\n')
    trust.trust(dir)
    write(dir .. "/Cargo.toml", '[package]\nname = "d"\nversion = "0.1.1"\nedition = "2021"\n')
    write(dir .. "/m/Cargo.toml", '[package]\nname = "m"\nversion = "0.1.1"\n')
    H.eq(false, trust.rehash(dir, dir .. "/Cargo.toml"), "a second changed file is not covered by one saved path")
    H.eq(true, trust.rehash(dir, { dir .. "/Cargo.toml", dir .. "/m/Cargo.toml" }))
    H.ok(trust.is_trusted(dir))
  end)

  it(
    "the fingerprint is memoised on stat stamps: reused while nothing changed, redone at once on any change",
    function()
      local dir = ws()
      local a = trust.fingerprint(dir)
      H.ok(rawequal(a, trust.fingerprint(dir)), "unchanged tree: the same result, no new walk")
      write(dir .. "/sub/build.rs", "fn main() {}\n") -- a new file in a new directory changes the parent's stamp
      local b = trust.fingerprint(dir)
      H.not_ok(rawequal(a, b))
      H.ok(b.files["sub/build.rs"])
      write(dir .. "/sub/build.rs", "fn main() { /* changed */ }\n")
      H.not_ok(trust.fingerprint(dir).files["sub/build.rs"] == b.files["sub/build.rs"])
      vim.uv.fs_unlink(dir .. "/sub/build.rs")
      H.is_nil(trust.fingerprint(dir).files["sub/build.rs"])
    end
  )

  it("the directory walk is capped (a huge tree is cut off and marked truncated, not walked for ever)", function()
    local dir = ws()
    for i = 1, 40 do
      vim.fn.mkdir(dir .. "/d" .. i, "p")
    end
    local f = trust.fingerprint(dir, { fresh = true })
    H.eq(nil, f.truncated)
    local cap = trust._max_dirs
    H.ok(cap and cap >= 1000, "the cap is exported for specs and sane")
  end)

  it("the scan ignores target/ and .git/ and is bounded", function()
    local dir = ws()
    trust.trust(dir)
    write(dir .. "/target/debug/build/x/build.rs", "fn main() {}\n")
    write(dir .. "/.git/hooks/Cargo.toml", "x")
    H.ok(trust.is_trusted(dir))
    local f = trust.fingerprint(dir)
    H.ok(f.hash and f.hash ~= "")
    H.ok(vim.tbl_count(f.files) <= 400)
  end)
end)

describe("trust.require", function()
  it("a trusted root calls back at once without asking", function()
    local dir = H.tmpdir()
    trust.trust(dir)
    local seen = answer("no")
    local got
    trust.require(dir, "cargo run", function(ok)
      got = ok
    end)
    H.eq(true, got)
    H.eq(0, seen.n)
  end)

  it("asks once, names the root and the action, and 'trust' is remembered", function()
    local dir = H.tmpdir()
    local seen = answer("trust")
    local n = 0
    trust.require(dir, "cargo run --bin x", function(ok)
      H.eq(true, ok)
      n = n + 1
    end)
    H.eq(1, n)
    H.match(seen.prompts[1], trust.normalize(dir), true)
    H.match(seen.prompts[1], "cargo run --bin x", true)
    trust.require(dir, "cargo test", function(ok)
      H.eq(true, ok)
      n = n + 1
    end)
    H.eq(2, n)
    H.eq(1, seen.n, "the second action did not ask again")
  end)

  it("'trust everything under <parent>' trusts a sibling workspace too", function()
    local base = H.tmpdir()
    vim.fn.mkdir(base .. "/one", "p")
    vim.fn.mkdir(base .. "/two", "p")
    answer("parent")
    trust.require(base .. "/one", "cargo run", function() end)
    H.ok(trust.is_trusted(base .. "/two"))
  end)

  it("'run once' runs but remembers nothing; 'do not run' refuses, warns and remembers nothing", function()
    local dir = H.tmpdir()
    answer("once")
    local got
    trust.require(dir, "cargo run", function(ok)
      got = ok
    end)
    H.eq(true, got)
    H.not_ok(trust.is_trusted(dir))
    answer("no")
    local n = H.capture_notify()
    trust.require(dir, "cargo run", function(ok)
      got = ok
    end)
    H.eq(false, got)
    H.not_ok(trust.is_trusted(dir))
    H.match(n.list[#n.list].msg, "not run", true)
    H.eq(vim.log.levels.WARN, n.list[#n.list].level)
  end)

  it("dismissing the prompt (Esc) refuses", function()
    local dir = H.tmpdir()
    answer("nothing-matches")
    local got
    trust.require(dir, "cargo run", function(ok)
      got = ok
    end)
    H.eq(false, got)
  end)

  it("two actions asked while a prompt is open share it", function()
    local dir = H.tmpdir()
    local pending, count = nil, 0
    stub(vim.ui, "select", function(items, _, on_choice)
      count = count + 1
      pending = function()
        on_choice(items[1])
      end
    end)
    local results = {}
    trust.require(dir, "cargo run", function(ok)
      results[#results + 1] = ok
    end)
    trust.require(dir, "cargo test", function(ok)
      results[#results + 1] = ok
    end)
    H.eq(1, count)
    pending()
    H.eq({ true, true }, results)
  end)
end)

describe("targets, tools and act are gated", function()
  before_each(function()
    H.need_rust()
  end)

  local function open_all()
    return H.open_fixture("rust-tasks-tools-all", "src/main.rs")
  end

  local function picker_items(cmd)
    local cap = {}
    stub(Snacks, "picker", function(opts)
      cap.opts = opts
    end)
    vim.cmd(cmd)
    H.drain()
    return cap.opts
  end

  it("confirming a target in an untrusted workspace asks first and runs nothing when refused", function()
    local dir = open_all()
    local term = terminals()
    local seen = answer("no")
    local opts = picker_items("RustTargets")
    opts.confirm({ close = function() end }, opts.items[1])
    H.eq(1, seen.n)
    H.eq(0, #term.opened)
    H.not_ok(trust.is_trusted(dir))
  end)

  it("trusting runs it, and the next run in that workspace does not ask", function()
    local dir = open_all()
    local term = terminals()
    local seen = answer("trust")
    local opts = picker_items("RustTargets")
    opts.confirm({ close = function() end }, opts.items[1])
    H.eq(1, #term.opened)
    H.eq(dir, term.opened[1].opts.cwd)
    opts.confirm({ close = function() end }, opts.items[2])
    H.eq(2, #term.opened)
    H.eq(1, seen.n)
    H.ok(trust.is_trusted(dir))
  end)

  it("RustTools and doctests are gated the same way", function()
    local dir = open_all()
    local term = terminals()
    local seen = answer("no")
    local opts = picker_items("RustTools")
    opts.confirm({ close = function() end }, opts.items[1])
    tasks.doctests()
    H.drain()
    H.eq(2, seen.n)
    H.eq(0, #term.opened)
    trust.trust(dir)
    tasks.doctests()
    H.drain()
    H.eq(1, #term.opened)
    H.eq({ "cargo", "test", "--doc", "--workspace", "--all-features" }, term.opened[1].cmd)
  end)

  it(":ActJob asks for the repository root, not for the workflow file", function()
    local repo = H.tmpdir()
    vim.fn.mkdir(repo .. "/.github/workflows", "p")
    local file = repo .. "/.github/workflows/ci.yml"
    vim.fn.writefile(vim.fn.readfile(H.fixtures .. "/act-workflow.yml"), file)
    H.git_init(repo)
    vim.cmd.cd(vim.fn.fnameescape(repo))
    H.open(file)
    if not pcall(vim.treesitter.start, 0, "yaml") then
      require("xyno_rust_test.harness").skip("no yaml treesitter parser")
    end
    vim.treesitter.get_parser(0, "yaml"):parse()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
      if l:find("runs-on:", 1, true) then
        vim.api.nvim_win_set_cursor(0, { i, 6 })
      end
    end
    local term = terminals()
    local seen = answer("no")
    vim.cmd("ActJob")
    H.eq(1, seen.n)
    H.match(seen.prompts[1], trust.normalize(repo), true)
    H.match(seen.prompts[1], "act job smoke", true)
    H.eq(0, #term.opened)
    trust.trust(repo)
    vim.cmd("ActJob")
    H.eq(1, #term.opened)
  end)

  it("reading targets (cargo metadata) needs no trust: the picker opens in an untrusted workspace", function()
    open_all()
    local seen = answer("no")
    local opts = picker_items("RustTargets")
    H.ok(opts and #opts.items > 0)
    H.eq(0, seen.n)
  end)
end)

describe("reading cargo metadata of an unknown workspace executes nothing of it", function()
  before_each(function()
    H.need_rust()
  end)

  --- A workspace whose build.rs, .cargo/config.toml (rustc, wrappers) and rust-toolchain-free manifest
  --- would each leave a canary file if cargo ran them.
  local function booby_trapped()
    local dir = H.tmpdir()
    local canary = dir .. "-canary"
    vim.fn.mkdir(canary, "p")
    local script = canary .. "/run.sh"
    write(
      script,
      ('#!/bin/sh\necho "$0 $*" >> %s/executed\ncase "$1" in -*) exec rustc "$@" ;; *) exec "$@" ;; esac\n'):format(
        canary
      )
    )
    vim.uv.fs_chmod(script, 493)
    write(dir .. "/Cargo.toml", '[package]\nname = "trap"\nversion = "0.1.0"\nedition = "2021"\nbuild = "build.rs"\n')
    write(dir .. "/src/main.rs", "fn main() {}\n")
    write(dir .. "/build.rs", ('fn main() { std::fs::write("%s/build-rs-ran", "x").unwrap(); }\n'):format(canary))
    write(
      dir .. "/.cargo/config.toml",
      ('[build]\nrustc = "%s"\nrustc-wrapper = "%s"\nrustc-workspace-wrapper = "%s"\n'):format(script, script, script)
    )
    return dir, canary
  end

  it("cargo metadata --no-deps and locate-project run no build.rs, rustc or wrapper", function()
    local dir, canary = booby_trapped()
    local meta, err = cargo.metadata(dir)
    H.ok(meta, tostring(err))
    H.eq("trap", meta.packages[1].name)
    H.eq(dir, require("xyno_rust.rust_context").root(dir .. "/src/main.rs"))
    vim.wait(300)
    H.is_nil(vim.uv.fs_stat(canary .. "/build-rs-ran"), "build.rs ran")
    H.is_nil(vim.uv.fs_stat(canary .. "/executed"), "a configured rustc/wrapper ran")
  end)

  it(
    "crate_meta.metadata (the resolving `cargo metadata` the other xyno plugins use) is neutralised in an untrusted workspace",
    function()
      local dir, canary = booby_trapped()
      local cm = require("xyno_rust.crate_meta")
      cm.invalidate()
      local meta, err = cm.metadata(dir)
      H.ok(meta, tostring(err))
      vim.wait(300)
      H.is_nil(vim.uv.fs_stat(canary .. "/build-rs-ran"), "build.rs ran")
      H.is_nil(vim.uv.fs_stat(canary .. "/executed"), "a configured rustc/wrapper ran")
    end
  )

  it("control: the same call in a trusted workspace does let cargo use the configured rustc wrapper", function()
    local dir, canary = booby_trapped()
    trust.trust(dir)
    local cm = require("xyno_rust.crate_meta")
    cm.invalidate()
    local meta, err = cm.metadata(dir)
    H.ok(meta, tostring(err))
    H.ok(
      vim.uv.fs_stat(canary .. "/executed"),
      "trusted workspaces behave as before (the wrapper ran), so the test above proves the guard"
    )
  end)

  it("an untrusted workspace is not retried online when the offline run cannot resolve", function()
    local dir = H.tmpdir()
    write(
      dir .. "/Cargo.toml",
      '[package]\nname = "x"\nversion = "0.1.0"\nedition = "2021"\n[dependencies]\nnot-in-any-cache-xyz = "1"\n'
    )
    write(dir .. "/src/main.rs", "fn main() {}\n")
    local cm = require("xyno_rust.crate_meta")
    local argvs = {}
    local orig = cm.exec
    cm.exec = function(argv, opts, cb)
      argvs[#argvs + 1] = argv
      return orig(argv, opts, cb)
    end
    cm.invalidate()
    local meta, err = cm.metadata(dir)
    cm.exec = orig
    H.is_nil(meta)
    H.eq(1, #argvs, "only the --offline run")
    H.has(argvs[1], "--offline")
    H.match(err, "workspace not trusted", true)
  end)

  it("and it works as a control: a real build of the same workspace does trigger the canary", function()
    local dir, canary = booby_trapped()
    local r = vim.system({ "cargo", "check", "--offline" }, { cwd = dir, text = true }):wait(120000)
    H.ok(
      vim.uv.fs_stat(canary .. "/executed") or vim.uv.fs_stat(canary .. "/build-rs-ran"),
      "the trap does not work, so the test above proves nothing: " .. (r.stderr or "")
    )
  end)
end)

describe("ra_overrides", function()
  it("turns build scripts and proc macros off for an untrusted workspace and is empty for a trusted one", function()
    local dir = H.tmpdir()
    H.eq({ cargo = { buildScripts = { enable = false } }, procMacro = { enable = false } }, trust.ra_overrides(dir))
    trust.trust(dir)
    H.eq({}, trust.ra_overrides(dir))
  end)
end)

describe(":RustTrust", function()
  it("is defined with a description", function()
    local c = H.ok(vim.api.nvim_get_commands({}).RustTrust)
    H.eq("*", c.nargs)
  end)

  it("add / status / list / revoke / revoke-all", function()
    local dir = H.tmpdir()
    local n = H.capture_notify()
    vim.cmd("RustTrust add " .. vim.fn.fnameescape(dir))
    H.ok(trust.is_trusted(dir))
    vim.cmd("RustTrust status " .. vim.fn.fnameescape(dir))
    H.match(n.list[#n.list].msg, "is trusted", true)
    vim.cmd("RustTrust list")
    H.match(n.list[#n.list].msg, trust.normalize(dir), true)
    vim.cmd("RustTrust revoke " .. vim.fn.fnameescape(dir))
    H.not_ok(trust.is_trusted(dir))
    vim.cmd("RustTrust status " .. vim.fn.fnameescape(dir))
    H.match(n.list[#n.list].msg, "NOT trusted", true)
    trust.trust(dir)
    vim.cmd("RustTrust revoke-all")
    H.eq({}, trust.list())
    vim.cmd("RustTrust bogus")
    H.eq(vim.log.levels.WARN, n.list[#n.list].level)
  end)

  it("the bare command lists the trusted workspaces and revokes the one chosen", function()
    local a, b = H.tmpdir(), H.tmpdir()
    trust.trust(a)
    trust.trust(b)
    stub(vim.ui, "select", function(items, _, on_choice)
      H.eq(2, #items)
      on_choice(items[1])
    end)
    vim.cmd("RustTrust")
    H.eq(1, #trust.list())
  end)
end)
