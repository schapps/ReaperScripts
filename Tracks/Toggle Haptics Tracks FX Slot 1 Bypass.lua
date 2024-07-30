-- @description Toggle Haptics Tracks FX Slot 1 Bypass
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Toggle FX Slot 1 Bypass for Tracks Containing "haptics" in the name. 
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
    
    -- Check if the track name contains "haptics" (case insensitive)
    if track_name:lower():find("haptics") then
        -- Get the current bypass state of FX slot 1 (FX index 0)
        local fx_bypass = reaper.TrackFX_GetEnabled(track, 0)
        
        -- Toggle the bypass state
        reaper.TrackFX_SetEnabled(track, 0, not fx_bypass)
    end
end

-- Update the Reaper UI
reaper.UpdateArrange()
