-- @description Set Project as Quad and Configure Hardware Outputs
-- @author Stephen Schappler
-- @version 1.1
-- @about
--   Set the master track to 4 channels and instantiate 2 pairs of hardware outputs
--   set as 1-2 out 1-2 and 3-4 out 5-6.
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/29/24 v1.0 - Creating the script
--   8/24/24 v1.1 - adding confirmation message for user feedback

function SetMasterTrackChannelsAndOutputs()
    -- Set Master Track channels to 4
    local master_track = reaper.GetMasterTrack(0)
    reaper.SetMediaTrackInfo_Value(master_track, 'I_NCHAN', 4)

    -- Clear existing hardware outputs by deleting all sends
    local send_count = reaper.GetTrackNumSends(master_track, 1)
    for i = send_count-1, 0, -1 do
        reaper.RemoveTrackSend(master_track, 1, i)
    end
    
    -- Add first stereo pair to outputs 1-2
    local hw_send_1 = reaper.CreateTrackSend(master_track, nil)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send_1, 'I_DSTCHAN', 0) -- Output 1-2 (channels 0-1)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send_1, 'I_SRCCHAN', 0) -- Source channels 1/2 (channels 0-1, stereo)

    -- Add second stereo pair to outputs 5-6
    local hw_send_2 = reaper.CreateTrackSend(master_track, nil)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send_2, 'I_DSTCHAN', 4) -- Output 5-6 (channels 4-5)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send_2, 'I_SRCCHAN', 2) -- Source channels 3/4 (channels 2-3, stereo)


    reaper.UpdateArrange() -- Update the REAPER interface

    -- Show confirmation message
    reaper.ShowMessageBox("Project master has been set to quad configuration.", "Configuration Complete", 0)
end

-- Run the script
SetMasterTrackChannelsAndOutputs()