-- ============================================================
-- github.lua  –  GitHub REST API v3 client
-- Wraps GET, PUT, DELETE /repos/{repo}/contents/...
-- All requests include:
--   Authorization: token <PAT>
--   User-Agent:    ReaTemplates/1.0
--   Accept:        application/vnd.github.v3+json
-- Returns a module table with individual API operations.
-- ============================================================

local M = {}

local json   = nil
local base64 = nil
local http   = nil
local config = nil

local BASE_URL = 'https://api.github.com'

-- ============================================================
-- Internal helpers
-- ============================================================

local function auth_headers()
  local pat = config.get_pat()
  return {
    ['Authorization'] = 'token ' .. pat,
    ['User-Agent']    = 'ReaTemplates/1.0',
    ['Accept']        = 'application/vnd.github.v3+json',
    ['Content-Type']  = 'application/json',
  }
end

local function repo_url(path)
  local cfg = config.get()
  return BASE_URL .. '/repos/' .. (cfg.github_repo or '') .. path
end

-- Parse a GitHub API JSON response; returns parsed table or nil + error string
local function parse_response(body, err)
  if err then return nil, err end
  if not body or body == '' then return nil, 'empty response' end
  local ok, data = pcall(json.decode, body)
  if not ok or type(data) ~= 'table' then
    return nil, 'json parse error: ' .. tostring(data)
  end
  -- GitHub errors come back as {"message": "..."}
  if data.message and not data.name and not data.sha and not data.content then
    return nil, 'GitHub API error: ' .. data.message
  end
  return data, nil
end

-- ============================================================
-- Low-level API
-- ============================================================

-- GET /repos/{repo}/contents/{path}
function M.get_contents(path)
  local url = repo_url('/contents/' .. path)
  local body, err = http.get(url, auth_headers())
  return parse_response(body, err)
end

-- PUT /repos/{repo}/contents/{path}
-- content_bytes: raw bytes to upload (will be base64-encoded)
-- message:       commit message
-- sha:           existing file SHA (nil for new file)
function M.put_contents(path, content_bytes, message, sha)
  local url = repo_url('/contents/' .. path)
  local payload = {
    message = message or 'Update ' .. path,
    content = base64.encode(content_bytes),
  }
  if sha and sha ~= '' then
    payload.sha = sha
  end
  local body_str = json.encode(payload)
  local resp_body, err = http.put(url, auth_headers(), body_str)
  return parse_response(resp_body, err)
end

-- DELETE /repos/{repo}/contents/{path}
-- sha:     SHA of the file to delete (required by GitHub API)
-- message: commit message
function M.delete_contents(path, sha, message)
  local url = repo_url('/contents/' .. path)
  local payload = {
    message = message or 'Delete ' .. path,
    sha     = sha,
  }
  local body_str = json.encode(payload)
  local resp_body, err = http.delete(url, auth_headers(), body_str)
  return parse_response(resp_body, err)
end

-- ============================================================
-- High-level template operations
-- ============================================================

-- Validate PAT by calling GET /user
function M.validate_pat()
  local url = BASE_URL .. '/user'
  local body, err = http.get(url, auth_headers())
  local data, parse_err = parse_response(body, err)
  if parse_err then return false, parse_err end
  if data and data.login then
    return true, data.login
  end
  return false, 'could not retrieve user info'
end

-- Get the SHA of an existing file (or nil if not found)
function M.get_file_sha(api_path)
  local data, err = M.get_contents(api_path)
  if err then return nil end
  return data and data.sha or nil
end

-- Upload a template's meta.json to GitHub
-- meta:     metadata table
-- Returns: true or nil, err
function M.upload_meta(meta)
  local cfg = config.get()
  local api_path = 'templates/' .. cfg.github_username .. '/' .. meta.name .. '/meta.json'
  local sha = M.get_file_sha(api_path)
  local content = json.encode(meta)
  local msg = sha and ('Update meta for ' .. meta.name) or ('Add meta for ' .. meta.name)
  local _, err = M.put_contents(api_path, content, msg, sha)
  if err then return nil, err end
  return true
end

-- Upload the .RTrackTemplate file to GitHub
function M.upload_template_file(name, file_path)
  local cfg = config.get()
  local f = io.open(file_path, 'rb')
  if not f then return nil, 'cannot read file: ' .. file_path end
  local content = f:read('*a')
  f:close()

  local api_path = 'templates/' .. cfg.github_username .. '/' .. name .. '/' .. name .. '.RTrackTemplate'
  local sha = M.get_file_sha(api_path)
  local msg = sha and ('Update ' .. name) or ('Add ' .. name)
  local _, err = M.put_contents(api_path, content, msg, sha)
  if err then return nil, err end
  return true
end

-- List all creator folders under /templates
-- Returns: list of {name} tables or nil, err
function M.list_creators()
  local data, err = M.get_contents('templates')
  if err then return nil, err end
  if type(data) ~= 'table' then return nil, 'unexpected response' end
  -- data is an array of directory entries
  local creators = {}
  for _, entry in ipairs(data) do
    if entry.type == 'dir' then
      creators[#creators + 1] = entry.name
    end
  end
  return creators, nil
end

-- List all templates for a given creator
-- Returns: list of {name} or nil, err
function M.list_templates_for(creator)
  local data, err = M.get_contents('templates/' .. creator)
  if err then return nil, err end
  if type(data) ~= 'table' then return nil, 'unexpected response' end
  local templates = {}
  for _, entry in ipairs(data) do
    if entry.type == 'dir' then
      templates[#templates + 1] = entry.name
    end
  end
  return templates, nil
end

-- Fetch meta.json for a specific creator/template
-- Returns: metadata table or nil, err
function M.fetch_meta(creator, name)
  local api_path = 'templates/' .. creator .. '/' .. name .. '/meta.json'
  local data, err = M.get_contents(api_path)
  if err then return nil, err end
  if not data or not data.content then return nil, 'no content field in response' end

  local decoded = base64.decode(data.content)
  local ok, meta = pcall(json.decode, decoded)
  if not ok or type(meta) ~= 'table' then
    return nil, 'cannot parse meta.json'
  end
  return meta, nil
end

-- Download the .RTrackTemplate file content (raw bytes)
-- Returns: raw_bytes or nil, err
function M.download_template_file(creator, name)
  local api_path = 'templates/' .. creator .. '/' .. name .. '/' .. name .. '.RTrackTemplate'
  local data, err = M.get_contents(api_path)
  if err then return nil, err end
  if not data or not data.content then return nil, 'no content in response' end
  local content = base64.decode(data.content)
  return content, nil
end

-- Fetch the admin tags list
-- Returns: tags_table {predefined_tags=[...]} or nil, err
function M.fetch_tags()
  local data, err = M.get_contents('config/tags.json')
  if err then return nil, err end
  if not data or not data.content then return nil, 'no content' end
  local decoded = base64.decode(data.content)
  local ok, tags = pcall(json.decode, decoded)
  if not ok or type(tags) ~= 'table' then return nil, 'cannot parse tags.json' end
  return tags, nil
end

-- Update the admin tags list
function M.update_tags(tags_table)
  local api_path = 'config/tags.json'
  local sha = M.get_file_sha(api_path)
  local content = json.encode(tags_table)
  local _, err = M.put_contents(api_path, content, 'Update tags list', sha)
  if err then return nil, err end
  return true
end

-- Fetch a user's personal tag list from config/<username>_tags.json
-- Returns: { ordered_tags = [...] } or nil, err
function M.fetch_user_tags(username)
  if not username or username == '' then return nil, 'no username' end
  local api_path = 'config/' .. username .. '_tags.json'
  local data, err = M.get_contents(api_path)
  if err then return nil, err end
  if not data or not data.content then return nil, 'no content' end
  local decoded = base64.decode(data.content)
  local ok, tags = pcall(json.decode, decoded)
  if not ok or type(tags) ~= 'table' then return nil, 'cannot parse user tags' end
  return tags, nil
end

-- Save a user's personal tag list to config/<username>_tags.json
-- ordered_tags_list: array of tag strings in display order
-- Returns: true or nil, err
function M.update_user_tags(username, ordered_tags_list)
  if not username or username == '' then return nil, 'no username' end
  local api_path = 'config/' .. username .. '_tags.json'
  local sha = M.get_file_sha(api_path)
  local content = json.encode({ ordered_tags = ordered_tags_list })
  local msg = sha and ('Update tags for ' .. username) or ('Add tags for ' .. username)
  local _, err = M.put_contents(api_path, content, msg, sha)
  if err then return nil, err end
  return true
end

-- Admin: delete a template (meta.json + template file)
function M.admin_delete_template(creator, name)
  local meta_path = 'templates/' .. creator .. '/' .. name .. '/meta.json'
  local tmpl_path = 'templates/' .. creator .. '/' .. name .. '/' .. name .. '.RTrackTemplate'

  -- Get SHAs
  local meta_sha = M.get_file_sha(meta_path)
  local tmpl_sha = M.get_file_sha(tmpl_path)

  local errors = {}
  if meta_sha then
    local _, err = M.delete_contents(meta_path, meta_sha, 'Admin: delete ' .. name .. ' meta')
    if err then errors[#errors + 1] = err end
  end
  if tmpl_sha then
    local _, err = M.delete_contents(tmpl_path, tmpl_sha, 'Admin: delete ' .. name)
    if err then errors[#errors + 1] = err end
  end

  if #errors > 0 then return nil, table.concat(errors, '; ') end
  return true
end

-- ============================================================
-- Module initialiser
-- ============================================================

function M.init(json_mod, base64_mod, http_mod, config_mod)
  json   = json_mod
  base64 = base64_mod
  http   = http_mod
  config = config_mod
end

return M
