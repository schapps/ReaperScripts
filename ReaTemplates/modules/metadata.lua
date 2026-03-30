-- ============================================================
-- metadata.lua  –  Read/write meta.json sidecars and scan local template folder
-- Meta folder: <templates_folder>/reatemplate_meta/<name>.json
-- Community cache: <ResourcePath>/Scripts/reatemplate_cache/<creator>__<name>.json
-- ============================================================

local M = {}

local json   = nil
local config = nil

local path_sep = package.config:sub(1, 1)

-- ============================================================
-- Path helpers
-- ============================================================

local function normalize(p)
  return p:gsub('\\', '/')
end

local function join(...)
  local parts = {...}
  local result = parts[1] or ''
  for i = 2, #parts do
    result = result:gsub('[/\\]$', '') .. '/' .. parts[i]:gsub('^[/\\]', '')
  end
  return result
end

local function meta_dir(templates_folder)
  return join(templates_folder, 'reatemplate_meta')
end

local function meta_path(templates_folder, name)
  return join(meta_dir(templates_folder), name .. '.json')
end

local function cache_dir()
  return join(reaper.GetResourcePath(), 'Scripts', 'reatemplate_cache')
end

local function cache_path(creator, name)
  return join(cache_dir(), creator .. '__' .. name .. '.json')
end

-- ============================================================
-- Ensure directories exist
-- ============================================================

local function ensure_dir(dir)
  if not reaper.file_exists(dir) then
    if path_sep == '\\' then
      os.execute('mkdir "' .. dir:gsub('/', '\\') .. '" 2>nul')
    else
      os.execute('mkdir -p "' .. dir .. '"')
    end
  end
end

-- ============================================================
-- Default metadata structure
-- ============================================================

function M.default_meta(name, creator)
  local now = os.date('!%Y-%m-%dT%H:%M:%SZ')
  return {
    name           = name or '',
    description    = '',
    creator        = creator or '',
    date_created   = now,
    date_modified  = now,
    version        = 1,
    predefined_tags = {},
    custom_tags    = {},
    plugins        = {},
    preview_image  = '',
    uploaded       = false,
  }
end

-- ============================================================
-- Read / write local meta.json
-- ============================================================

function M.read_meta(name)
  local cfg = config.get()
  local path = meta_path(cfg.templates_folder, name)
  local f = io.open(path, 'r')
  if not f then return nil end
  local raw = f:read('*a')
  f:close()
  local ok, data = pcall(json.decode, raw)
  if ok and type(data) == 'table' then return data end
  return nil
end

function M.write_meta(meta)
  local cfg = config.get()
  ensure_dir(meta_dir(cfg.templates_folder))
  local path = meta_path(cfg.templates_folder, meta.name)
  -- Update date_modified
  meta.date_modified = os.date('!%Y-%m-%dT%H:%M:%SZ')
  local f = io.open(path, 'w')
  if not f then return false, 'cannot write ' .. path end
  f:write(json.encode(meta))
  f:close()
  return true
end

function M.delete_meta(name)
  local cfg = config.get()
  local path = meta_path(cfg.templates_folder, name)
  os.remove(path)
end

-- ============================================================
-- Scan local templates folder for .RTrackTemplate files
-- ============================================================

-- Returns a list of {name, path, meta} tables
function M.scan_local()
  local cfg = config.get()
  local folder = cfg.templates_folder
  if not folder or folder == '' then return {} end

  local results = {}

  -- Use reaper.EnumerateFiles to list files in the folder
  local i = 0
  while true do
    local fname = reaper.EnumerateFiles(folder, i)
    if not fname then break end
    if fname:lower():match('%.rtracktemplate$') then
      local name = fname:match('^(.+)%.%w+$') or fname
      local full_path = join(folder, fname)
      local meta = M.read_meta(name)
      if not meta then
        -- Create a bare meta if none exists
        meta = M.default_meta(name, cfg.github_username or '')
      end
      results[#results + 1] = {
        name = name,
        path = full_path,
        meta = meta,
      }
    end
    i = i + 1
  end

  return results
end

-- ============================================================
-- Community cache
-- ============================================================

function M.write_cache(meta)
  ensure_dir(cache_dir())
  local path = cache_path(meta.creator or 'unknown', meta.name)
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(json.encode(meta))
  f:close()
  return true
end

function M.read_cache(creator, name)
  local path = cache_path(creator, name)
  local f = io.open(path, 'r')
  if not f then return nil end
  local raw = f:read('*a')
  f:close()
  local ok, data = pcall(json.decode, raw)
  if ok and type(data) == 'table' then return data end
  return nil
end

-- Return all cached community templates
function M.scan_cache()
  local dir = cache_dir()
  ensure_dir(dir)
  local results = {}
  local i = 0
  while true do
    local fname = reaper.EnumerateFiles(dir, i)
    if not fname then break end
    if fname:lower():match('%.json$') then
      local path = join(dir, fname)
      local f = io.open(path, 'r')
      if f then
        local raw = f:read('*a')
        f:close()
        local ok, data = pcall(json.decode, raw)
        if ok and type(data) == 'table' then
          results[#results + 1] = data
        end
      end
    end
    i = i + 1
  end
  return results
end

function M.clear_cache()
  local dir = cache_dir()
  local i = 0
  while true do
    local fname = reaper.EnumerateFiles(dir, i)
    if not fname then break end
    if fname:lower():match('%.json$') then
      os.remove(join(dir, fname))
    end
    i = i + 1
  end
end

-- ============================================================
-- Template file path helper
-- ============================================================

function M.template_file_path(name)
  local cfg = config.get()
  return join(cfg.templates_folder, name .. '.RTrackTemplate')
end

-- ============================================================
-- Module initialiser
-- ============================================================

function M.init(json_mod, config_mod)
  json   = json_mod
  config = config_mod
end

return M
