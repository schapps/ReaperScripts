-- @description Import Selected Items Into ReaSamplomatic on Selected Tracks
-- @author Analogmad, MPL, modification by Stephen Schappler
-- @version 1.6
-- Initial Script by MPL Modified by Analogmad (Chris Kowalski), and further modified by Stephen Schappler
-- From Analogmad: MPL Helped me with this via the Reaper Forums. I had an issue of putting all samples into one RS5K. Added Arming for Audio Recording. Added Velocity Randomizer
-- From Stephen Schappler: I changed the MIDI Velcotiy randomizer this script uses (it now uses one I wrote for this purpose), as well as the actions used to render items to a new takes before and after getting loaded into the sampler
-- @about
--   Import Selected Items Into ReaSamplomatic on Selected Tracks
-- @link https://www.stephenschappler.com
-- @changelog
--   9/3/24 v1.0 - Adding script to ReaPack
--   9/3/24 v1.1 - Changing name of Midi Randomize JSFX to the correct name
--   5/15/25 v1.2 - Multi-track support: items on each selected track load into that track's own RS5K instance
--   5/15/25 v1.3 - ReaImGUI panel with Load Items button
--   5/15/25 v1.4 - Preserve Relative Delays option
--   5/15/25 v1.5 - Obey Note-Offs checkbox
--   5/15/25 v1.6 - Max Voices slider (1-64)

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. "/?.lua;" .. package.path
local ImGui = require "imgui" "0.10"

local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local theme_path  = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

local ctx       = ImGui.CreateContext("Import into ReaSamplomatic")
local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_AlwaysAutoResize
               | ImGui.WindowFlags_NoScrollWithMouse

local script_title    = 'Import Selected Items into ReaSamplomatic on Selected Tracks'
local status_msg      = ""
local preserve_delays  = reaper.GetExtState("ImportToRS5K", "PreserveDelays")  == "true"
local obey_note_offs   = reaper.GetExtState("ImportToRS5K", "ObeyNoteOffs") ~= "false"
local max_voices       = tonumber(reaper.GetExtState("ImportToRS5K", "MaxVoices")) or 12

-------------------------------------------------------------------------------
local function GetRS5kID(tr)
  for i = 1, reaper.TrackFX_GetCount(tr) do
    local retval, fx_name = reaper.TrackFX_GetFXName(tr, i-1, '')
    if fx_name:find('RS5K') or fx_name:find('ReaSamplOmatic5000') then
      return i - 1
    end
  end
  return -1
end

-------------------------------------------------------------------------------
local function GetDelayPluginID(tr)
  for i = 1, reaper.TrackFX_GetCount(tr) do
    local retval, fx_name = reaper.TrackFX_GetFXName(tr, i-1, '')
    if fx_name:find('Time Adjustment Delay') then return i - 1 end
  end
  return -1
end

-------------------------------------------------------------------------------
local function ApplyDelayPlugin(track, delay_sec)
  if delay_sec <= 0 then return end
  local delay_ms = math.min(delay_sec * 1000, 1000)
  local fx = GetDelayPluginID(track)
  if fx == -1 then
    fx = reaper.TrackFX_AddByName(track, 'Time Adjustment Delay', false, -1)
  end
  reaper.TrackFX_SetParamNormalized(track, fx, 0, (delay_ms + 1000) / 2000)
end

-------------------------------------------------------------------------------
local function GetMidiToolID(tr)
  for i = 1, reaper.TrackFX_GetCount(tr) do
    local fxName = ({reaper.TrackFX_GetFXName(tr, i-1, '')})[2]
    if fxName:find('Randomize') then return i-1 end
  end
  return -1
end

-------------------------------------------------------------------------------
local function ExportSelItemsToRs5k(track)
  local number_of_samples = reaper.CountSelectedMediaItems(0)

  local miditool_pos = GetMidiToolID(track)
  if miditool_pos == -1 then
    miditool_pos = reaper.TrackFX_AddByName(track, 'MIDI Randomize Note Velocity', false, -1)
  end

  local rs5k_pos = GetRS5kID(track)
  if rs5k_pos == -1 then
    rs5k_pos = reaper.TrackFX_AddByName(track, 'ReaSamplOmatic5000 (Cockos)', false, -1)
  end

  local slot = 0
  for i = 1, number_of_samples do
    local item = reaper.GetSelectedMediaItem(0, i-1)
    if reaper.GetMediaItemTrack(item) ~= track then goto skip_to_next_item end
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then goto skip_to_next_item end

    local filename = reaper.GetMediaSourceFileName(reaper.GetMediaItemTake_Source(take), '')
    reaper.TrackFX_SetParamNormalized(track, rs5k_pos, 3, 0)   -- note range start
    reaper.TrackFX_SetParamNormalized(track, rs5k_pos, 8, (max_voices - 1) / 63)
    reaper.TrackFX_SetParamNormalized(track, rs5k_pos, 9, 0)   -- attack
    reaper.TrackFX_SetParamNormalized(track, rs5k_pos, 11, obey_note_offs and 1 or 0)
    reaper.TrackFX_SetNamedConfigParm(track, rs5k_pos, "FILE"..slot, filename)
    slot = slot + 1
    ::skip_to_next_item::
  end
  if rs5k_pos then reaper.TrackFX_SetNamedConfigParm(track, rs5k_pos, "DONE", "") end
  return slot
end

-------------------------------------------------------------------------------
local function MIDI_prepare(tr)
  local bits_set = tonumber('111111'..'00000', 2)
  reaper.SetMediaTrackInfo_Value(tr, 'I_RECINPUT', 4096+bits_set)
  reaper.SetMediaTrackInfo_Value(tr, 'I_RECMON', 1)
  reaper.SetMediaTrackInfo_Value(tr, 'I_RECARM', 1)
  reaper.SetMediaTrackInfo_Value(tr, 'I_RECMODE', 1)
end

-------------------------------------------------------------------------------
local function load_items()
  if reaper.CountSelectedMediaItems(0) == 0 then return end

  reaper.Undo_BeginBlock()

  -- snapshot item positions before rendering alters takes
  local track_min_pos, global_min = {}, math.huge
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local tr   = reaper.GetMediaItemTrack(item)
    local pos  = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    if not track_min_pos[tr] or pos < track_min_pos[tr] then track_min_pos[tr] = pos end
    if pos < global_min then global_min = pos end
  end

  reaper.Main_OnCommand(41999, 0) -- render items to new take

  local seen, track_order = {}, {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local tr = reaper.GetMediaItemTrack(reaper.GetSelectedMediaItem(0, i))
    if not seen[tr] then seen[tr] = true; table.insert(track_order, tr) end
  end

  local total_items = 0
  for _, tr in ipairs(track_order) do
    total_items = total_items + ExportSelItemsToRs5k(tr)
    MIDI_prepare(tr)
    if preserve_delays then
      ApplyDelayPlugin(tr, track_min_pos[tr] - global_min)
    end
  end

  reaper.Main_OnCommand(reaper.NamedCommandLookup("_XENAKIOS_SELECTFIRSTTAKEOFITEMS"), 0)
  reaper.Main_OnCommand(40131, 0) -- crop to active take
  reaper.Main_OnCommand(reaper.NamedCommandLookup("_S&M_WNCLS5"), 0) -- close FX windows

  reaper.Undo_EndBlock(script_title, 1)

  local t = #track_order
  status_msg = ("Loaded %d item%s across %d track%s."):format(
    total_items, total_items == 1 and "" or "s",
    t, t == 1 and "" or "s"
  )
end

-------------------------------------------------------------------------------
local function loop()
  local color_count, var_count = theme.Push(ctx)
  ImGui.SetNextWindowSizeConstraints(ctx, 220, 0, 9999, 9999)
  local visible, open = ImGui.Begin(ctx, "Import into ReaSamplomatic", true, WIN_FLAGS)

  if visible then
    local changed, new_val = ImGui.Checkbox(ctx, "Preserve Relative Delays", preserve_delays)
    if changed then
      preserve_delays = new_val
      reaper.SetExtState("ImportToRS5K", "PreserveDelays", tostring(preserve_delays), true)
    end
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Adds a delay plugin to offset each track's audio\nby its relative start position. Max range: 0-1000ms.")
    end

    local changed2, new_val2 = ImGui.Checkbox(ctx, "Obey Note-Offs", obey_note_offs)
    if changed2 then
      obey_note_offs = new_val2
      reaper.SetExtState("ImportToRS5K", "ObeyNoteOffs", tostring(obey_note_offs), true)
    end

    ImGui.Spacing(ctx)
    ImGui.Text(ctx, "Max Voices")
    ImGui.SetNextItemWidth(ctx, -1)
    local changed3, new_val3 = ImGui.SliderInt(ctx, "##voices", max_voices, 1, 64)
    if changed3 then
      max_voices = new_val3
      reaper.SetExtState("ImportToRS5K", "MaxVoices", tostring(max_voices), true)
    end

    if status_msg ~= "" then
      ImGui.Spacing(ctx)
      ImGui.Text(ctx, status_msg)
    end

    ImGui.Spacing(ctx)
    local no_items = reaper.CountSelectedMediaItems(0) == 0
    if no_items then ImGui.BeginDisabled(ctx, true) end
    if ImGui.Button(ctx, "Load Items", -1, 0) then load_items() end
    if no_items then ImGui.EndDisabled(ctx) end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
