-- @description Solo Selected Media Items, Set Time Selection, and Play, Unsolo on Stop
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Solo items selected items and plays them. Will respect repeat setting.
-- @link https://www.stephenschappler.com
-- @changelog 
--   07/29/24 v1.0 - Creating the script
--   08/02/24 v1.1 - Making it smarter

function msg(m)
    reaper.ShowConsoleMsg(tostring(m) .. "\n")
  end
  
  -- Save the current edit cursor position
  local start_pos = reaper.GetCursorPosition()
  
  -- Get the selected media items
  local selected_items = {}
  local num_selected_items = reaper.CountSelectedMediaItems(0)
  for i = 0, num_selected_items - 1 do
    selected_items[#selected_items + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  
  -- Function to solo and unsolo media items
  local function SoloItems(solo)
    for _, item in ipairs(selected_items) do
      local take = reaper.GetActiveTake(item)
      if take then
        reaper.SetMediaItemSelected(item, solo)
        local track = reaper.GetMediaItem_Track(item)
        reaper.SetMediaTrackInfo_Value(track, "I_SOLO", solo and 1 or 0)
      end
    end
  end
  
  -- Function to unsolo media items after a delay
  local function UnsoloItemsAfterDelay()
    reaper.defer(function()
      SoloItems(false)
      reaper.GetSet_LoopTimeRange(true, false, 0, 0, false) -- Clear time selection
    end)
  end
  
  -- Function to stop playback at the end of the time selection
  local function StopAtTimeSelectionEnd(end_time)
    if reaper.GetPlayState() == 0 then -- 0 means stopped
      reaper.defer(UnsoloItemsAfterDelay) -- Unsolo after delay
      return -- Stop the deferred function
    end
  
    if reaper.GetPlayPosition() >= end_time then
      reaper.OnStopButton()
      reaper.defer(UnsoloItemsAfterDelay) -- Unsolo after delay
      return -- Stop the deferred function
    end
  
    reaper.defer(function() StopAtTimeSelectionEnd(end_time) end) -- Continuously defer the function to check for stop state
  end
  
  -- Ensure "Transport: Toggle stop playback at end of loop if repeat is disabled" option is on
  local repeat_off_stop_on = reaper.GetToggleCommandState(41834) == 1
  if not repeat_off_stop_on then
    reaper.Main_OnCommand(41834, 0)
  end
  
  -- Find the earliest and latest selected media items to set the time selection
  if #selected_items > 0 then
    local earliest_start_pos = reaper.GetMediaItemInfo_Value(selected_items[1], "D_POSITION")
    local latest_end_pos = earliest_start_pos + reaper.GetMediaItemInfo_Value(selected_items[1], "D_LENGTH")
    
    for _, item in ipairs(selected_items) do
      local item_start_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end_pos = item_start_pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      
      if item_start_pos < earliest_start_pos then
        earliest_start_pos = item_start_pos
      end
      
      if item_end_pos > latest_end_pos then
        latest_end_pos = item_end_pos
      end
    end
    
    reaper.SetEditCurPos(earliest_start_pos, false, false)
    reaper.GetSet_LoopTimeRange(true, false, earliest_start_pos, latest_end_pos, false)
  end
  
  -- Solo the selected items
  SoloItems(true)
  
  -- Start playback
  reaper.OnPlayButton()
  
  -- Defer the stop function to check for the end of the time selection
  if #selected_items > 0 then
    local latest_end_pos = reaper.GetMediaItemInfo_Value(selected_items[1], "D_POSITION") + reaper.GetMediaItemInfo_Value(selected_items[1], "D_LENGTH")
    
    for _, item in ipairs(selected_items) do
      local item_end_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION") + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      
      if item_end_pos > latest_end_pos then
        latest_end_pos = item_end_pos
      end
    end
  
    reaper.defer(function() StopAtTimeSelectionEnd(latest_end_pos) end)
  end
  