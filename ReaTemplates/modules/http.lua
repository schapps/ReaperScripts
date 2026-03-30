-- ============================================================
-- http.lua  –  HTTP abstraction layer
-- Prefers SWS Http_Get / Http_Post when available.
-- Falls back to curl via io.popen for GET, and a temp-file approach for PUT/DELETE.
-- All GitHub requests inject Authorization and User-Agent headers automatically
-- when a PAT is provided.
-- Returns a module table:
--   http.get(url, headers)          → body_str or nil, err_str
--   http.put(url, headers, body)    → body_str or nil, err_str
--   http.delete(url, headers, body) → body_str or nil, err_str
--   http.check_online()             → bool
-- ============================================================

local M = {}

local HAS_SWS_HTTP = reaper.APIExists('Http_Get')

-- ============================================================
-- Internal helpers
-- ============================================================

-- Build a flat list of header strings: {"Key: Value", ...}
local function headers_to_list(headers)
  local list = {}
  for k, v in pairs(headers or {}) do
    list[#list + 1] = k .. ': ' .. v
  end
  return list
end

-- SWS Http_Get wrapper
local function sws_get(url, headers)
  local header_str = table.concat(headers_to_list(headers), '\r\n')
  local ok, response = reaper.Http_Get(url, header_str)
  if ok then
    return response, nil
  else
    return nil, 'Http_Get failed'
  end
end

-- curl-based GET fallback (synchronous via io.popen)
local function curl_get(url, headers)
  local args = { 'curl', '-s', '-L', '--max-time', '15' }
  for k, v in pairs(headers or {}) do
    args[#args + 1] = '-H'
    args[#args + 1] = '"' .. k .. ': ' .. v .. '"'
  end
  args[#args + 1] = '"' .. url .. '"'
  local cmd = table.concat(args, ' ')
  local ok, handle = pcall(io.popen, cmd, 'r')
  if not ok or not handle then
    return nil, 'curl not available'
  end
  local body = handle:read('*a')
  handle:close()
  return body, nil
end

-- curl-based PUT / DELETE via temp file
local function curl_request(method, url, headers, body)
  local temp_in  = os.tmpname()
  local temp_out = os.tmpname()

  -- Write body to temp file
  if body then
    local f = io.open(temp_in, 'wb')
    if not f then return nil, 'cannot write temp file' end
    f:write(body)
    f:close()
  end

  local args = {
    'curl', '-s', '-L',
    '-X', method,
    '--max-time', '30',
    '-o', '"' .. temp_out .. '"',
  }

  if body then
    args[#args + 1] = '--data-binary'
    args[#args + 1] = '@"' .. temp_in .. '"'
  end

  for k, v in pairs(headers or {}) do
    args[#args + 1] = '-H'
    args[#args + 1] = '"' .. k .. ': ' .. v .. '"'
  end
  args[#args + 1] = '"' .. url .. '"'

  local cmd = table.concat(args, ' ')
  local ok_popen, handle = pcall(io.popen, cmd .. ' 2>&1', 'r')
  if ok_popen and handle then
    handle:read('*a')
    handle:close()
  end

  -- Read output file
  local f = io.open(temp_out, 'rb')
  local resp = f and f:read('*a') or nil
  if f then f:close() end

  -- Clean up temp files
  os.remove(temp_in)
  os.remove(temp_out)

  if resp then
    return resp, nil
  else
    return nil, method .. ' request failed'
  end
end

-- SWS Http_Post wrapper (used for all non-GET verbs when available)
-- SWS only exposes Http_Get and Http_Post; for PUT/DELETE we use curl.
local function sws_post(url, headers, body)
  local header_str = table.concat(headers_to_list(headers), '\r\n')
  local ok, response = reaper.Http_Post(url, body or '', header_str)
  if ok then
    return response, nil
  else
    return nil, 'Http_Post failed'
  end
end

-- ============================================================
-- Public API
-- ============================================================

function M.get(url, headers)
  if HAS_SWS_HTTP then
    return sws_get(url, headers)
  else
    return curl_get(url, headers)
  end
end

function M.put(url, headers, body)
  -- SWS does not have a generic PUT method, so always use curl for PUT
  return curl_request('PUT', url, headers, body)
end

function M.delete(url, headers, body)
  return curl_request('DELETE', url, headers, body)
end

-- Quick connectivity check — attempts GET on GitHub API root
function M.check_online()
  local body, err = M.get('https://api.github.com', {
    ['User-Agent'] = 'ReaTemplates/1.0',
  })
  if err or not body or body == '' then
    return false
  end
  return true
end

return M
