-- The contract constant dependents check, and :checkhealth xyno-rust.
local H = require("xyno_rust_test.helpers")
local x = require("xyno_rust")

describe("api_version", function()
  it("is a 'major.minor' string next to the plugin version", function()
    H.match(x.api_version, "^%d+%.%d+$")
    H.match(x.version, "^%d+%.%d+%.%d+$")
  end)

  it("compatible() accepts the same major with a minor not above ours", function()
    local maj, min = x.api_version:match("^(%d+)%.(%d+)$")
    H.eq(true, (x.compatible(maj .. "." .. min)))
    H.eq(true, (x.compatible(maj .. ".0")))
  end)

  it("compatible() says why when the major differs, the minor is newer, or the request is garbage", function()
    local maj, min = x.api_version:match("^(%d+)%.(%d+)$")
    local ok, why = x.compatible((tonumber(maj) + 1) .. ".0")
    H.eq(false, ok)
    H.match(why, "another major", true)
    ok, why = x.compatible(maj .. "." .. (tonumber(min) + 1))
    H.eq(false, ok)
    H.match(why, "update xyno-rust.nvim", true)
    ok, why = x.compatible("banana")
    H.eq(false, ok)
    H.match(why, "unreadable", true)
    H.eq(false, (x.compatible(nil)))
  end)

  it("every function the dependents call still exists (xyno-new, xyno-imports, xyno-crates, xyno-macros)", function()
    local calls = {
      ["xyno_rust.rust_context"] = { "root", "canon", "get", "cargo_flags" },
      ["xyno_rust.fsutil"] = { "rename", "slash" },
      ["xyno_rust.crate_meta"] = {
        "metadata",
        "metadata_async",
        "root",
        "exec",
        "member_of",
        "dependencies",
        "registry_dir",
      },
      ["xyno_rust.code_actions"] = { "clients" },
      ["xyno_rust.rust_restart"] = { "manifest_saved", "on_exit", "server_pids", "kill_survivors" },
      ["xyno_rust.deps"] = { "snacks" },
      ["xyno_rust.lsp_status"] = { "component" },
      ["xyno_rust.rust_tasks"] = { "doctests" },
      ["xyno_rust.rust_nav"] = { "goto_super", "local_usages" },
    }
    for mod, fns in pairs(calls) do
      local m = require(mod)
      for _, f in ipairs(fns) do
        H.eq("function", type(m[f]), mod .. "." .. f)
      end
    end
  end)

  it("rust_context.root keeps its synchronous contract: a string for a path in a crate, nil outside", function()
    H.need_rust()
    local dir = H.fixture("basic")
    H.eq(dir, require("xyno_rust.rust_context").root(dir .. "/src/lib.rs"))
    H.is_nil(require("xyno_rust.rust_context").root(H.tmpdir() .. "/none.rs"))
  end)
end)

describe(":checkhealth xyno-rust", function()
  it("runs, names every section, and reports the api version", function()
    vim.opt.rtp:prepend(H.repo)
    local dir = H.fixture("basic")
    vim.cmd.cd(vim.fn.fnameescape(dir))
    vim.cmd("checkhealth xyno-rust")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    for _, section in ipairs({
      "xyno-rust: plugin",
      "xyno-rust: tools",
      "xyno-rust: state",
      "xyno-rust: workspace trust",
      "xyno-rust: current workspace",
    }) do
      H.match(text, section, true)
    end
    H.match(text, "api_version " .. x.api_version, true)
    H.no_match(text, "ERROR", true, "no health error on a healthy setup:\n" .. text)
    vim.cmd("silent! %bwipeout!")
  end)

  it("flags invalid stored values and a missing cargo metadata", function()
    local state_file = vim.fn.stdpath("state") .. "/rust-context.json"
    vim.fn.mkdir(vim.fs.dirname(state_file), "p")
    vim.fn.writefile({ vim.json.encode({ ["/x"] = { features = { "--evil" } } }) }, state_file)
    vim.cmd.cd(vim.fn.fnameescape(H.tmpdir()))
    vim.cmd("checkhealth xyno-rust")
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    vim.fn.delete(state_file)
    H.match(text, "invalid values that are ignored: --evil", true)
    vim.cmd("silent! %bwipeout!")
  end)
end)
