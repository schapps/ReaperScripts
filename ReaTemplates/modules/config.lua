-- ============================================================
-- config.lua  –  Load / save user configuration
-- Config file: <ResourcePath>/Scripts/reatemplate_config.json
--
-- PAT obfuscation: XOR each byte with a repeating key, then Base64-encode.
-- NOTE: This is lightweight obfuscation to avoid plaintext storage.
--       It is NOT encryption and does NOT protect against a determined
--       attacker who reads both this source file and the config file.
-- ============================================================

local M = {}

-- These are filled in by M.init(json_mod, base64_mod)
local json   = nil
local base64 = nil

-- ============================================================
-- Internal constants
-- ============================================================

local XOR_KEY = { 0x52, 0x65, 0x61, 0x54, 0x65, 0x6D, 0x70, 0x6C }  -- "ReaTempl"

local function config_path()
  return reaper.GetResourcePath() .. '/Scripts/reatemplate_config.json'
end

-- ============================================================
-- XOR obfuscation helpers
-- ============================================================

local function xor_bytes(data)
  local out = {}
  for i = 1, #data do
    local b = data:byte(i)
    local k = XOR_KEY[((i - 1) % #XOR_KEY) + 1]
    out[i] = string.char(b ~ k)
  end
  return table.concat(out)
end

-- Obfuscate PAT: XOR → Base64
function M.obfuscate_pat(plain_pat)
  if not plain_pat or plain_pat == '' then return '' end
  return base64.encode(xor_bytes(plain_pat))
end

-- Deobfuscate PAT: Base64 → XOR
function M.deobfuscate_pat(encoded_pat)
  if not encoded_pat or encoded_pat == '' then return '' end
  local ok, result = pcall(function()
    return xor_bytes(base64.decode(encoded_pat))
  end)
  if ok then return result else return '' end
end

-- ============================================================
-- Default config
-- ============================================================

local function default_config()
  -- Auto-detect the REAPER track templates folder
  local res = reaper.GetResourcePath()
  local sep = package.config:sub(1, 1)
  local templates_folder = res .. sep .. 'TrackTemplates'
  return {
    github_username  = '',
    github_pat       = '',
    github_repo      = '',
    templates_folder = templates_folder,
    last_sync        = '',
    admin_username   = '',
    predefined_tags  = {},  -- admin-managed shared list (cached from GitHub)
    user_tags        = {},  -- user's personal ordered tag list (cached from GitHub)
  }
end

-- ============================================================
-- Load / save
-- ============================================================

local _config = nil  -- cached config table

function M.load()
  local path = config_path()
  local f = io.open(path, 'r')
  if not f then
    _config = default_config()
    return _config
  end
  local raw = f:read('*a')
  f:close()

  local ok, parsed = pcall(json.decode, raw)
  if not ok or type(parsed) ~= 'table' then
    _config = default_config()
    return _config
  end

  -- Merge with defaults so any new keys are present
  local cfg = default_config()
  for k, v in pairs(parsed) do
    cfg[k] = v
  end
  _config = cfg
  return _config
end

function M.save(cfg)
  _config = cfg
  local path = config_path()

  -- Ensure Scripts directory exists
  local scripts_dir = reaper.GetResourcePath() .. '/Scripts'
  if not reaper.file_exists(scripts_dir) then
    -- try to create it (best-effort)
    os.execute('mkdir "' .. scripts_dir:gsub('/', '\\') .. '"')
  end

  local encoded = json.encode(cfg)
  local f = io.open(path, 'w')
  if not f then
    reaper.ShowMessageBox('Could not write config file:\n' .. path, 'ReaTemplates Error', 0)
    return false
  end
  f:write(encoded)
  f:close()
  return true
end

function M.get()
  if not _config then M.load() end
  return _config
end

-- Returns true when the config has never been set up (no username saved)
function M.is_first_launch()
  local cfg = M.get()
  return cfg.github_username == '' or cfg.github_username == nil
end

-- Convenience: return the plain-text PAT from config
function M.get_pat()
  local cfg = M.get()
  if not cfg.github_pat or cfg.github_pat == '' then return '' end
  return M.deobfuscate_pat(cfg.github_pat)
end

-- ============================================================
-- Module initialiser (must be called before any other method)
-- ============================================================

function M.init(json_mod, base64_mod)
  json   = json_mod
  base64 = base64_mod
end

return M
