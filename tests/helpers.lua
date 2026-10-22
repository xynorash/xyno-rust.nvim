-- Utilities for spec files. `local H = require("xyno_rust_test.helpers")`.
--
-- Assertions   H.eq H.ok H.not_ok H.is_nil H.match H.no_match H.has H.throws
-- Waiting      H.wait_for(pred, timeout_ms, msg) H.wait_lsp(name, bufnr, ms)
-- Editor       H.feed(keys) H.open(path) H.clients() H.diagnostics(source)
--              H.start_ra(buf, root) H.need_parser(lang) H.messages() H.clear_messages() H.capture_notify()
--              H.fake_snacks() (a stand-in for snacks.nvim's picker and terminal)
-- Fixtures     H.fixture(name, {git=true}) H.open_fixture(name, rel) H.git(...)
-- Processes    H.spawn(cmd)
-- Skipping     H.skip_file(reason) H.need_rust() H.need_os({ "linux", "macos" }, reason)
--              H.need_posix(reason) and, in a spec's first 15 lines,
--              `-- xyno-os: linux (reason)` (tests/run.lua)
-- Cleanup      H.cleanup() (the runner calls it at the end; registered
--              resources are temp dirs, jobs, LSP clients)
local harness = require("xyno_rust_test.harness")

local H = {}
local repo = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
H.repo = repo
H.fixtures = repo .. "/tests/fixtures"

-- ---------------------------------------------------------------- assertions

local function fail(msg, level)
  error(msg, (level or 1) + 1)
end

-- Windows spells one path several ways (D:\\a, D:/a, d:/a): compare the
-- canonical form (forward slashes, lower-case drive letter) there.
local function canon(v)
  if type(v) == "string" then
    if v:find("%f[%a]%a:[/\\]") then
      -- also drive paths embedded in a message ("coverage loaded (D:\\x\\y)")
      return (v:gsub("\\", "/"):gsub("%f[%a](%a):/", function(d)
        return d:lower() .. ":/"
      end))
    end
    return v
  elseif type(v) == "table" then
    local t = {}
    for k, x in pairs(v) do
      t[k] = canon(x)
    end
    return t
  end
  return v
end

function H.eq(expected, actual, msg)
  local same = vim.deep_equal(expected, actual)
  if not same and vim.fn.has("win32") == 1 then
    same = vim.deep_equal(canon(expected), canon(actual))
  end
  if not same then
    fail(
      ("%sexpected %s\n  actual   %s"):format(msg and (msg .. ": ") or "", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

function H.ok(v, msg)
  if not v then
    fail(msg or ("expected a truthy value, got " .. vim.inspect(v)), 2)
  end
  return v
end

function H.not_ok(v, msg)
  if v then
    fail(msg or ("expected a falsy value, got " .. vim.inspect(v)), 2)
  end
end

function H.is_nil(v, msg)
  if v ~= nil then
    fail((msg and (msg .. ": ") or "") .. "expected nil, got " .. vim.inspect(v), 2)
  end
end

--- Lua pattern match (plain = true for a literal substring).
function H.match(str, pat, plain, msg)
  if type(str) ~= "string" or not str:find(pat, 1, plain) then
    fail((msg and (msg .. ": ") or "") .. ("%s does not match %q"):format(vim.inspect(str), pat), 2)
  end
end

function H.no_match(str, pat, plain, msg)
  if type(str) == "string" and str:find(pat, 1, plain) then
    fail((msg and (msg .. ": ") or "") .. ("%s unexpectedly matches %q"):format(vim.inspect(str), pat), 2)
  end
end

--- A list contains `item` (deep compare), or a string contains the substring.
function H.has(container, item, msg)
  local found = false
  if type(container) == "string" then
    found = container:find(item, 1, true) ~= nil
  else
    for _, v in ipairs(container) do
      if vim.deep_equal(v, item) then
        found = true
        break
      end
    end
  end
  if not found then
    fail(
      (msg and (msg .. ": ") or "") .. ("%s does not contain %s"):format(vim.inspect(container), vim.inspect(item)),
      2
    )
  end
end

--- fn must raise an error (matching `pat`, a Lua pattern, when given).
function H.throws(fn, pat)
  local ok, e = pcall(fn)
  if ok then
    fail("expected an error, none raised", 2)
  end
  if pat and not tostring(e):find(pat) then
    fail(("error %q does not match %q"):format(tostring(e), pat), 2)
  end
end

-- ------------------------------------------------------------------ waiting

--- Wait until pred() is truthy (vim.wait, the event loop keeps running).
--- Returns its value; raises `msg` on timeout.
function H.wait_for(pred, timeout_ms, msg)
  local value
  local done = vim.wait(timeout_ms or 5000, function()
    value = pred()
    return value and true or false
  end, 20)
  if not done then
    fail("timed out waiting for " .. (msg or "condition"), 2)
  end
  return value
end

function H.clients(bufnr, name)
  return vim.lsp.get_clients({ bufnr = bufnr, name = name })
end

--- Wait for LSP client `name` attached to `bufnr` (default current buffer).
function H.wait_lsp(name, bufnr, timeout_ms)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return H.wait_for(function()
    return H.clients(bufnr, name)[1]
  end, timeout_ms or 60000, "LSP client " .. name)
end

--- Diagnostics of a buffer, optionally only those of `source`
--- (vim.diagnostic `source` field, e.g. "rustc", "rust-analyzer", "clippy").
function H.diagnostics(source, bufnr)
  local out = {}
  for _, d in ipairs(vim.diagnostic.get(bufnr or 0)) do
    if not source or d.source == source or (d.source or ""):find(source, 1, true) then
      out[#out + 1] = d
    end
  end
  return out
end

-- ------------------------------------------------------------------- editor

--- Type keys as if typed (mappings apply). Processes them before returning.
function H.feed(keys, mode)
  local k = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(k, mode or "x", false)
end

--- :edit a file. Returns the buffer number.
function H.open(path)
  vim.cmd.edit(vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

--- Text of :messages.
function H.messages()
  return vim.api.nvim_exec2("messages", { output = true }).output
end

function H.clear_messages()
  vim.cmd("messages clear")
end

--- Replace vim.notify; returns { list = {{msg, level}...}, restore = fn }.
function H.capture_notify()
  local orig = vim.notify
  local cap = { list = {} }
  vim.notify = function(msg, level)
    cap.list[#cap.list + 1] = { msg = msg, level = level }
  end
  cap.restore = function()
    vim.notify = orig
  end
  H._restore[#H._restore + 1] = cap.restore
  return cap
end

--- Start a real rust-analyzer for `buf` rooted at `root` (what rustaceanvim or
--- nvim-lspconfig would do in a full setup). Returns the client.
function H.start_ra(buf, root, cargo)
  H.need_rust()
  local id = vim.lsp.start({
    name = "rust-analyzer",
    cmd = { "rust-analyzer" },
    root_dir = root,
    settings = { ["rust-analyzer"] = { cargo = cargo or { allFeatures = true, targetDir = true } } },
  }, { bufnr = buf })
  return H.wait_for(function()
    local c = id and vim.lsp.get_client_by_id(id)
    return c and c.initialized and c
  end, 60000, "rust-analyzer to initialize")
end

--- A stand-in for snacks.nvim as a global `Snacks` with `picker` and
--- `terminal`, so the pickers can be driven without the plugin. Restored by cleanup().
function H.fake_snacks()
  local orig = rawget(_G, "Snacks")
  local terms = {}
  _G.Snacks = {
    picker = function() end,
    terminal = {
      get = function()
        return nil
      end,
      open = function(cmd, opts)
        local t = { cmd = cmd, opts = opts }
        terms[#terms + 1] = t
        return t
      end,
    },
  }
  H._restore[#H._restore + 1] = function()
    _G.Snacks = orig
  end
  return terms
end

-- ----------------------------------------------------------------- tool probes

--- Both rust-analyzer (a real one, not rustup's proxy stub) and cargo work.
function H.rust_available()
  if vim.env.XYNO_TEST_SKIP_RUST == "1" then
    return false, "XYNO_TEST_SKIP_RUST=1"
  end
  if vim.fn.executable("cargo") ~= 1 then
    return false, "cargo not found"
  end
  if vim.fn.executable("rust-analyzer") ~= 1 then
    return false, "rust-analyzer not found"
  end
  if vim.system({ "rust-analyzer", "--version" }):wait(10000).code ~= 0 then
    return false, "rust-analyzer is only a rustup proxy (rustup component add rust-analyzer)"
  end
  return true
end

--- "linux", "macos" or "windows".
H.os = vim.fn.has("win32") == 1 and "windows" or vim.fn.has("mac") == 1 and "macos" or "linux"
H.is_win = H.os == "windows"

--- Skip the test (or, at load time, the file) unless this platform is in `list`.
function H.need_os(list, reason)
  if not vim.tbl_contains(list, H.os) then
    harness.skip(("needs %s, this is %s: %s"):format(table.concat(list, " or "), H.os, reason))
  end
end

--- Skip the test on the platforms in `list`: a failure seen in a CI run that is
--- not diagnosed or fixed yet. Always names the reason.
function H.known_issue(list, reason)
  if vim.tbl_contains(list, H.os) then
    harness.skip(("known issue on %s: %s"):format(H.os, reason))
  end
end

--- Skip on Windows (shell scripts, chmod bits, signals, symlinks without privileges).
function H.need_posix(reason)
  H.need_os({ "linux", "macos" }, reason)
end

function H.skip_file(reason)
  harness.skip(reason)
end

local function need(probe)
  local ok, why = probe()
  if not ok then
    harness.skip(why)
  end
end
function H.need_rust()
  need(H.rust_available)
end

--- Skip the test unless the tree-sitter parser for `lang` is installed
--- (language.add() does not raise for a missing parser, it returns nil + a message).
function H.need_parser(lang)
  local ok, res = pcall(vim.treesitter.language.add, lang)
  if not (ok and res == true) then
    harness.skip("tree-sitter " .. lang .. " parser not installed")
  end
end
-- -------------------------------------------------------------- temp + cleanup

H._dirs, H._jobs, H._restore = {}, {}, {}

--- A fresh empty directory, removed by cleanup().
function H.tmpdir()
  local base = vim.env.XYNO_TEST_TMP
  if not base or base == "" then
    base = vim.fs.dirname(vim.fn.tempname())
  end
  local dir = assert(vim.uv.fs_mkdtemp(base .. "/spec-XXXXXX"))
  H._dirs[#H._dirs + 1] = dir
  if H.os ~= "linux" then
    -- one spelling of the path: macOS /var is /private/var (cargo prints the
    -- latter), Windows has short 8.3 names and backslashes
    dir = vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
  end
  return dir
end

local function run(cmd, opts)
  local r = vim.system(cmd, vim.tbl_extend("force", { text = true }, opts or {})):wait(60000)
  return r
end

--- Run git in `dir` with a fixed identity; returns trimmed stdout, raises on failure.
function H.git(dir, ...)
  local cmd = { "git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ... }
  local r = run(cmd, { cwd = dir })
  if r.code ~= 0 then
    error(("git %s failed (%d): %s"):format(table.concat({ ... }, " "), r.code, r.stderr), 2)
  end
  return vim.trim(r.stdout)
end

--- git init + one commit of everything in `dir`.
function H.git_init(dir)
  H.git(dir, "init", "-q", "-b", "main")
  H.git(dir, "add", "-A")
  H.git(dir, "commit", "-q", "-m", "init")
  return dir
end

--- Recursive copy of a file or directory (modes kept by libuv, symlinks recreated).
function H.copy_tree(src, dest)
  local st = assert(vim.uv.fs_lstat(src))
  if st.type == "directory" then
    vim.fn.mkdir(dest, "p")
    for name in vim.fs.dir(src) do
      H.copy_tree(src .. "/" .. name, dest .. "/" .. name)
    end
  elseif st.type == "link" then
    assert(vim.uv.fs_symlink(assert(vim.uv.fs_readlink(src)), dest))
  else
    assert(vim.uv.fs_copyfile(src, dest))
  end
end

--- Copy tests/fixtures/<name> (a crate directory or a single .rs file) into a
--- fresh temp dir. Returns the path of the copy (directory, or file path).
--- opts.git = true makes the crate a git repository with one commit.
function H.fixture(name, opts)
  opts = opts or {}
  local src = H.fixtures .. "/" .. name
  local dir = H.tmpdir()
  if H.os == "linux" then
    local r = run({ "cp", "-a", "--no-preserve=ownership", src, dir .. "/" })
    assert(r.code == 0, "copying fixture " .. name .. ": " .. (r.stderr or ""))
  else
    H.copy_tree(src, dir .. "/" .. name) -- BSD cp lacks --no-preserve, Windows has no cp
  end
  local dest = dir .. "/" .. name
  if opts.git then
    H.git_init(vim.fn.isdirectory(dest) == 1 and dest or dir)
  end
  return dest
end

--- Copy a fixture, cd into the crate, open `rel` (default src/main.rs or the
--- file itself). Returns dir, bufnr.
function H.open_fixture(name, rel, opts)
  local dest = H.fixture(name, opts)
  if vim.fn.isdirectory(dest) == 1 then
    vim.cmd.cd(vim.fn.fnameescape(dest))
    return dest, H.open(dest .. "/" .. (rel or "src/main.rs"))
  end
  vim.cmd.cd(vim.fn.fnameescape(vim.fs.dirname(dest)))
  return vim.fs.dirname(dest), H.open(dest)
end

--- Start a background process (killed by cleanup). Returns the vim.SystemObj.
function H.spawn(cmd, opts)
  local obj = vim.system(cmd, opts or {})
  H._jobs[#H._jobs + 1] = obj
  return obj
end

--- Stop LSP clients, close buffers, kill jobs, delete temp dirs.
function H.cleanup()
  for _, fn in ipairs(H._restore) do
    pcall(fn)
  end
  H._restore = {}
  -- drop the buffers (without autocmds) before anything waits for the clients
  pcall(function()
    vim.cmd("noautocmd silent! %bwipeout!")
  end)
  pcall(function()
    for _, c in ipairs(vim.lsp.get_clients()) do
      c:stop(true)
    end
    vim.wait(2000, function()
      return #vim.lsp.get_clients() == 0
    end, 20)
  end)
  for _, j in ipairs(H._jobs) do
    pcall(function()
      j:kill(15)
      j:wait(2000)
    end)
  end
  H._jobs = {}
  pcall(vim.cmd, "silent! %bwipeout!")
  pcall(vim.cmd, "cd " .. vim.fn.fnameescape(vim.env.HOME or "/"))
  for _, d in ipairs(H._dirs) do
    vim.fn.delete(d, "rf")
  end
  H._dirs = {}
end

return H
