-- A small TOML reader for the files a repository may ship for this plugin (.xynovim/run.toml). It reads
-- the subset those files need and REJECTS everything else with a line number, instead of guessing:
--   # comments, [table], [a.b], [[array_of_tables]], key = value with
--   "basic strings" (\" \\ \n \t \r escapes), 'literal strings', true / false, integers,
--   arrays of those (may span lines), inline tables { k = v, ... } of those.
-- No dates, floats, multi-line strings, dotted keys. Input is capped at 64 KiB. Nothing is evaluated.
local M = {}

M.MAX_BYTES = 65536

local function perr(line, msg)
  return nil, ("line %d: %s"):format(line, msg)
end

local ESC = { ['"'] = '"', ["\\"] = "\\", n = "\n", t = "\t", r = "\r" }

--- Parse one value at s[i]; returns value, next index (or nil, message).
local function value(s, i, line)
  local c = s:sub(i, i)
  if c == '"' then
    local out, j = {}, i + 1
    while true do
      local ch = s:sub(j, j)
      if ch == "" or ch == "\n" then
        return nil, "unterminated string"
      elseif ch == '"' then
        return table.concat(out), j + 1
      elseif ch == "\\" then
        local e = ESC[s:sub(j + 1, j + 1)]
        if not e then
          return nil, "unsupported escape \\" .. s:sub(j + 1, j + 1)
        end
        out[#out + 1] = e
        j = j + 2
      else
        out[#out + 1] = ch
        j = j + 1
      end
    end
  elseif c == "'" then
    local e = s:find("'", i + 1, true)
    local nl = s:find("\n", i + 1, true)
    if not e or (nl and nl < e) then
      return nil, "unterminated string"
    end
    return s:sub(i + 1, e - 1), e + 1
  elseif c == "[" then
    local arr, j = {}, i + 1
    while true do
      j = s:find("[^%s,]", j) or #s + 1
      -- comments inside a multi-line array
      while s:sub(j, j) == "#" do
        j = (s:find("\n", j, true) or #s) + 1
        j = s:find("[^%s,]", j) or #s + 1
      end
      local ch = s:sub(j, j)
      if ch == "" then
        return nil, "unterminated array"
      elseif ch == "]" then
        return arr, j + 1
      end
      local v, nj = value(s, j, line)
      if v == nil then
        return nil, nj
      end
      arr[#arr + 1] = v
      j = nj
    end
  elseif c == "{" then
    local t, j = {}, i + 1
    while true do
      j = s:find("[^ \t,]", j) or #s + 1
      local ch = s:sub(j, j)
      if ch == "}" then
        return t, j + 1
      end
      local k, e = s:match('^([%w_%-]+)[ \t]*=[ \t]*()', j)
      if not k then
        local qk, qe = s:match('^"([^"\n]*)"[ \t]*=[ \t]*()', j)
        if not qk then
          return nil, "bad inline table"
        end
        k, e = qk, qe
      end
      local v, nj = value(s, e, line)
      if v == nil then
        return nil, nj
      end
      t[k] = v
      j = nj
    end
  end
  local word = s:match("^[%w%-_+.]+", i)
  if word == "true" then
    return true, i + 4
  elseif word == "false" then
    return false, i + 5
  elseif word and word:match("^[+-]?%d+$") then
    return tonumber(word), i + #word
  end
  return nil, "unsupported value"
end

---@param text string
---@return table? doc, string? error
function M.parse(text)
  if #text > M.MAX_BYTES then
    return nil, ("file is larger than %d bytes"):format(M.MAX_BYTES)
  end
  text = text:gsub("\r\n", "\n")
  local doc, cur = {}, nil
  cur = doc
  local i, n, line = 1, #text, 1
  local function nextline(from)
    local e = text:find("\n", from, true)
    return e and e + 1 or n + 1
  end
  local function rest_ok(j)
    local tail = text:match("^[ \t]*#?[^\n]*", j)
    return tail:match("^[ \t]*$") or tail:match("^[ \t]*#")
  end
  while i <= n do
    local ls = text:match("^[ \t]*()", i)
    local ch = text:sub(ls, ls)
    if ch == "" then
      break
    elseif ch == "\n" then
      i, line = ls + 1, line + 1
    elseif ch == "#" then
      i, line = nextline(ls), line + 1
    elseif ch == "[" then
      local arr = text:sub(ls, ls + 1) == "[["
      local name, e = text:match(arr and "^%[%[[ \t]*([%w_%-%.]+)[ \t]*%]%]()" or "^%[[ \t]*([%w_%-%.]+)[ \t]*%]()", ls)
      if not name or not rest_ok(e) then
        return perr(line, "bad table header")
      end
      local node = doc
      local parts = vim.split(name, ".", { plain = true })
      for idx, p in ipairs(parts) do
        local last = idx == #parts
        local nxt = node[p]
        if last and arr then
          if nxt == nil then
            nxt = {}
            node[p] = nxt
          elseif type(nxt) ~= "table" or nxt.__scalar then
            return perr(line, "`" .. name .. "` is defined twice")
          end
          local item = {}
          nxt[#nxt + 1] = item
          node = item
        else
          if nxt == nil then
            nxt = {}
            node[p] = nxt
          elseif type(nxt) ~= "table" then
            return perr(line, "`" .. name .. "` is not a table")
          end
          -- inside an array of tables a sub-table belongs to the last item
          if not last and #nxt > 0 then
            nxt = nxt[#nxt]
          end
          node = nxt
        end
      end
      cur = node
      i, line = nextline(e), line + 1
    else
      local k, e = text:match('^([%w_%-]+)[ \t]*=[ \t]*()', ls)
      if not k then
        return perr(line, "expected `key = value` or a table header")
      end
      local v, nj = value(text, e, line)
      if v == nil then
        return perr(line, nj)
      end
      if cur[k] ~= nil then
        return perr(line, "key `" .. k .. "` is set twice")
      end
      if not rest_ok(nj) then
        return perr(line, "unexpected text after the value")
      end
      cur[k] = v
      -- count the lines a multi-line array consumed
      local _, nl = text:sub(ls, nj - 1):gsub("\n", "")
      line = line + nl
      i, line = nextline(nj), line + 1
    end
  end
  return doc
end

--- Quote a string for TOML output.
function M.quote(s)
  return '"' .. s:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\t", "\\t"):gsub("\r", "\\r") .. '"'
end

return M
