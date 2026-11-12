-- Generate a synthetic cargo workspace for the benchmark:
--   nvim -l bench/gen.lua <dir> <members> <files-per-member> [routes-per-file]
-- Every file looks like an axum router module (routes plus filler), so the route scan has real work.
local dir, members, files, routes = arg[1], tonumber(arg[2]), tonumber(arg[3]), tonumber(arg[4]) or 6
assert(dir and members and files, "usage: nvim -l bench/gen.lua <dir> <members> <files-per-member> [routes-per-file]")
local function write(path, text)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end
local list = {}
for m = 1, members do
  list[#list + 1] = ('"crates/m%d"'):format(m)
  write(("%s/crates/m%d/Cargo.toml"):format(dir, m), ('[package]\nname = "m%d"\nversion = "0.1.0"\nedition = "2021"\n\n[features]\ndefault = []\nf%d = []\n'):format(m, m))
  local mods = {}
  for i = 1, files do
    mods[#mods + 1] = ("pub mod r%d;"):format(i)
    local body = { "use axum::{routing::{get, post}, Router};", "", "pub fn router() -> Router {", "    Router::new()" }
    for r = 1, routes do
      body[#body + 1] = ('        .route("/api/v1/m%d/r%d/item%d/{id}", get(h%d).post(p%d))'):format(m, i, r, r, r)
    end
    body[#body + 1] = "}"
    for k = 1, 120 do
      body[#body + 1] = ("// filler %d: handlers elided, this line only gives the parser something to read"):format(k)
    end
    write(("%s/crates/m%d/src/r%d.rs"):format(dir, m, i), table.concat(body, "\n") .. "\n")
  end
  write(("%s/crates/m%d/src/lib.rs"):format(dir, m), table.concat(mods, "\n") .. "\n")
end
write(dir .. "/Cargo.toml", "[workspace]\nresolver = \"2\"\nmembers = [" .. table.concat(list, ", ") .. "]\n")
print(("generated %d members x %d files = %d .rs files in %s"):format(members, files, members * files + members, dir))
