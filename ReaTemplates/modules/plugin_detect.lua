-- ============================================================
-- plugin_detect.lua  –  Parse .RTrackTemplate XML for plugin references
-- Extracts VST, VST3, AU, and JS plugin names from the chunk XML.
-- Returns a module table with:
--   plugin_detect.parse_plugins(xml_string)
--     → list of {name, type, installed}
-- ============================================================

local M = {}

-- ============================================================
-- Internal: extract a set of unique plugin names by type
-- ============================================================

-- Patterns to match plugin lines inside RTrackTemplate XML chunks.
-- REAPER state chunks look like:
--   VST "Plugin Name (Manufacturer)" ...
--   VST3 "Plugin Name" ...
--   AU "Plugin Name" ...
--   JS path/to/effect ""
--   <VST "Plugin Name" ...>
--   <JS path/to/effect>

local function strip_quotes(s)
  return (s:gsub('^"', ''):gsub('"$', ''))
end

local function collect_vst(xml, results, seen)
  -- Matches:  VST "Display Name (Manuf)" plugname.dll ...
  --           VST3 "Display Name" ...
  for prefix, quoted in xml:gmatch('(VST3?)%s+"([^"]+)"') do
    local name = strip_quotes(quoted)
    local key = prefix .. ':' .. name
    if not seen[key] then
      seen[key] = true
      results[#results + 1] = { name = name, type = prefix, installed = nil }
    end
  end
end

local function collect_au(xml, results, seen)
  for quoted in xml:gmatch('AU%s+"([^"]+)"') do
    local name = strip_quotes(quoted)
    local key = 'AU:' .. name
    if not seen[key] then
      seen[key] = true
      results[#results + 1] = { name = name, type = 'AU', installed = nil }
    end
  end
end

local function collect_js(xml, results, seen)
  -- JS entries look like:  JS path/to/effect ""   or  <JS path/to/effect>
  -- We want just the path/name component
  for path in xml:gmatch('<JS%s+([^%s>]+)') do
    local key = 'JS:' .. path
    if not seen[key] then
      seen[key] = true
      results[#results + 1] = { name = path, type = 'JS', installed = nil }
    end
  end
  for path in xml:gmatch('\nJS%s+([^%s\n"]+)') do
    local key = 'JS:' .. path
    if not seen[key] then
      seen[key] = true
      results[#results + 1] = { name = path, type = 'JS', installed = nil }
    end
  end
end

-- ============================================================
-- Check if a plugin is installed using a dummy-track approach.
-- We create a temporary track, try to add the FX, and check
-- if it loaded. Then immediately delete the track.
-- This is accurate but slow – only call at save/insert time,
-- not on every frame.
-- ============================================================

local function check_installed_vst(name)
  local track_count = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_count, false)
  local tmp_track = reaper.GetTrack(0, track_count)
  if not tmp_track then return nil end

  -- Try adding the FX; REAPER searches by display name
  local fx_idx = reaper.TrackFX_AddByName(tmp_track, name, false, -1)
  local installed = fx_idx >= 0

  -- Delete the temporary track silently
  reaper.DeleteTrack(tmp_track)

  return installed
end

local function check_installed_js(path)
  local track_count = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(track_count, false)
  local tmp_track = reaper.GetTrack(0, track_count)
  if not tmp_track then return nil end

  local fx_idx = reaper.TrackFX_AddByName(tmp_track, 'JS: ' .. path, false, -1)
  local installed = fx_idx >= 0

  reaper.DeleteTrack(tmp_track)
  return installed
end

-- ============================================================
-- Public API
-- ============================================================

-- Parse plugin references from an .RTrackTemplate XML string.
-- Returns: list of {name, type, installed}
-- installed is nil (unknown) — call enrich_installed_status to fill it in.
function M.parse_plugins(xml)
  local results = {}
  local seen    = {}

  collect_vst(xml, results, seen)
  collect_au(xml, results, seen)
  collect_js(xml, results, seen)

  return results
end

-- Enrich a plugin list with installed status.
-- This is potentially slow (spawns temp tracks) so run only when needed.
function M.enrich_installed_status(plugins)
  reaper.PreventUIRefresh(1)
  reaper.Undo_BeginBlock()

  for _, p in ipairs(plugins) do
    if p.type == 'JS' then
      p.installed = check_installed_js(p.name)
    else
      -- VST, VST3, AU
      p.installed = check_installed_vst(p.name)
    end
  end

  reaper.Undo_EndBlock('ReaTemplates: plugin detection', -1)
  reaper.PreventUIRefresh(-1)

  return plugins
end

-- Quick check: are any plugins in the list missing?
-- Returns true if at least one plugin has installed == false
function M.has_missing_plugins(plugins)
  for _, p in ipairs(plugins) do
    if p.installed == false then return true end
  end
  return false
end

-- Returns only the missing plugins
function M.get_missing_plugins(plugins)
  local missing = {}
  for _, p in ipairs(plugins) do
    if p.installed == false then
      missing[#missing + 1] = p
    end
  end
  return missing
end

return M
