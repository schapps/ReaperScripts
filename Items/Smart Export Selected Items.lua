-- @description Smart Export Selected Items
-- @version 1.3
-- @about
--[[
Smart Render Selected Items Based on Channel Count (Optimized for Group Rendering with Overlapping Items Handling)

This script renders selected media items by grouping them based on their effective channel count and rendering each group together. It also handles overlapping items with the same name by gluing them temporarily for rendering.

Configuration:
- Map effective channel counts to action IDs (commands) that load the desired render preset.

Usage:
- Modify the action_map to include your own action IDs for each channel count.
- Select the media items you want to render.
- Run this script.

--]]
-- @author
--   Original script by Stephen Schappler
--   Modified by OpenAI's ChatGPT
-- @link https://www.stephenschappler.com
-- @changelog
--   11/21/24 v1.0 - Creating the script
--   11/21/24 v1.3 - Added handling of overlapping items with the same name
--   11/21/24 v1.4 - Fixed error with restoring item selection after glue and undo

-- Clear the console at the start
reaper.ClearConsole()

-- CONFIGURATION AREA
-- Map effective channel counts to action command IDs (as strings, with '_RS' prefix if custom script)
local action_map = {
  [1] = "_RS3154aeded5c31a0a90efc4be8d02d8ad70e2daa2", -- Action ID to load desired Mono render preset
  [2] = "_RSc31d9877f7d3502eac942c63df7e057a163dd74e", -- Action ID to load desired Stereo render preset
  [4] = "_RSb8bd74b8ebb0ae6acdee310785d2c8bc143e137d", -- Action ID to load desired Quad render preset
  [6] = "_RS1829513b44371fd5d962ebf7a717d96b569689cb"  -- Action ID to load desired Surround render preset
}

-- END OF CONFIGURATION

-- Function to map I_CHANMODE to effective channel count
local function GetEffectiveChannelCount(take, source_num_channels)
  local chan_mode = reaper.GetMediaItemTakeInfo_Value(take, 'I_CHANMODE')
  local effective_channels = source_num_channels -- Default to source channels

  if chan_mode == 0 then
    -- Normal mode, use source number of channels
    effective_channels = source_num_channels
  elseif chan_mode >= 1 and chan_mode <= 3 then
    -- Mono modes
    effective_channels = 1
  elseif chan_mode >= 65 and chan_mode <= 71 then
    -- Mono modes for channels beyond 2 (channels 3 to 8)
    effective_channels = 1
  elseif chan_mode == 4 then
    -- Reverse stereo
    effective_channels = 2
  else
    -- Other modes (e.g., left/right to stereo)
    effective_channels = source_num_channels
  end

  return effective_channels
end

-- Function to run an action by command ID
local function RunActionByID(cmdID)
  if not cmdID then
    reaper.ShowMessageBox('No action ID provided.', 'Error', 0)
    return
  end

  local original_cmdID = cmdID  -- Save for debugging

  if type(cmdID) == 'string' then
    if cmdID:sub(1, 1) == '_' then
      local new_cmdID = reaper.NamedCommandLookup(cmdID)
      if new_cmdID == 0 then
        reaper.ShowMessageBox('Named command not found: ' .. cmdID, 'Error', 0)
        return
      else
        cmdID = new_cmdID
      end
    else
      cmdID = tonumber(cmdID)
      if not cmdID then
        reaper.ShowMessageBox('Invalid action ID string: ' .. original_cmdID, 'Error', 0)
        return
      end
    end
  end

  if cmdID and cmdID > 0 then
    reaper.Main_OnCommand(cmdID, 0)
  else
    reaper.ShowMessageBox('Invalid action ID after lookup: ' .. tostring(cmdID), 'Error', 0)
  end
end

-- Save current project render settings
local _, original_cfg = reaper.GetSetProjectInfo_String(0, 'RENDER_CFG', '', false)

-- Get the total number of selected media items
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
  local GUID = reaper.BR_GetMediaItemGUID(item)
  selected_item_GUIDs[#selected_item_GUIDs + 1] = GUID
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
    -- Store item info
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

-- Build items_by_name mapping name to list of items
local items_by_name = {}
for _, info in ipairs(item_info_list) do
  local name = info.name or ""
  if not items_by_name[name] then
    items_by_name[name] = {}
  end
  table.insert(items_by_name[name], info)
end

-- Build list of overlapping item groups and non-overlapping items
local overlapping_groups = {}
local non_overlapping_items = {}

for name, items in pairs(items_by_name) do
  if #items > 1 then
    -- Multiple items with the same name
    -- Check for overlapping items
    local checked = {}
    for i = 1, #items do
      local item_i = items[i]
      if not checked[item_i] then
        local group = {item_i}
        checked[item_i] = true
        for j = i + 1, #items do
          local item_j = items[j]
          if not checked[item_j] then
            -- Check if items overlap
            if (item_i.start_pos < item_j.end_pos) and (item_j.start_pos < item_i.end_pos) then
              -- Items overlap
              table.insert(group, item_j)
              checked[item_j] = true
            end
          end
        end
        if #group > 1 then
          -- Found overlapping items with the same name
          table.insert(overlapping_groups, group)
        else
          -- Single item, not overlapping with others
          table.insert(non_overlapping_items, item_i)
        end
      end
    end
  else
    -- Only one item with this name
    table.insert(non_overlapping_items, items[1])
  end
end

-- Process glued items
for _, group in ipairs(overlapping_groups) do
  -- Begin undo block for glue and render
  reaper.Undo_BeginBlock()
  -- Select the items in the group
  reaper.Main_OnCommand(40289, 0) -- Unselect all items
  for _, info in ipairs(group) do
    reaper.SetMediaItemSelected(info.item, true)
  end
  -- Glue items
  reaper.Main_OnCommand(41588, 0) -- Item: Glue items
  -- Get the new glued item
  local glued_item = reaper.GetSelectedMediaItem(0, 0)
  if glued_item then
    local glued_take = reaper.GetActiveTake(glued_item)
    local group_name = group[1].name -- Assuming all items have the same name
    reaper.GetSetMediaItemTakeInfo_String(glued_take, "P_NAME", group_name, true)
    local source = reaper.GetMediaItemTake_Source(glued_take)
    local source_num_channels = reaper.GetMediaSourceNumChannels(source)
    local effective_channels = GetEffectiveChannelCount(glued_take, source_num_channels)
    local action_id = action_map[effective_channels]
    if action_id then
      -- Run the action to load the render preset
      RunActionByID(action_id)

      -- Set render bounds to selected media items
      reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)

      -- Ensure only the glued item is selected
      reaper.Main_OnCommand(40289, 0) -- Unselect all items
      reaper.SetMediaItemSelected(glued_item, true)

      -- Render the item
      reaper.Main_OnCommand(41824, 0) -- File: Render project, using the most recent render settings, auto-close render dialog

      -- Undo the glue action
      reaper.Undo_EndBlock("Glue and Render", -1)
      reaper.Undo_DoUndo2(0)
    else
      reaper.ShowMessageBox('No action defined for effective channel count: ' .. effective_channels, 'Error', 0)
      reaper.Undo_EndBlock("Glue and Render", -1)
    end
  else
    reaper.ShowMessageBox('Failed to glue items for ' .. group_name, 'Error', 0)
    reaper.Undo_EndBlock("Glue and Render", -1)
  end
end

-- Build items_by_channel_count for non-glued items
local items_by_channel_count = {}

for _, info in ipairs(non_overlapping_items) do
  local effective_channels = info.effective_channels
  if not items_by_channel_count[effective_channels] then
    items_by_channel_count[effective_channels] = {}
  end
  table.insert(items_by_channel_count[effective_channels], info.item)
end

-- Now, for each channel count, process the items
for effective_channels, items in pairs(items_by_channel_count) do
  local action_id = action_map[effective_channels]
  if action_id then
    -- Run the action to load the render preset
    RunActionByID(action_id)

    -- Set render bounds to selected media items
    reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)

    -- Temporarily select only these items
    reaper.Main_OnCommand(40289, 0) -- Unselect all items
    for _, item in ipairs(items) do
      reaper.SetMediaItemSelected(item, true)
    end

    -- Render the items
    reaper.Main_OnCommand(41824, 0) -- File: Render project, using the most recent render settings, auto-close render dialog
  else
    reaper.ShowMessageBox('No action defined for effective channel count: ' .. effective_channels, 'Error', 0)
  end
end

-- Restore the original item selection using GUIDs
reaper.Main_OnCommand(40289, 0) -- Unselect all items
for _, GUID in ipairs(selected_item_GUIDs) do
  local item = reaper.BR_GetMediaItemByGUID(0, GUID)
  if item then
    reaper.SetMediaItemSelected(item, true)
  end
end

-- Restore original render settings
reaper.GetSetProjectInfo_String(0, 'RENDER_CFG', original_cfg, true)

-- Update Arrange
reaper.UpdateArrange()

-- End undo block
reaper.Undo_EndBlock('Smart Render Selected Items', -1)
