-- @description Set Project as Surround and Configure Hardware Outputs
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Set the master track to 6 channels and instantiate 3 pairs of hardware outputs set to 1-6 out 1-6
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/29/24 Creating the script

function SetMasterToSixChannelsAndRouteToHardwareOutputs()
    -- Set Master Track channels to 6
    local master_track = reaper.GetMasterTrack(0)
    reaper.SetMediaTrackInfo_Value(master_track, 'I_NCHAN', 6)

    -- Clear existing hardware outputs by deleting all sends
    local send_count = reaper.GetTrackNumSends(master_track, 1)
    for i = send_count-1, 0, -1 do
        reaper.RemoveTrackSend(master_track, 1, i)
    end
    
    -- Add multichannel hardware output for channels 1-6
    local hw_send = reaper.CreateTrackSend(master_track, nil)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send, 'I_DSTCHAN', 0) -- Output 1 (channels 0-5 for multichannel)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send, 'I_SRCCHAN', 0) -- Source channels 1/2 (channels 0-1, stereo)
    
    -- Add second stereo pair to outputs 3-4
    local hw_send_2 = reaper.CreateTrackSend(master_track, nil)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send_2, 'I_DSTCHAN', 2) -- Output 5-6 (channels 4-5)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send_2, 'I_SRCCHAN', 2) -- Source channels 3/4 (channels 2-3, stereo)
    
    -- Add third stereo pair to outputs 5-6
    local hw_send_2 = reaper.CreateTrackSend(master_track, nil)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send_2, 'I_DSTCHAN', 4) -- Output 5-6 (channels 4-5)
    reaper.SetTrackSendInfo_Value(master_track, 1, hw_send_2, 'I_SRCCHAN', 4) -- Source channels 5/6 (channels 4-5, stereo)

    reaper.UpdateArrange() -- Update the REAPER interface
end

-- Run the script
SetMasterToSixChannelsAndRouteToHardwareOutputs()