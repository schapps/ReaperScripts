-- @description Smart Export Selected Items - Configure
-- @version 1.0
-- @about
--   Opens the export-destination setup dialog for "Smart Export Selected Items"
--   at any time, so the output directory/filename pattern can be changed without
--   hand-editing the sidecar config file. Does not export anything itself.
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @provides
--   [nomain] ../Common/SmartExportSetupDialog.lua > Common/SmartExportSetupDialog.lua
-- @changelog
--   08/11/26 v1.0 - Initial release

local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("(.*[/\\])")
local config_path = script_dir .. "Smart Export Selected Items - User Config.lua"

local function load_config(path)
  local cfg = {}
  local f = io.open(path, "r")
  if not f then return cfg end
  local content = f:read("*all")
  f:close()
  local env = setmetatable({}, {
    __index = _G,
    __newindex = function(t, k, v) cfg[k] = v end
  })
  local chunk, err
  if _VERSION == "Lua 5.1" then
    chunk, err = loadstring(content)  -- luacheck: ignore
    if chunk then setfenv(chunk, env) end  -- luacheck: ignore
  else
    chunk, err = load(content, "config", "t", env)
  end
  if not chunk then
    reaper.ShowMessageBox("Config syntax error:\n" .. tostring(err), "Smart Export Config Error", 0)
    return cfg
  end
  local ok, run_err = pcall(chunk)
  if not ok then
    reaper.ShowMessageBox("Config error:\n" .. tostring(run_err), "Smart Export Config Error", 0)
  end
  return cfg
end

local function save_config(dir, pattern, mono_enabled, mono_threshold)
  local f = io.open(config_path, "w")
  if not f then return end
  f:write("-- Smart Export Selected Items - User Config\n")
  f:write("-- Edit these settings to customize your export.\n")
  f:write("-- This file will NOT be overwritten by ReaPack updates.\n\n")
  f:write("-- Output root directory (maps to RENDER_FILE).\n")
  f:write("-- Set to empty string \"\" to use the project folder as the root.\n")
  f:write("render_output_dir = " .. string.format("%q", dir) .. "\n\n")
  f:write("-- Output filename pattern (maps to RENDER_PATTERN).\n")
  f:write("-- Common tokens: $item (take name), $project (project name), $projectpath (project folder),\n")
  f:write("--                $user (Windows username), $date, $hour12_$minute\n")
  f:write("render_output_pattern = " .. string.format("%q", pattern) .. "\n\n")
  f:write("-- Auto-downmix stereo items to mono before export when L/R correlation meets the threshold.\n")
  f:write("mono_downmix_enabled = " .. tostring(mono_enabled) .. "\n")
  f:write("mono_downmix_threshold = " .. tostring(mono_threshold) .. "\n")
  f:close()
end

local default_output_dir             = "D:\\Reaper Export"
local default_output_pattern         = "$project\\$item"
local default_mono_downmix_enabled   = true
local default_mono_downmix_threshold = 0.9

local render_output_dir      = default_output_dir
local render_output_pattern  = default_output_pattern
local mono_downmix_enabled   = default_mono_downmix_enabled
local mono_downmix_threshold = default_mono_downmix_threshold

if reaper.file_exists(config_path) then
  local cfg = load_config(config_path)
  render_output_dir     = cfg.render_output_dir     or default_output_dir
  render_output_pattern = cfg.render_output_pattern or default_output_pattern
  if cfg.mono_downmix_enabled   ~= nil then mono_downmix_enabled   = cfg.mono_downmix_enabled   end
  if cfg.mono_downmix_threshold ~= nil then mono_downmix_threshold = cfg.mono_downmix_threshold end
end

local setup_dialog_path = script_dir .. "Common/SmartExportSetupDialog.lua"
if not reaper.file_exists(setup_dialog_path) then
  setup_dialog_path = script_dir .. "../Common/SmartExportSetupDialog.lua"
end

if not reaper.file_exists(setup_dialog_path) then
  reaper.ShowMessageBox("Could not find Common/SmartExportSetupDialog.lua", "Smart Export Configure", 0)
  return
end

local SetupDialog = dofile(setup_dialog_path)
SetupDialog.Show({
  script_dir        = script_dir,
  initial_dir       = render_output_dir,
  initial_pattern   = render_output_pattern,
  save_button_label = "Save",
  save_config = function(dir, pattern)
    save_config(dir, pattern, mono_downmix_enabled, mono_downmix_threshold)
  end,
})
