-- The statusline says "RA missing" for a Rust buffer when there is no rust-analyzer binary to start.
-- xyno-os: linux,macos (PATH lookup)
local H = require("xyno_rust_test.helpers")
local status = require("xyno_rust.lsp_status")

describe("RA missing", function()
  it("is shown for a rust buffer without client or binary, and not for other filetypes", function()
    local old = vim.env.PATH
    vim.env.PATH = H.tmpdir() -- an empty directory: no rust-analyzer
    local ok, err = pcall(function()
      local rs = vim.api.nvim_create_buf(false, true)
      vim.bo[rs].filetype = "rust"
      H.eq("RA missing", status.rust_analyzer(rs))
      local lua = vim.api.nvim_create_buf(false, true)
      vim.bo[lua].filetype = "lua"
      H.eq(nil, status.rust_analyzer(lua))
    end)
    vim.env.PATH = old
    assert(ok, err)
  end)
end)
