-- ============================================================
-- base64.lua  –  Standard RFC 4648 Base64 encode / decode
-- No external dependencies.
-- Returns a module table with base64.encode(str) and base64.decode(str)
-- ============================================================

local M = {}

local CHARS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

-- Build decode lookup table
local DECODE = {}
for i = 1, #CHARS do
  DECODE[CHARS:sub(i, i)] = i - 1
end
DECODE['='] = 0

function M.encode(data)
  local result = {}
  local len = #data
  local i = 1
  while i <= len do
    local b1 = data:byte(i)       or 0
    local b2 = data:byte(i + 1)   or 0
    local b3 = data:byte(i + 2)   or 0

    local n = b1 * 65536 + b2 * 256 + b3

    local c1 = CHARS:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
    local c2 = CHARS:sub(math.floor((n % 262144) / 4096) + 1, math.floor((n % 262144) / 4096) + 1)
    local c3 = CHARS:sub(math.floor((n % 4096) / 64) + 1, math.floor((n % 4096) / 64) + 1)
    local c4 = CHARS:sub((n % 64) + 1, (n % 64) + 1)

    if len - i < 2 then c4 = '=' end
    if len - i < 1 then c3 = '=' end

    result[#result + 1] = c1 .. c2 .. c3 .. c4
    i = i + 3
  end
  return table.concat(result)
end

function M.decode(data)
  -- Remove whitespace and newlines that may appear in multi-line base64
  data = data:gsub('[%s\n\r]', '')
  local result = {}
  local len = #data
  local i = 1
  while i <= len - 3 do
    local n1 = DECODE[data:sub(i,   i  )] or 0
    local n2 = DECODE[data:sub(i+1, i+1)] or 0
    local n3 = DECODE[data:sub(i+2, i+2)] or 0
    local n4 = DECODE[data:sub(i+3, i+3)] or 0

    local n = n1 * 262144 + n2 * 4096 + n3 * 64 + n4

    result[#result + 1] = string.char(math.floor(n / 65536))

    if data:sub(i+2, i+2) ~= '=' then
      result[#result + 1] = string.char(math.floor((n % 65536) / 256))
    end
    if data:sub(i+3, i+3) ~= '=' then
      result[#result + 1] = string.char(n % 256)
    end

    i = i + 4
  end
  return table.concat(result)
end

return M
