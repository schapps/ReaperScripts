-- @description ReaTemplates
-- @author Stephen Schappler
-- @version 0.1
-- @about
--   ReaImGUI-based REAPER script for saving, tagging, browsing, and sharing
--   track templates via a private GitHub repository.
--   Features: rich metadata, tag filtering, plugin detection, background sync.
-- @link https://www.stephenschappler.com
-- @provides
--   [main] ReaTemplates.lua
--   modules/json.lua
--   modules/base64.lua
--   modules/http.lua
--   modules/config.lua
--   modules/metadata.lua
--   modules/github.lua
--   modules/sync.lua
--   modules/plugin_detect.lua
--   modules/toast.lua
--   modules/ui.lua
-- @changelog
--   0.1 - Just experimenting. Not ready for use.

-- ============================================================
-- ReaImGUI dependency check + bootstrap
-- ============================================================
if not reaper.ImGui_GetBuiltinPath then
  reaper.MB(
    'ReaImGui is required for ReaTemplates.\n\nInstall it via ReaPack: Extensions > ReaPack > Browse packages > ReaImGui.',
    'Missing Dependency', 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

-- ============================================================
-- Paths
-- ============================================================
local script_path = select(2, reaper.get_action_context())
local script_dir  = script_path:match('^(.*[/\\])')
local modules_dir = script_dir .. 'modules/'

-- Theme: check sibling Common/ first, then parent Common/
local theme_path = script_dir .. 'Common/ReaImGuiTheme.lua'
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. '../Common/ReaImGuiTheme.lua'
end
if not reaper.file_exists(theme_path) then
  reaper.MB(
    'ReaImGuiTheme.lua not found.\n\nExpected at:\n' .. theme_path,
    'ReaTemplates: Missing Theme', 0)
  return
end

-- ============================================================
-- Load utility modules via dofile (absolute paths)
-- ============================================================
local function load_module(name)
  local path = modules_dir .. name
  if not reaper.file_exists(path) then
    reaper.MB('Missing module: ' .. path, 'ReaTemplates Error', 0)
    error('Missing module: ' .. path)
  end
  return dofile(path)
end

local theme         = dofile(theme_path)
local json          = load_module('json.lua')
local base64        = load_module('base64.lua')
local http          = load_module('http.lua')
local config        = load_module('config.lua')
local metadata      = load_module('metadata.lua')
local github        = load_module('github.lua')
local sync          = load_module('sync.lua')
local plugin_detect = load_module('plugin_detect.lua')
local toast         = load_module('toast.lua')
local ui            = load_module('ui.lua')

-- ============================================================
-- Wire up module dependencies (init calls)
-- ============================================================
config.init(json, base64)
metadata.init(json, config)
github.init(json, base64, http, config)
sync.init(github, metadata, config, toast)

-- ============================================================
-- ImGui context
-- ============================================================
local ctx = ImGui.CreateContext('ReaTemplates')

-- ============================================================
-- Online check (runs once on startup, blocking but fast)
-- ============================================================
local is_online = false
do
  local ok = pcall(function()
    is_online = http.check_online()
  end)
  if not ok then is_online = false end
end

-- ============================================================
-- Initialise UI module
-- ============================================================
ui.init(ImGui, ctx, theme, json, config, metadata, github, sync, plugin_detect, toast)
ui.set_online(is_online)

-- ============================================================
-- Periodic online re-check (every ~30 seconds)
-- ============================================================
local last_online_check = reaper.time_precise()
local ONLINE_CHECK_INTERVAL = 30.0

-- ============================================================
-- Main defer loop
-- ============================================================
local function loop()
  -- Re-check online status periodically
  local now = reaper.time_precise()
  if now - last_online_check >= ONLINE_CHECK_INTERVAL then
    last_online_check = now
    local ok, result = pcall(http.check_online)
    local new_online = ok and result or false
    if new_online ~= is_online then
      is_online = new_online
      ui.set_online(is_online)
      if is_online then
        toast.info('Connection restored')
      else
        toast.warning('Connection lost')
      end
    end
  end

  -- Render UI; returns false when window is closed
  local keep_open = ui.render()

  if keep_open then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
