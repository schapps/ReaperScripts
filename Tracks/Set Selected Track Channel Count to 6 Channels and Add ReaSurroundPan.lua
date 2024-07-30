-- @description Set Selected Track Channel Count to 6 Channels and Add ReaSurroundPan
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Sets the selected tracks channel count to 6 and adds ReaSurroundPan. 
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/29/24 Creating the script

-- Function to execute a command
function runCommand(commandID)
    reaper.Main_OnCommand(commandID, 0) -- 0 is to use the main section
end

function setTracksToSixChannelsAndAddReaSurround()
    -- Get the current project
    local proj = 0 -- 0 is the current project

    -- Get the number of selected tracks
    local numSelectedTracks = reaper.CountSelectedTracks(proj)

    if numSelectedTracks == 0 then
        -- If no tracks are selected, show a message box
        reaper.ShowMessageBox("No tracks are selected.", "Error", 0)
        return
    end

    -- Begin an undo block to allow for a single undo operation
    reaper.Undo_BeginBlock()

    -- Iterate over all selected tracks
    for i = 0, numSelectedTracks - 1 do
        -- Get the current selected track (0-indexed)
        local track = reaper.GetSelectedTrack(proj, i)

        -- Set the track's number of channels to 6
        reaper.SetMediaTrackInfo_Value(track, "I_NCHAN", 6)
        
        -- Add ReaSurroundPan FX to the track
        -- TrackFX_AddByName returns the index of the FX if it's added, or -1 if it's not
        local fxIndex = reaper.TrackFX_AddByName(track, "ReaSurroundPan", false, -1)

        -- Check if the FX was added successfullys
        if fxIndex == -1 then
            reaper.ShowMessageBox("ReaSurround could not be added to the track.", "Error", 0)
        end
        
        --Embed UI in MCP
        --runCommand(42372)
        
    end

    -- End the undo block
    reaper.Undo_EndBlock("Set selected tracks to six channels and add ReaSurround", -1)
end

-- Call the function
setTracksToSixChannelsAndAddReaSurround()
