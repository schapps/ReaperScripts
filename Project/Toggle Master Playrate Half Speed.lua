-- @description Toggle Master Playrate Half Speed
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Toggles the master playrate between 1.0 and 0.5 speed
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/30/24 Creating the script

function toggle_playrate()
    -- Get the current playrate
    local current_playrate = reaper.Master_GetPlayRate(0)
    
    -- Determine the new playrate
    local new_playrate
    if current_playrate == 1.0 then
      new_playrate = 0.5
    else
      new_playrate = 1.0
    end
  
    -- Set the new playrate
    reaper.CSurf_OnPlayRateChange(new_playrate)
  end
  
  -- Main function
  reaper.Undo_BeginBlock() -- Begin the undo block
  toggle_playrate()
  reaper.Undo_EndBlock("Toggle Master Playrate between 1.0 and 0.5", -1) -- End the undo block
  reaper.UpdateArrange() -- Update the arrangement view
  