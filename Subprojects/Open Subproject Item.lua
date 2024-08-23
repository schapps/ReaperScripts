-- @description Open Subproject Item
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   This is a simple script to check if the selected item is a subrproject, and if it is, open it.
-- @link https://www.stephenschappler.com
-- @changelog 
--   8/23/24 - v1.0 - Creating the script

-- Function to check if the selected item is a subproject
function check_and_open_subproject()
    -- Get the selected item
    local item = reaper.GetSelectedMediaItem(0, 0)
    
    -- If no item is selected, exit the script
    if item == nil then
        reaper.ShowMessageBox("No item selected.", "Error", 0)
        return
    end
    
    -- Get the active take from the item
    local take = reaper.GetActiveTake(item)
    
    -- If the take is not valid, exit the script
    if take == nil then
        reaper.ShowMessageBox("No active take found.", "Error", 0)
        return
    end
    
    -- Get the source of the take
    local source = reaper.GetMediaItemTake_Source(take)
    
    -- Get the file name of the source
    local filename = reaper.GetMediaSourceFileName(source, "")
    
    -- Check if the file is a .rpp file (subproject)
    if filename:sub(-4) == ".rpp" then
        -- Run the command to open the subproject
        reaper.Main_OnCommand(40109, 0)  -- 40109 is the ID for "Open subproject"
    else
        reaper.ShowMessageBox("The selected item is not a subproject (.rpp).", "Info", 0)
    end
end

-- Run the function
check_and_open_subproject()

-- Update the Reaper GUI
reaper.UpdateArrange()
