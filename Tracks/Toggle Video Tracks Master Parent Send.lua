-- @description Toggle Video Tracks Master Parent Send
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Toggle Master Parent Send for Tracks Containing "video" in the Name 
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/30/24 Creating the script

-- Get the number of tracks in the project
local track_count = reaper.CountTracks(0)

-- Loop through each track
for i = 0, track_count - 1 do
    -- Get the track at the current index
    local track = reaper.GetTrack(0, i)
    
    -- Get the track name
    local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    
    -- Check if the track name contains "video" (case insensitive)
    if track_name:lower():find("video") then
        -- Get the current master parent send state
        local master_parent_send = reaper.GetMediaTrackInfo_Value(track, "B_MAINSEND")
        
        -- Toggle the master parent send state
        local new_master_parent_send = (master_parent_send == 1) and 0 or 1
        reaper.SetMediaTrackInfo_Value(track, "B_MAINSEND", new_master_parent_send)
    end
end

-- Update the Reaper UI
reaper.UpdateArrange()
