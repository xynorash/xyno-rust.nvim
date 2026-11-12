-- State-file validation (no option injection through the stored context), the profiling items'
-- binary path under a stored --target, and the shared cargo_metadata definition.
local H = require("xyno_rust_test.helpers")
H.fake_snacks()
require("xyno_rust").setup()
local rc = require("xyno_rust.rust_context")
local tasks = require("xyno_rust.rust_tasks")

local state_file = vim.fn.stdpath("state") .. "/rust-context.json"
local function write_state(tbl)
  vim.fn.mkdir(vim.fs.dirname(state_file), "p")
  local f = assert(io.open(state_file, "w"))
  f:write(vim.json.encode(tbl))
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
before_each(function()
  vim.fn.delete(state_file)
  require("xyno_rust.cargo").reset_caches()
end)
after_each(function()
  for i = #restores, 1, -1 do
    pcall(restores[i])
  end
  restores = {}
  vim.fn.delete(state_file)
end)

--- No element of `argv` (other than the flag names this module adds itself) may start with "-".
local function option_like_values(argv)
  local bad = {}
  local own = { ["--all-features"] = true, ["--no-default-features"] = true, ["--features"] = true, ["--target"] = true, ["--workspace"] = true, ["--no-deps"] = true, ["--keep-going"] = true }
  for _, a in ipairs(argv) do
    if a:sub(1, 1) == "-" and not own[a] then
      bad[#bad + 1] = a
    end
  end
  return bad
end

describe("state-file flag validation", function()
  local evil_features = {
    "--config=build.rustc-wrapper=\"/tmp/x\"",
    "-Zunstable-options",
    "a,--manifest-path=/etc/passwd",
    "has space",
    "semi;colon",
    "$(touch /tmp/x)",
    "",
    "ok_feature",
    "dep:serde",
    "pkg/feat",
    "pkg?/feat",
    "with-dash.and+plus",
  }

  it("rejects feature names that cargo would read as options (or that split in two) and keeps the valid ones", function()
    local root = H.tmpdir()
    vim.fn.writefile({ "[package]", 'name = "x"' }, root .. "/Cargo.toml")
    write_state({ [root] = { all = false, features = evil_features } })
    local n = H.capture_notify()
    local ctx = rc.get(root)
    H.eq({ "ok_feature", "dep:serde", "pkg/feat", "pkg?/feat", "with-dash.and+plus" }, ctx.features)
    H.eq({}, option_like_values(rc.cargo_flags(ctx)))
    vim.wait(100, function()
      return #n.list > 0
    end, 10)
    H.eq(1, #n.list, "one warning, not one per read")
    H.eq(vim.log.levels.WARN, n.list[1].level)
    H.match(n.list[1].msg, "ignored invalid feature/target", true)
    rc.get(root)
    vim.wait(50, function()
      return false
    end, 10)
    H.eq(1, #n.list, "and not again for the same root")
  end)

  it("rejects targets that are options, paths or shell syntax; accepts real triples", function()
    for _, bad in ipairs({ "--config=x", "-Zfoo", "a b", "x;y", "../../evil", "$(x)", "t\nu" }) do
      local ctx = rc.sanitize({ all = true, target = bad })
      H.is_nil(ctx.target, bad)
      H.eq({ "--all-features" }, rc.cargo_flags({ all = true, target = bad }))
    end
    for _, good in ipairs({ "x86_64-unknown-linux-gnu", "wasm32-unknown-unknown", "thumbv7em-none-eabihf", "aarch64-apple-darwin", "x86_64-pc-windows-msvc", "riscv64gc-unknown-linux-gnu" }) do
      H.eq(good, rc.sanitize({ target = good }).target)
      H.eq({ "--all-features", "--target", good }, rc.cargo_flags({ all = true, target = good }))
    end
  end)

  it("also holds for contexts that are not read from the file: cargo_flags, ra_cargo, bacon_args", function()
    local ctx = { all = false, features = { "--evil", "good" }, target = "-Zx" }
    H.eq({ "--features", "good" }, rc.cargo_flags(ctx))
    H.eq({ "good" }, rc.ra_cargo(ctx).features)
    H.is_nil(rc.ra_cargo(ctx).target)
    H.eq({}, option_like_values(rc.bacon_args(ctx)))
  end)

  it("apply() stores only the sanitized context", function()
    local root = H.tmpdir()
    vim.fn.writefile({ "[package]", 'name = "x"' }, root .. "/Cargo.toml")
    stub(vim, "notify", function() end)
    rc.apply(root, { all = false, features = { "--evil", "good" }, target = "--t" })
    local stored = vim.json.decode(table.concat(vim.fn.readfile(state_file), "\n"))
    H.eq({ "good" }, stored[rc.canon(root)].features)
    H.is_nil(stored[rc.canon(root)].target)
  end)

  it("health reports invalid stored values", function()
    write_state({ ["/some/root"] = { features = { "--evil", "good" }, target = "-Zx" } })
    H.eq({ "--evil", "-Zx" }, rc.rejected(rc.stored()["/some/root"]))
  end)
end)

describe("profiling items honour the stored --target", function()
  local meta = {
    target_directory = "/w/target",
    packages = { { name = "app", features = {}, targets = { { name = "tool", kind = { "bin" } } } } },
  }
  local function samply_for(ctx)
    stub(rc, "get", function()
      return ctx
    end)
    for _, it in ipairs(tasks.target_items("/w", meta)) do
      if it.text:find("^samply") then
        return it
      end
    end
  end

  it("without a target the binary is target/profiling/<bin>", function()
    H.need_posix("sh -c line")
    local it = samply_for(nil)
    H.has(it.cmd[3], vim.fn.shellescape("/w/target/profiling/tool"))
  end)

  it("with --target T cargo builds into target/T/profiling and samply records that binary", function()
    H.need_posix("sh -c line")
    local it = samply_for({ all = true, target = "x86_64-unknown-linux-gnu" })
    H.has(it.cmd[3], "'--target' 'x86_64-unknown-linux-gnu'")
    H.has(it.cmd[3], " && samply record " .. vim.fn.shellescape("/w/target/x86_64-unknown-linux-gnu/profiling/tool"))
    H.no_match(it.cmd[3], vim.fn.shellescape("/w/target/profiling/tool"), true)
  end)

  it("a windows target gets the .exe suffix, a wasm target gets no samply item (it cannot run there)", function()
    H.need_posix("sh -c line")
    local win = samply_for({ all = true, target = "x86_64-pc-windows-msvc" })
    H.has(win.cmd[3], "/x86_64-pc-windows-msvc/profiling/tool.exe")
    H.is_nil(samply_for({ all = true, target = "wasm32-unknown-unknown" }))
  end)
end)

describe("one cargo metadata definition", function()
  it("rust_context and rust_tasks no longer define their own (they use cargo.lua)", function()
    for _, f in ipairs({ "rust_context", "rust_tasks" }) do
      local src = table.concat(vim.fn.readfile(H.repo .. "/lua/xyno_rust/" .. f .. ".lua"), "\n")
      H.no_match(src, "local function cargo_metadata", true, f)
      H.no_match(src, ":wait(", true, f .. " still blocks on a process")
    end
  end)

  it("no module of the plugin waits on a process on the main thread, except the documented sync wrappers", function()
    local allowed = { ["cargo.lua"] = true, ["crate_meta.lua"] = true, ["fsutil.lua"] = true }
    local offenders = {}
    for _, path in ipairs(vim.fn.glob(H.repo .. "/lua/xyno_rust/*.lua", true, true)) do
      local name = vim.fs.basename(path)
      if not allowed[name] and name ~= "healthcheck.lua" then
        local src = table.concat(vim.fn.readfile(path), "\n")
        if src:find(":wait(", 1, true) or src:find("vim.fn.system", 1, true) then
          offenders[#offenders + 1] = name
        end
      end
    end
    H.eq({}, offenders)
  end)
end)
