-- Small JSON state files under stdpath("state"): { [key] = value } tables that
-- several nvim instances share. Reads tolerate a missing or hand-broken file;
-- writes go through a lock file and an atomic rename, so two nvims updating
-- different keys at once do not drop each other's change.
local M = {}

--- The decoded table of `file`, {} when it is missing or not a JSON object/array.
function M.read(file)
  local f = io.open(file)
  if not f then
    return {}
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(data) == "table" and data or {}
end

--- Write aside and rename: a reader (another nvim) never sees a truncated file.
function M.write(file, data)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  local tmp = ("%s.%d.tmp"):format(file, vim.uv.os_getpid())
  local f = assert(io.open(tmp, "w"))
  f:write(vim.json.encode(data))
  f:close()
  assert(require("xyno_rust.fsutil").rename(tmp, file))
end

--- Read, let `fn(all)` change the table, write - under a lock file. A lock older than 5 s is
--- a dead owner's; after ~2 s without it the write goes on anyway.
function M.update(file, fn)
  local lock = file .. ".lock"
  -- (mkdir "p" raises E739 when another nvim creates the dir between its stat and mkdir)
  pcall(vim.fn.mkdir, vim.fs.dirname(file), "p")
  local fd
  for _ = 1, 400 do
    fd = vim.uv.fs_open(lock, "wx", 420)
    if fd then
      break
    end
    local st = vim.uv.fs_stat(lock)
    if st and os.time() - st.mtime.sec > 5 then
      vim.uv.fs_unlink(lock)
    else
      vim.uv.sleep(5)
    end
  end
  local ok, err = pcall(function()
    local all = M.read(file)
    fn(all)
    M.write(file, all)
  end)
  if fd then
    vim.uv.fs_close(fd)
    vim.uv.fs_unlink(lock)
  end
  if not ok then
    error(err, 0)
  end
end

return M
