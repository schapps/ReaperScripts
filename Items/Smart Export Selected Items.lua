-- @description Smart Export Selected Items
-- @version 1.8
-- @about
--   A script to easily export selected items of many different channel counts all at once.
--   SWS extension is required. No render preset setup needed.
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @changelog
--   11/21/24 v1.0 - Creating the script
--   11/21/24 v1.3 - Added handling of overlapping items with the same name
--   11/21/24 v1.4 - Fixed error with restoring item selection after glue and undo
--   11/21/24 v1.5 - Changing how Config Area works
--   12/20/24 v1.6 - Fixed bug when exporting multiple overlapping looping items at once
--   02/07/25 v1.7 - Switch to Smart Export Simplified preset and add multichannel track mismatch warning
--   05/21/25 v1.8 - Hardcode render settings directly; remove cfillion/ReaPack dependency


-- Clear the console at the start
reaper.ClearConsole()

if not reaper.SNM_SetIntConfigVar then
  reaper.ShowMessageBox("The SWS extension is required but not installed.\nDownload it from https://www.sws-extension.org", "Missing dependency", 0)
  return
end

-- CONFIGURATION AREA

-- Output filename pattern using REAPER tokens.
-- Common tokens: $item (take name), $project (project name), $projectpath (project folder),
--                $user (Windows username), $date, $hour12_$minute
-- Default: exports WAV files to the project folder, named after the item take name.
local render_output_pattern = "$projectpath\\$item"

-- Apply hardcoded render settings (WAV 24-bit, 48 kHz, selected items via master).
-- Equivalent to the "Smart Export Simplified" preset without requiring any preset to be installed.
local function ApplyHardcodedRenderSettings()
  local SETTINGS_MASK = 0x7FFF
  -- Source: selected items via master (0x40) + embed metadata (0x200)
  -- + mono media to mono files (0x10) + multichannel tracks to multichannel files (0x4)
  local render_settings = 596

  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT', 'ZXZhdxgGAA==', true) -- WAV 24-bit
  reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT2', '', true)
  reaper.GetSetProjectInfo(0, 'RENDER_SRATE', 48000, true)
  reaper.GetSetProjectInfo(0, 'RENDER_CHANNELS', 2, true)
  reaper.GetSetProjectInfo(0, 'RENDER_DITHER', 0, true)

  local current_settings = reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS', 0, false)
  reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS',
    (render_settings & SETTINGS_MASK) | (current_settings & ~SETTINGS_MASK), true)

  reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 4, true)
  reaper.GetSetProjectInfo(0, 'RENDER_STARTPOS', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_ENDPOS', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILFLAG', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TAILMS', 2000, true)
  reaper.GetSetProjectInfo(0, 'RENDER_NORMALIZE', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_NORMALIZE_TARGET', 0.063096, true)
  reaper.GetSetProjectInfo(0, 'RENDER_BRICKWALL', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEIN', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEOUT', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEINSHAPE', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_FADEOUTSHAPE', 1, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TRIMSTART', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_TRIMEND', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_PADSTART', 0, true)
  reaper.GetSetProjectInfo(0, 'RENDER_PADEND', 0, true)

  reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', render_output_pattern, true)

  reaper.SNM_SetIntConfigVar('projrenderlimit', 0)        -- Full-speed offline
  reaper.SNM_SetIntConfigVar('projrenderrateinternal', 1) -- Use project sample rate
  reaper.SNM_SetIntConfigVar('projrenderresample', 10)

  return true
end

-- END OF CONFIGURATION

-- Save current project render settings
local _, original_cfg = reaper.GetSetProjectInfo_String(0, 'RENDER_CFG', '', false)

local num_selected_items = reaper.CountSelectedMediaItems(0)
if num_selected_items == 0 then
  reaper.ShowMessageBox('No media items selected.', 'Error', 0)
  return
end

-- Store the original item selection using GUIDs
local selected_item_GUIDs = {}
for i = 0, num_selected_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  table.insert(selected_item_GUIDs, reaper.BR_GetMediaItemGUID(item))
end

-- Build item_info_list
local item_info_list = {}
local mismatches = {}
for i = 0, num_selected_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then
    local source = reaper.GetMediaItemTake_Source(take)
    local source_num_channels = reaper.GetMediaSourceNumChannels(source)
    local track = reaper.GetMediaItem_Track(item)
    local track_channels = track and reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") or 0
    if source_num_channels > 2 and track_channels ~= source_num_channels then
      local _, track_name = reaper.GetTrackName(track)
      track_name = track_name and track_name ~= "" and track_name or "(unnamed track)"
      local _, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      take_name = take_name and take_name ~= "" and take_name or "(untitled take)"
      table.insert(mismatches, ("Track '%s' has %d channels, but item '%s' has %d channels."):format(track_name, track_channels, take_name, source_num_channels))
    end
    local start_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    local end_pos = start_pos + length
    local retval, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    table.insert(item_info_list, {
      item = item,
      take = take,
      start_pos = start_pos,
      end_pos = end_pos,
      name = take_name,
      source_num_channels = source_num_channels
    })
  else
    reaper.ShowMessageBox('No active take or take is MIDI for item at position ' .. reaper.GetMediaItemInfo_Value(item, 'D_POSITION'), 'Error', 0)
  end
end

if #mismatches > 0 then
  reaper.ShowMessageBox(table.concat(mismatches, "\n") .. "\n\nSet the track channel count to match multichannel items before exporting.", "Item/Track Channel Mismatch", 0)
  return
end

-- Begin undo block
reaper.Undo_BeginBlock()

-- Build overlapping groups
local items_by_name = {}
for _, info in ipairs(item_info_list) do
  local name = info.name or ""
  if not items_by_name[name] then items_by_name[name] = {} end
  table.insert(items_by_name[name], info)
end

local overlapping_groups = {}
local non_overlapping_items = {}

for _, items in pairs(items_by_name) do
  local checked = {}
  for i, item_i in ipairs(items) do
    if not checked[item_i] then
      local group = {item_i}
      checked[item_i] = true
      for j = i + 1, #items do
        local item_j = items[j]
        if not checked[item_j] and item_i.start_pos < item_j.end_pos and item_j.start_pos < item_i.end_pos then
          table.insert(group, item_j)
          checked[item_j] = true
        end
      end
      if #group > 1 then
        table.insert(overlapping_groups, group)
      else
        table.insert(non_overlapping_items, item_i)
      end
    end
  end
end

-- Process overlapping groups
for _, group in ipairs(overlapping_groups) do
  reaper.Main_OnCommand(40289, 0) -- Unselect all items
  for _, info in ipairs(group) do
    reaper.SetMediaItemSelected(info.item, true)
  end
  reaper.Main_OnCommand(41588, 0) -- Glue items
  local glued_item = reaper.GetSelectedMediaItem(0, 0)
  if glued_item then
    local glued_take = reaper.GetActiveTake(glued_item)
    local group_name = group[1].name
    reaper.GetSetMediaItemTakeInfo_String(glued_take, "P_NAME", group_name, true)
    if ApplyHardcodedRenderSettings() then
      reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)
      reaper.Main_OnCommand(41824, 0) -- Render
    end
    reaper.Undo_DoUndo2(0) -- Undo glue
  end
end

-- Process non-overlapping items
if #non_overlapping_items > 0 and ApplyHardcodedRenderSettings() then
  reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)
  reaper.Main_OnCommand(40289, 0) -- Unselect all items
  for _, info in ipairs(non_overlapping_items) do
    reaper.SetMediaItemSelected(info.item, true)
  end
  reaper.Main_OnCommand(41824, 0) -- Render
end

-- Restore selection
reaper.Main_OnCommand(40289, 0)
for _, GUID in ipairs(selected_item_GUIDs) do
  local item = reaper.BR_GetMediaItemByGUID(0, GUID)
  if item then
    reaper.SetMediaItemSelected(item, true)
  end
end

reaper.GetSetProjectInfo_String(0, 'RENDER_CFG', original_cfg, true)
reaper.UpdateArrange()
reaper.Undo_EndBlock('Smart Render Selected Items', -1)
