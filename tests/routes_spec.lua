-- :RustRoutes scanner on the sql_and_routes.rs fixture (treesitter, no LSP).
local H = require("xyno_rust_test.helpers")

describe("rust_routes.scan_source", function()
  before_each(function()
    H.need_parser("rust")
  end)

  it("finds axum .route() calls and actix attribute routes", function()
    local f = assert(io.open(H.fixtures .. "/sql_and_routes.rs"))
    local src = f:read("*a")
    f:close()
    local paths = {}
    for _, r in ipairs(require("xyno_rust.rust_routes").scan_source(src)) do
      paths[#paths + 1] = r.path
    end
    table.sort(paths)
    H.eq({ "/health", "/health", "/users/:id" }, paths)
  end)
end)
