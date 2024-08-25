-- @description Track Visibility, Show Only Selected Tracks and Video Tracks
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Will only show selected tracks (plus their children), and video tracks
-- @link https://www.stephenschappler.com
-- @changelog 
--   8/23/24 Creating the script

function hide_all_except_selected_and_video()
    local num_tracks = reaper.CountTracks(0)
    
    if num_tracks == 0 then return end
    
    --Select all children of folder tracks
    reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_SELCHILDREN2"), 0)
    
    -- Iterate through all tracks
    for i = 0, num_tracks - 1 do
        local track = reaper.GetTrack(0, i)
        local track_name_ret, track_name = reaper.GetTrackName(track)
        local selected = reaper.IsTrackSelected(track)
        
        -- Check if track name contains "video" (case insensitive)
        local is_video_track = string.match(string.lower(track_name), "video")

        if selected or is_video_track then
            -- If the track is selected or contains "video", unhide it
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 1)
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 1)
        else
            -- If the track is not selected and doesn't contain "video", hide it
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINMIXER", 0)
            reaper.SetMediaTrackInfo_Value(track, "B_SHOWINTCP", 0)
        end

    end

    -- Force Reaper to update the arrange view
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
end

-- Run the function
reaper.Undo_BeginBlock()
reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_SAVESEL"), 0) --Save track selection
hide_all_except_selected_and_video() -- Main function
reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_RESTORESEL"), 0) --Restore track selection
reaper.Undo_EndBlock("Hide all tracks except selected and video tracks", -1)
