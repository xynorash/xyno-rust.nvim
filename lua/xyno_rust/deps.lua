-- Optional plugins the pickers and terminals lean on. Nothing here raises: a
-- missing plugin is one line in the notification area.
local M = {}

--- The snacks.nvim table (picker, terminal), or nil after a one-line error.
function M.snacks()
  local s = rawget(_G, "Snacks")
  if type(s) ~= "table" then
    local ok, mod = pcall(require, "snacks")
    s = ok and type(mod) == "table" and mod or nil
  end
  if s and s.picker then
    return s
  end
  vim.notify("xyno-rust: snacks.nvim is required for pickers and terminals (folke/snacks.nvim)", vim.log.levels.ERROR)
  return nil
end

return M
