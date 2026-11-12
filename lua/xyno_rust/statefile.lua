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

M.lock_tries = 400 -- x 5 ms: how long a writer waits for the lock before it writes anyway
M.stale_after = 5 -- seconds: an older lock is a dead owner's

local seq = 0
local function new_token()
  seq = seq + 1
  return ("%d.%d.%d.%d"):format(vim.uv.os_getpid(), seq, vim.uv.hrtime() % 1e9, math.random(1, 1e9))
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  return s
end

--- Remove a lock that looks stale. Waiters used to stat, then unlink: between the two another waiter could
--- have deleted the stale lock and created its own, and the first waiter then deleted THAT live lock. Now:
--- one reaper at a time (an O_EXCL guard file), the staleness and the owner token are checked again under
--- the guard, and the lock is moved aside (atomic) and compared with the token before it is dropped; a live
--- lock that was moved by mistake goes back.
local function reap(lock, seen_token)
  local guard = lock .. ".reap"
  local gfd = vim.uv.fs_open(guard, "wx", 420)
  if not gfd then
    local gst = vim.uv.fs_stat(guard)
    if gst and os.time() - gst.mtime.sec > M.stale_after * 2 then
      vim.uv.fs_unlink(guard) -- a reaper that died
    end
    return
  end
  vim.uv.fs_close(gfd)
  local st = vim.uv.fs_stat(lock)
  if st and os.time() - st.mtime.sec > M.stale_after and read_all(lock) == seen_token then
    local dead = lock .. ".dead." .. new_token()
    if vim.uv.fs_rename(lock, dead) then
      if read_all(dead) == seen_token then
        vim.uv.fs_unlink(dead)
      elseif not vim.uv.fs_link(dead, lock) then
        vim.uv.fs_unlink(dead) -- somebody already took the lock again: theirs stands
      else
        vim.uv.fs_unlink(dead)
      end
    end
  end
  vim.uv.fs_unlink(guard)
end

--- Read, let `fn(all)` change the table, write - under a lock file (it holds its owner's token). A lock
--- older than 5 s is a dead owner's; after ~2 s without it the write goes on anyway.
function M.update(file, fn)
  local lock = file .. ".lock"
  -- (mkdir "p" raises E739 when another nvim creates the dir between its stat and mkdir)
  pcall(vim.fn.mkdir, vim.fs.dirname(file), "p")
  local fd
  local token = new_token()
  for _ = 1, M.lock_tries do
    fd = vim.uv.fs_open(lock, "wx", 420)
    if fd then
      vim.uv.fs_write(fd, token)
      break
    end
    local st = vim.uv.fs_stat(lock)
    if st and os.time() - st.mtime.sec > M.stale_after then
      local seen = read_all(lock)
      if seen then
        reap(lock, seen)
      end
      if vim.uv.fs_stat(lock) then
        vim.uv.sleep(5) -- still there (a live lock the stat was too old for): do not spin
      end
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
    if read_all(lock) == token then -- only our own lock: after a reap it may be somebody else's now
      vim.uv.fs_unlink(lock)
    end
  end
  if not ok then
    error(err, 0)
  end
end

return M
