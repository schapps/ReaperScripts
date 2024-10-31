-- @description Find and Select Items by Name on Selected Tracks
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Find and Select Items by Name on Selected Tracks
-- @link https://www.stephenschappler.com
-- @changelog 
--   10/31/24 - v1.0 - Creating the script

-- Prompt for the search string
local retval, search_string = reaper.GetUserInputs("Search Items by Name", 1, "Enter search string:", "")
if not retval or search_string == "" then return end

-- Start undo block
reaper.Undo_BeginBlock()

-- Deselect all items
reaper.Main_OnCommand(40289, 0)  -- Unselect all items

-- Loop through each selected track
local track_count = reaper.CountSelectedTracks(0)
for t = 0, track_count - 1 do
    local track = reaper.GetSelectedTrack(0, t)

    -- Iterate over all items on the current track
    local item_count = reaper.CountTrackMediaItems(track)
    for i = 0, item_count - 1 do
        local item = reaper.GetTrackMediaItem(track, i)
        local take = reaper.GetMediaItemTake(item, 0) -- Assume first take if there are multiple
        if take then
            local item_name = reaper.GetTakeName(take)
            if item_name:find(search_string) then
                reaper.SetMediaItemSelected(item, true)
            end
        end
    end
end

-- Update the selection in the UI
reaper.UpdateArrange()

-- End undo block
reaper.Undo_EndBlock("Select Items by Name on Selected Tracks", -1)
