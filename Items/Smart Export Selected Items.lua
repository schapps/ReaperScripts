-- @description Smart Export Selected Items
-- @version 1.6
-- @about
--   A script to easily export selected items of many different channel counts all at once.
--   cfillion's Apply Render Preset scripts are required to work
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @changelog
--   11/21/24 v1.0 - Creating the script
--   11/21/24 v1.3 - Added handling of overlapping items with the same name
--   11/21/24 v1.4 - Fixed error with restoring item selection after glue and undo
--   11/21/24 v1.5 - Changing how Config Area works
--   12/20/24 v1.6 - Fixed bug when exporting multiple overlapping looping items at once


-- Clear the console at the start
reaper.ClearConsole()

-- CONFIGURATION AREA
-- Map effective channel counts to render preset names
local preset_map = {
  [1] = "Marathon - Mono", -- Preset name for Mono
  [2] = "Marathon - Stereo", -- Preset name for Stereo
  [4] = "Marathon - Quad", -- Preset name for Quad
  [6] = "Marathon - 6ch" -- Preset name for Surround
}

-- Path to cfillion's Apply render preset script
local apply_preset_script_path = ("%s/Scripts/ReaTeam Scripts/Rendering/cfillion_Apply render preset.lua"):format(reaper.GetResourcePath())

-- Ensure the Apply Render Preset script is available
local function ApplyRenderPresetByName(preset_name)
  if not reaper.file_exists(apply_preset_script_path) then
    reaper.ShowMessageBox("Apply render preset script not found.\n" .. apply_preset_script_path, "Error", 0)
    return false
  end
  ApplyPresetByName = preset_name
  dofile(apply_preset_script_path)
  return true
end

-- END OF CONFIGURATION

-- Function to map I_CHANMODE to effective channel count
local function GetEffectiveChannelCount(take, source_num_channels)
  local chan_mode = reaper.GetMediaItemTakeInfo_Value(take, 'I_CHANMODE')
  local effective_channels = source_num_channels
  if chan_mode == 0 then
    effective_channels = source_num_channels
  elseif chan_mode >= 1 and chan_mode <= 3 then
    effective_channels = 1
  elseif chan_mode >= 65 and chan_mode <= 71 then
    effective_channels = 1
  elseif chan_mode == 4 then
    effective_channels = 2
  else
    effective_channels = source_num_channels
  end
  return effective_channels
end

-- Save current project render settings
local _, original_cfg = reaper.GetSetProjectInfo_String(0, 'RENDER_CFG', '', false)

local num_selected_items = reaper.CountSelectedMediaItems(0)
if num_selected_items == 0 then
  reaper.ShowMessageBox('No media items selected.', 'Error', 0)
  return
end

-- Begin undo block
reaper.Undo_BeginBlock()

-- Store the original item selection using GUIDs
local selected_item_GUIDs = {}
for i = 0, num_selected_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  table.insert(selected_item_GUIDs, reaper.BR_GetMediaItemGUID(item))
end

-- Build item_info_list
local item_info_list = {}
for i = 0, num_selected_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then
    local source = reaper.GetMediaItemTake_Source(take)
    local source_num_channels = reaper.GetMediaSourceNumChannels(source)
    local effective_channels = GetEffectiveChannelCount(take, source_num_channels)
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
      effective_channels = effective_channels,
      source_num_channels = source_num_channels
    })
  else
    reaper.ShowMessageBox('No active take or take is MIDI for item at position ' .. reaper.GetMediaItemInfo_Value(item, 'D_POSITION'), 'Error', 0)
  end
end

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
    local source = reaper.GetMediaItemTake_Source(glued_take)
    local effective_channels = GetEffectiveChannelCount(glued_take, reaper.GetMediaSourceNumChannels(source))
    local preset_name = preset_map[effective_channels]
    if preset_name and ApplyRenderPresetByName(preset_name) then
      reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)
      reaper.Main_OnCommand(41824, 0) -- Render
      reaper.Undo_DoUndo2(0) -- Undo glue
    end
  end
end

-- Process non-overlapping items
local items_by_channel_count = {}
for _, info in ipairs(non_overlapping_items) do
  if not items_by_channel_count[info.effective_channels] then
    items_by_channel_count[info.effective_channels] = {}
  end
  table.insert(items_by_channel_count[info.effective_channels], info.item)
end

for effective_channels, items in pairs(items_by_channel_count) do
  local preset_name = preset_map[effective_channels]
  if preset_name and ApplyRenderPresetByName(preset_name) then
    reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)
    reaper.Main_OnCommand(40289, 0) -- Unselect all items
    for _, item in ipairs(items) do
      reaper.SetMediaItemSelected(item, true)
    end
    reaper.Main_OnCommand(41824, 0) -- Render
  end
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
