-- @description Smart Export Selected Items
-- @version 1.2
-- @about
--[[
Smart Render Selected Items Based on Channel Count (Optimized for Group Rendering)

This script renders selected media items by grouping them based on their effective channel count and rendering each group together. The effective channel count is determined by the take's channel mode.

Configuration:
- Map effective channel counts to action IDs (commands) that load the desired render preset.

Usage:
- Modify the action_map to include your own action IDs for each channel count.
- Select the media items you want to render.
- Run this script.

--]]
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @changelog 
--   11/21/24 v1.0 - Creating the script

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

-- Store the original item selection
local selected_items = {}
for i = 0, num_selected_items - 1 do
  local item = reaper.GetSelectedMediaItem(0, i)
  selected_items[#selected_items + 1] = item
end

-- Build a table of items grouped by effective channel count
local items_by_channel_count = {}

for _, item in ipairs(selected_items) do
  local take = reaper.GetActiveTake(item)
  if take and not reaper.TakeIsMIDI(take) then
    local source = reaper.GetMediaItemTake_Source(take)
    local source_num_channels = reaper.GetMediaSourceNumChannels(source)
    local effective_channels = GetEffectiveChannelCount(take, source_num_channels)
    -- Add item to the list for this channel count
    if not items_by_channel_count[effective_channels] then
      items_by_channel_count[effective_channels] = {}
    end
    table.insert(items_by_channel_count[effective_channels], item)
  else
    reaper.ShowMessageBox('No active take or take is MIDI for item at position ' .. reaper.GetMediaItemInfo_Value(item, 'D_POSITION'), 'Error', 0)
  end
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

-- Restore the original item selection
reaper.Main_OnCommand(40289, 0) -- Unselect all items
for _, item in ipairs(selected_items) do
  reaper.SetMediaItemSelected(item, true)
end

-- End undo block
reaper.Undo_EndBlock('Smart Render Selected Items', -1)
