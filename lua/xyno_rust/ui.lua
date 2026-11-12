-- Highlight groups of the pickers this plugin fills (routes). Each is linked to a theme group with
-- `default = true`, so a colorscheme or the user's config can define it instead; the links are
-- restored after `:colorscheme`. The pickers themselves are snacks.nvim's and follow its groups.
local M = {}

M.groups = {
  XynoRustRouteKind = "Keyword", -- GET / POST / ... column of :RustRoutes
  XynoRustRoutePath = "String", -- the route path
  XynoRustRouteDetail = "Function", -- handler / detail
  XynoRustRouteFile = "Comment", -- file of the route
}

function M.define()
  for name, target in pairs(M.groups) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

function M.setup()
  M.define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("xyno_rust_ui", { clear = true }),
    callback = M.define,
  })
end

return M
