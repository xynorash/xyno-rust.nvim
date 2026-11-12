-- Async / tokio debugging help. A debugger (DAP) can not list tokio tasks: tasks are heap objects the
-- runtime schedules, not threads, so gdb / lldb / CodeLLDB show worker threads and the poll frames. The
-- tool for the task list is tokio-console, which talks to the program through the `console-subscriber`
-- crate. This module does what is possible from the editor:
--
--   :TokioConsole         checks the project (tokio, console-subscriber, `--cfg tokio_unstable`, the init
--                         call, the tokio-console binary) and prints what is missing, each with the line
--                         to add; when everything is there it opens tokio-console in a terminal.
--   :TokioConsole check   only the report.
--   M.detect(lines)       the #[tokio::main] / #[tokio::test] attributes of a buffer (a debug session
--                         started in such a file gets a one-time hint, see M.debug_hint).
--
-- Nothing is installed or edited: the report names `cargo install --locked tokio-console` and the
-- Cargo.toml lines, you run them.
local M = {}

M.ATTRS = {
  { pat = "^%s*#%[tokio::main", kind = "main" },
  { pat = "^%s*#%[tokio::test", kind = "test" },
}

--- The tokio entry attributes in a list of lines: { { line = 1-based, kind = "main"|"test" }, ... }
---@param lines string[]
function M.detect(lines)
  local out = {}
  for i, l in ipairs(lines) do
    for _, a in ipairs(M.ATTRS) do
      if l:match(a.pat) then
        out[#out + 1] = { line = i, kind = a.kind }
      end
    end
  end
  return out
end

--- Whether any package of the cargo metadata depends on crate `name`.
local function depends(meta, name)
  for _, p in ipairs(meta and meta.packages or {}) do
    for _, d in ipairs(p.dependencies or {}) do
      if d.name == name then
        return true, p.name
      end
    end
  end
  return false
end

local function read(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local t = fd:read(1 << 20)
  fd:close()
  return t
end

--- Does a cargo config in the workspace (or RUSTFLAGS) pass `--cfg tokio_unstable`?
function M.unstable_cfg(root, env)
  env = env or vim.env
  for _, v in ipairs({ env.RUSTFLAGS or "", env.CARGO_ENCODED_RUSTFLAGS or "", env.CARGO_BUILD_RUSTFLAGS or "" }) do
    if v:find("tokio_unstable", 1, true) then
      return true, "environment"
    end
  end
  for _, f in ipairs({ ".cargo/config.toml", ".cargo/config" }) do
    local t = read(root .. "/" .. f)
    if t and t:find("tokio_unstable", 1, true) then
      return true, f
    end
  end
  return false
end

--- Does any .rs file under src/ (and the workspace members' src/) call console_subscriber::init / ::builder?
function M.init_call(root, meta)
  local dirs = { root .. "/src" }
  for _, p in ipairs(meta and meta.packages or {}) do
    if p.manifest_path then
      dirs[#dirs + 1] = vim.fs.dirname(p.manifest_path) .. "/src"
    end
  end
  local seen = {}
  for _, d in ipairs(dirs) do
    if not seen[d] then
      seen[d] = true
      for name, typ in vim.fs.dir(d, { depth = 4 }) do
        if typ == "file" and name:match("%.rs$") then
          local t = read(d .. "/" .. name)
          if
            t
            and (
              t:find("console_subscriber::init", 1, true)
              or t:find("console_subscriber::ConsoleLayer", 1, true)
              or t:find("console_subscriber::Builder", 1, true)
              or t:find("console_subscriber::spawn", 1, true)
            )
          then
            return true, d .. "/" .. name
          end
        end
      end
    end
  end
  return false
end

--- The checklist. Pure: everything is passed in.
---@param s { meta: table?, unstable: boolean, init: boolean, exe: boolean, attrs: table[] }
---@return { ok: boolean, text: string, fix?: string }[]
function M.checks(s)
  local out = {}
  local has_tokio = depends(s.meta, "tokio")
  out[#out + 1] = {
    ok = has_tokio,
    text = "the project depends on tokio",
    fix = 'tokio = { version = "1", features = ["full", "tracing"] }   # [dependencies]',
  }
  out[#out + 1] = {
    ok = depends(s.meta, "console-subscriber"),
    text = "the project depends on console-subscriber (the program side of tokio-console)",
    fix = 'console-subscriber = "0.4"   # [dependencies], dev-only is fine: cargo add --dev console-subscriber',
  }
  out[#out + 1] = {
    ok = s.init,
    text = "the program calls console_subscriber::init()",
    fix = "fn main() { console_subscriber::init(); ... }   // before the runtime starts tasks",
  }
  out[#out + 1] = {
    ok = s.unstable,
    text = "built with --cfg tokio_unstable (tokio only emits task events then)",
    fix = '.cargo/config.toml:  [build]\\n rustflags = ["--cfg", "tokio_unstable"]   # changes the build, cargo rebuilds everything once',
  }
  out[#out + 1] = {
    ok = s.exe,
    text = "tokio-console is installed",
    fix = "cargo install --locked tokio-console   (not run for you)",
  }
  return out
end

function M.report(checks, attrs)
  local lines = { "tokio-console (the async task list; a debugger can not show tasks):" }
  local all = true
  for _, c in ipairs(checks) do
    lines[#lines + 1] = (c.ok and "  [x] " or "  [ ] ") .. c.text
    if not c.ok then
      all = false
      lines[#lines + 1] = "        " .. c.fix:gsub("\\n", "\n        ")
    end
  end
  if #attrs > 0 then
    lines[#lines + 1] = ("This buffer has %d tokio entry point(s)."):format(#attrs)
  end
  lines[#lines + 1] =
    "Debugger side: async frames are renamed (…::{{closure}} shows its function), but tasks are not threads: breakpoints"
  lines[#lines + 1] = "inside async fns work, stepping across .await continues on whichever worker polls next."
  return table.concat(lines, "\n"), all
end

--- Gather the facts of the project of the current buffer; cb(state).
function M.gather(cb)
  local rc = require("xyno_rust.rust_context")
  rc.root_async(nil, function(root)
    if not root then
      return cb(nil)
    end
    require("xyno_rust.cargo").metadata_async(root, function(meta)
      local unstable = M.unstable_cfg(root)
      local init = M.init_call(root, meta)
      cb({
        root = root,
        meta = meta,
        unstable = unstable,
        init = init,
        exe = vim.fn.executable("tokio-console") == 1,
        attrs = M.detect(vim.api.nvim_buf_get_lines(0, 0, -1, false)),
      })
    end)
  end)
end

--- Launch tokio-console in a terminal; `url` defaults to its own default (http://127.0.0.1:6669).
function M.launch(url)
  local Snacks = require("xyno_rust.deps").snacks()
  if not Snacks then
    return
  end
  local argv = { "tokio-console" }
  if url and url ~= "" then
    argv[#argv + 1] = url
  end
  return Snacks.terminal.open(argv, { auto_close = false, win = { position = "bottom" } })
end
M._launch = M.launch

function M.command(args)
  local a = vim.trim(args or "")
  M.gather(function(st)
    if not st then
      return vim.notify("xyno-rust: no Cargo.toml found", vim.log.levels.WARN)
    end
    local checks = M.checks(st)
    local text, all = M.report(checks, st.attrs)
    if a == "check" or not all then
      return vim.notify(text, all and vim.log.levels.INFO or vim.log.levels.WARN)
    end
    M._launch(a ~= "" and a or nil)
  end)
end

--- Once per session and root: a debug session in a file with #[tokio::main] / #[tokio::test] while the
--- project is not set up for tokio-console gets one line pointing at :TokioConsole. Returns whether it spoke.
local told = {}
function M.debug_hint(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local attrs = M.detect(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  if #attrs == 0 then
    return false
  end
  local file = vim.api.nvim_buf_get_name(buf)
  local root = require("xyno_rust.rust_context").root(file, { nowait = true })
  if not root or told[root] then
    return false
  end
  told[root] = true
  vim.notify(
    "xyno-rust: async code: a debugger shows threads, not tokio tasks. :TokioConsole lists the tasks (and says what to add to the project).",
    vim.log.levels.INFO
  )
  return true
end

function M._reset_hints()
  told = {}
end

function M.setup(opts)
  if opts and opts.commands == false then
    return
  end
  vim.api.nvim_create_user_command("TokioConsole", function(a)
    M.command(a.args)
  end, {
    nargs = "?",
    complete = function()
      return { "check" }
    end,
    desc = "tokio-console: project check, then launch",
  })
end

return M
