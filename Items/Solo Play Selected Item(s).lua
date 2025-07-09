-- @description Solo Selected Media Items, Set Time Selection, and Play, Unsolo on Stop
-- @version 1.3
-- @about
--   Solo selected media items, set time selection to their range, play them, and unsolo when playback stops
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @changelog 
--   07/29/24 v1.0 - Creating the script
--   08/02/24 v1.1 - Making it smarter
--   08/02/24 v1.2 - Save and restore cursor and timeline selection and keep selected items selected on stop
--   07/09/25 v1.3 - Preserve user's "Stop at loop end" transport preference

-- Save the current edit cursor position and time selection
local start_pos = reaper.GetCursorPosition()
local time_sel_start, time_sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

-- Get the selected media items
local selected_items = {}
local num_selected_items = reaper.CountSelectedMediaItems(0)
for i = 0, num_selected_items - 1 do
    selected_items[#selected_items + 1] = reaper.GetSelectedMediaItem(0, i)
end

-- === Handle "Stop playback at end of loop if repeat is disabled" setting ===
local stop_at_loop_cmd = 41834
local original_stop_at_loop_setting = reaper.GetToggleCommandState(stop_at_loop_cmd)

-- Enable the setting if not already on
if original_stop_at_loop_setting ~= 1 then
    reaper.Main_OnCommand(stop_at_loop_cmd, 0)
end

-- Function to solo and unsolo media items
local function SoloItems(solo)
    for _, item in ipairs(selected_items) do
        local take = reaper.GetActiveTake(item)
        if take then
            local track = reaper.GetMediaItem_Track(item)
            reaper.SetMediaTrackInfo_Value(track, "I_SOLO", solo and 1 or 0)
        end
    end
end

-- Function to unsolo media items and restore state after delay
local function UnsoloItemsAfterDelay()
    reaper.defer(function()
        SoloItems(false)

        -- Restore time selection and cursor
        reaper.GetSet_LoopTimeRange(true, false, time_sel_start, time_sel_end, false)
        reaper.SetEditCurPos(start_pos, false, false)

        -- === Restore "Stop playback at end of loop if repeat is disabled" setting ===
        if reaper.GetToggleCommandState(stop_at_loop_cmd) ~= original_stop_at_loop_setting then
            reaper.Main_OnCommand(stop_at_loop_cmd, 0)
        end
    end)
end

-- Function to stop playback at the end of the time selection
local function StopAtTimeSelectionEnd(end_time)
    if reaper.GetPlayState() == 0 then
        reaper.defer(UnsoloItemsAfterDelay)
        return
    end

    if reaper.GetPlayPosition() >= end_time then
        reaper.OnStopButton()
        reaper.defer(UnsoloItemsAfterDelay)
        return
    end

    reaper.defer(function() StopAtTimeSelectionEnd(end_time) end)
end

-- Set time selection from selected items
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

-- Defer stop-checking function
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
