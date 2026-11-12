-- :checkhealth xyno-rust (the directory is named after the plugin so that name works; the checks
-- live in xyno_rust.healthcheck).
return {
  check = function()
    require("xyno_rust.healthcheck").check()
  end,
}
