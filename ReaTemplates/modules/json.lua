-- ============================================================
-- json.lua  –  Minimal self-contained JSON encode / decode
-- No external dependencies.
-- Returns a module table with json.encode(value) and json.decode(str)
-- ============================================================

local M = {}

-- ============================================================
-- ENCODE
-- ============================================================

local escape_chars = {
  ['"']  = '\\"',
  ['\\'] = '\\\\',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
}

local function escape_string(s)
  return s:gsub('[\\"/%c]', function(c)
    return escape_chars[c] or string.format('\\u%04X', c:byte())
  end)
end

local function encode_value(val, seen)
  local t = type(val)

  if val == nil then
    return 'null'
  elseif t == 'boolean' then
    return tostring(val)
  elseif t == 'number' then
    if val ~= val then return 'null' end  -- NaN → null
    if val == math.huge or val == -math.huge then return 'null' end
    -- Use integer form when it is a whole number
    if math.type and math.type(val) == 'integer' then
      return tostring(val)
    end
    if val == math.floor(val) and math.abs(val) < 1e15 then
      return string.format('%.0f', val)
    end
    return string.format('%.17g', val)
  elseif t == 'string' then
    return '"' .. escape_string(val) .. '"'
  elseif t == 'table' then
    if seen[val] then
      error('json.encode: circular reference detected')
    end
    seen[val] = true

    -- Determine if array or object
    local is_array = true
    local max_n = 0
    for k, _ in pairs(val) do
      if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
        is_array = false
        break
      end
      if k > max_n then max_n = k end
    end
    if is_array and max_n ~= #val then
      is_array = false
    end

    local parts = {}
    if is_array then
      for i = 1, #val do
        parts[i] = encode_value(val[i], seen)
      end
      seen[val] = nil
      return '[' .. table.concat(parts, ',') .. ']'
    else
      for k, v in pairs(val) do
        if type(k) ~= 'string' and type(k) ~= 'number' then
          -- skip unsupported key types
        else
          local key_str = '"' .. escape_string(tostring(k)) .. '"'
          parts[#parts + 1] = key_str .. ':' .. encode_value(v, seen)
        end
      end
      seen[val] = nil
      return '{' .. table.concat(parts, ',') .. '}'
    end
  else
    -- functions, userdata, threads → null
    return 'null'
  end
end

function M.encode(val)
  return encode_value(val, {})
end

-- ============================================================
-- DECODE
-- ============================================================

local function decode_error(str, pos, msg)
  error(string.format('json.decode: %s at position %d (near %q)', msg, pos, str:sub(pos, pos + 8)))
end

local function skip_whitespace(str, pos)
  return str:match('^%s*()', pos)
end

local decode_value  -- forward declaration

local function decode_string(str, pos)
  -- pos points to the opening "
  local result = {}
  local i = pos + 1
  while i <= #str do
    local c = str:sub(i, i)
    if c == '"' then
      return table.concat(result), i + 1
    elseif c == '\\' then
      local e = str:sub(i + 1, i + 1)
      if e == '"'  then result[#result+1] = '"';  i = i + 2
      elseif e == '\\' then result[#result+1] = '\\'; i = i + 2
      elseif e == '/'  then result[#result+1] = '/';  i = i + 2
      elseif e == 'n'  then result[#result+1] = '\n'; i = i + 2
      elseif e == 'r'  then result[#result+1] = '\r'; i = i + 2
      elseif e == 't'  then result[#result+1] = '\t'; i = i + 2
      elseif e == 'b'  then result[#result+1] = '\b'; i = i + 2
      elseif e == 'f'  then result[#result+1] = '\f'; i = i + 2
      elseif e == 'u'  then
        local hex = str:sub(i + 2, i + 5)
        if #hex < 4 then decode_error(str, i, 'invalid \\uXXXX escape') end
        local code = tonumber(hex, 16)
        if not code then decode_error(str, i, 'invalid hex in \\uXXXX') end
        -- Encode as UTF-8
        if code < 0x80 then
          result[#result+1] = string.char(code)
        elseif code < 0x800 then
          result[#result+1] = string.char(0xC0 | (code >> 6), 0x80 | (code & 0x3F))
        else
          result[#result+1] = string.char(0xE0 | (code >> 12),
                                           0x80 | ((code >> 6) & 0x3F),
                                           0x80 | (code & 0x3F))
        end
        i = i + 6
      else
        decode_error(str, i, 'invalid escape sequence \\' .. e)
      end
    else
      result[#result+1] = c
      i = i + 1
    end
  end
  decode_error(str, pos, 'unterminated string')
end

local function decode_number(str, pos)
  local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
  if not num_str then decode_error(str, pos, 'invalid number') end
  local n = tonumber(num_str)
  if not n then decode_error(str, pos, 'invalid number') end
  return n, pos + #num_str
end

local function decode_array(str, pos)
  local arr = {}
  pos = skip_whitespace(str, pos + 1)  -- skip '['
  if str:sub(pos, pos) == ']' then return arr, pos + 1 end
  while true do
    local val
    val, pos = decode_value(str, pos)
    arr[#arr + 1] = val
    pos = skip_whitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == ']' then return arr, pos + 1 end
    if c ~= ',' then decode_error(str, pos, 'expected , or ]') end
    pos = skip_whitespace(str, pos + 1)
  end
end

local function decode_object(str, pos)
  local obj = {}
  pos = skip_whitespace(str, pos + 1)  -- skip '{'
  if str:sub(pos, pos) == '}' then return obj, pos + 1 end
  while true do
    pos = skip_whitespace(str, pos)
    if str:sub(pos, pos) ~= '"' then decode_error(str, pos, 'expected string key') end
    local key
    key, pos = decode_string(str, pos)
    pos = skip_whitespace(str, pos)
    if str:sub(pos, pos) ~= ':' then decode_error(str, pos, 'expected :') end
    pos = skip_whitespace(str, pos + 1)
    local val
    val, pos = decode_value(str, pos)
    obj[key] = val
    pos = skip_whitespace(str, pos)
    local c = str:sub(pos, pos)
    if c == '}' then return obj, pos + 1 end
    if c ~= ',' then decode_error(str, pos, 'expected , or }') end
    pos = skip_whitespace(str, pos + 1)
  end
end

decode_value = function(str, pos)
  pos = skip_whitespace(str, pos)
  local c = str:sub(pos, pos)
  if c == '"' then
    return decode_string(str, pos)
  elseif c == '{' then
    return decode_object(str, pos)
  elseif c == '[' then
    return decode_array(str, pos)
  elseif c == 't' then
    if str:sub(pos, pos + 3) == 'true' then return true, pos + 4 end
    decode_error(str, pos, 'invalid token')
  elseif c == 'f' then
    if str:sub(pos, pos + 4) == 'false' then return false, pos + 5 end
    decode_error(str, pos, 'invalid token')
  elseif c == 'n' then
    if str:sub(pos, pos + 3) == 'null' then return nil, pos + 4 end
    decode_error(str, pos, 'invalid token')
  elseif c == '-' or (c >= '0' and c <= '9') then
    return decode_number(str, pos)
  else
    decode_error(str, pos, 'unexpected character ' .. c)
  end
end

function M.decode(str)
  if type(str) ~= 'string' then
    error('json.decode: expected string, got ' .. type(str))
  end
  local ok, val, _ = pcall(decode_value, str, 1)
  if not ok then
    error(val)
  end
  return val
end

return M
