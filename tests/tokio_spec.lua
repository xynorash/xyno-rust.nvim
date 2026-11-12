-- xyno_rust.tokio: entry-point detection, the project checklist (pure), the real file readers on a temp
-- crate, :TokioConsole with a fake terminal, and the once-per-root debug hint.
local H = require("xyno_rust_test.helpers")
local terms = H.fake_snacks()
require("xyno_rust").setup()
local T = require("xyno_rust.tokio")

local function crate(deps, extra)
  local dir = H.tmpdir()
  vim.fn.mkdir(dir .. "/src", "p")
  vim.fn.writefile(vim.list_extend({ '[package]', 'name = "tk"', 'version = "0.1.0"', 'edition = "2021"', "[dependencies]" }, deps or {}), dir .. "/Cargo.toml")
  vim.fn.writefile({ "#[tokio::main]", "async fn main() {}" }, dir .. "/src/main.rs")
  for p, text in pairs(extra or {}) do
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. p), "p")
    vim.fn.writefile(vim.split(text, "\n"), dir .. "/" .. p)
  end
  return dir
end

describe("detect", function()
  it("finds tokio::main and tokio::test, with arguments, not comments or other runtimes", function()
    local got = T.detect({ "// #[tokio::main]", "#[tokio::main(flavor = \"multi_thread\")]", "fn a(){}", "  #[tokio::test]", "#[async_std::main]", "#[test]" })
    H.eq({ { line = 2, kind = "main" }, { line = 4, kind = "test" } }, got)
  end)
end)

describe("checks", function()
  local meta = { packages = { { name = "p", dependencies = { { name = "tokio" } } } } }
  it("lists what is missing with the line to add", function()
    local c = T.checks({ meta = meta, unstable = false, init = false, exe = false, attrs = {} })
    H.eq({ true, false, false, false, false }, vim.tbl_map(function(x) return x.ok end, c))
    local text, all = T.report(c, { { line = 1, kind = "main" } })
    H.eq(false, all)
    H.match(text, "console-subscriber", true)
    H.match(text, "tokio_unstable", true)
    H.match(text, "cargo install --locked tokio-console", true)
    H.match(text, "1 tokio entry point", true)
  end)
  it("everything present: complete", function()
    local m2 = { packages = { { name = "p", dependencies = { { name = "tokio" }, { name = "console-subscriber" } } } } }
    local _, all = T.report(T.checks({ meta = m2, unstable = true, init = true, exe = true, attrs = {} }), {})
    H.ok(all)
  end)
end)

describe("project readers", function()
  it("finds --cfg tokio_unstable in .cargo/config.toml or RUSTFLAGS", function()
    local d = crate({}, { [".cargo/config.toml"] = '[build]\nrustflags = ["--cfg", "tokio_unstable"]' })
    H.eq({ true, ".cargo/config.toml" }, { T.unstable_cfg(d, {}) })
    H.eq(false, (T.unstable_cfg(crate({}), {})))
    H.eq({ true, "environment" }, { T.unstable_cfg(crate({}), { RUSTFLAGS = "--cfg tokio_unstable" }) })
  end)
  it("finds the console_subscriber::init() call under src/", function()
    local d = crate({}, { ["src/telemetry/mod.rs"] = "pub fn start() { console_subscriber::init(); }" })
    H.ok((T.init_call(d, nil)))
    H.eq(false, (T.init_call(crate({}), nil)))
  end)
end)

describe(":TokioConsole", function()
  it("reports the gaps of a project that is not set up, launches nothing", function()
    H.need_rust()
    local d = crate({ 'tokio = { version = "1", features = ["full"] }' })
    vim.cmd("cd " .. vim.fn.fnameescape(d))
    vim.cmd("edit " .. vim.fn.fnameescape(d .. "/src/main.rs"))
    local n = H.capture_notify()
    vim.cmd("TokioConsole")
    H.wait_for(function() return #n.list > 0 end, 30000, "report")
    H.match(n.list[1].msg, "[ ] the project depends on console-subscriber", true)
    H.match(n.list[1].msg, "[x] the project depends on tokio", true)
    H.eq(0, #terms)
  end)

  it("a complete project (with a tokio-console on PATH) launches it with the given address", function()
    H.need_rust()
    local d = crate({ 'tokio = "1"', 'console-subscriber = "0.4"' }, {
      [".cargo/config.toml"] = 'rustflags = ["--cfg", "tokio_unstable"]',
      ["src/lib.rs"] = "pub fn i() { console_subscriber::init(); }",
    })
    local bin = d .. "/bin"
    vim.fn.mkdir(bin, "p")
    vim.fn.writefile({ "#!/bin/sh" }, bin .. "/tokio-console")
    vim.fn.setfperm(bin .. "/tokio-console", "rwxr-xr-x")
    local path = vim.env.PATH
    vim.env.PATH = bin .. ":" .. path
    vim.cmd("cd " .. vim.fn.fnameescape(d))
    vim.cmd("edit " .. vim.fn.fnameescape(d .. "/src/main.rs"))
    vim.cmd("TokioConsole http://127.0.0.1:6670")
    H.wait_for(function() return #terms > 0 end, 30000, "terminal")
    vim.env.PATH = path
    H.eq({ "tokio-console", "http://127.0.0.1:6670" }, terms[#terms].cmd)
  end)
end)

describe("debug_hint", function()
  it("speaks once per root, only in a file with a tokio entry point", function()
    H.need_rust()
    T._reset_hints()
    local d = crate({ 'tokio = "1"' })
    vim.cmd("edit " .. vim.fn.fnameescape(d .. "/src/main.rs"))
    local n = H.capture_notify()
    H.ok(T.debug_hint())
    H.eq(false, T.debug_hint())
    H.match(n.list[1].msg, ":TokioConsole", true)
    T._reset_hints()
    vim.cmd("enew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "fn main() {}" })
    H.eq(false, T.debug_hint())
  end)
end)
