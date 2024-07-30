-- @description Play at Half Speed and Reset Playrate on Stop
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Play at Half Speed and Reset Playrate on Stop
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/30/24 Creating the script

function play_half_speed()
    -- Set the playrate to 0.5
    reaper.CSurf_OnPlayRateChange(0.5)
    
    -- Start playback
    reaper.OnPlayButton()
  end
  
  function reset_playrate_on_stop()
    -- Check if playback is stopped
    if reaper.GetPlayState() == 0 then -- 0 means stopped
      -- Reset the playrate to 1.0
      reaper.CSurf_OnPlayRateChange(1.0)
       
      -- Stop the deferred function
      return
    end
    
    -- Continuously defer the function to check for stop state
    reaper.defer(reset_playrate_on_stop)
  end
  
  -- Main function
  reaper.Undo_BeginBlock() -- Begin the undo block
  play_half_speed()
  reaper.defer(reset_playrate_on_stop) -- Defer the reset function
  reaper.Undo_EndBlock("Play at Half Speed and Reset Playrate on Stop", -1) -- End the undo block
  reaper.UpdateArrange() -- Update the arrangement view
  