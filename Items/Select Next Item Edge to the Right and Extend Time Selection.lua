-- @description Select Next Item Edge to the Right and Extend Time Selection
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Select Next Item Edge to the Right and Extend Time Selection
-- @link https://www.stephenschappler.com
-- @changelog 
--   9/27/24 v1.0 - Creating the script with Kei's help :)
--   9/27/24 v1.1 - I am dumn and uploaded the wrong version. Fixed.

-- Get the current edit cursor position
local current_pos = reaper.GetCursorPosition()
local old_cursor_pos = current_pos

-- Initialize the next edge position to a large number
local next_edge_pos = math.huge

-- Get the total number of tracks
local track_count = reaper.CountTracks(0)

-- Loop through all tracks and their media items
for i = 0, track_count - 1 do
    local track = reaper.GetTrack(0, i)
    local item_count = reaper.CountTrackMediaItems(track)
    for j = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, j)
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local item_end = item_start + item_length

        -- Check for the nearest item start position to the right
        if item_start > current_pos and item_start < next_edge_pos then
            next_edge_pos = item_start
        end
        -- Check for the nearest item end position to the right
        if item_end > current_pos and item_end < next_edge_pos then
            next_edge_pos = item_end
        end
    end
end

-- Move the edit cursor if a media item edge is found
if next_edge_pos ~= math.huge then
    reaper.SetEditCurPos(next_edge_pos, true, false)
    new_cursor_pos = next_edge_pos
else
    --reaper.ShowMessageBox("No media item edge found to the right.", "Notice", 0)
    return
end

-- Get the current time selection
local start_time_sel, end_time_sel = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)

-- Adjust the time selection based on whether it exists
if start_time_sel == end_time_sel then
    -- No time selection exists; create one from old to new cursor position
    local new_start = math.min(old_cursor_pos, new_cursor_pos)
    local new_end = math.max(old_cursor_pos, new_cursor_pos)
    reaper.GetSet_LoopTimeRange(true, false, new_start, new_end, false)
else
    -- Time selection exists; extend it to the new cursor position
    local new_start = math.min(start_time_sel, new_cursor_pos)
    local new_end = math.max(end_time_sel, new_cursor_pos)
    reaper.GetSet_LoopTimeRange(true, false, new_start, new_end, false)
end

-- Update the arrangement view
reaper.UpdateArrange()
