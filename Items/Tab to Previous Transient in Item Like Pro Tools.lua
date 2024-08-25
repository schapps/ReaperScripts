-- @description Tab to Previous Transient in Item, Like Pro Tools
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   A script to emulate the tab to transient behavior in Pro Tools
-- @link https://www.stephenschappler.com
-- @changelog 
--   08/23/24 Creating the script

-- Function to move to the previous transient within the selected item
function tab_to_previous_transient_in_item()
    reaper.Main_OnCommand(40376, 0) -- Move edit cursor to previous transient in item
end

-- Main function to decide what to do
function main()
    local item = reaper.GetSelectedMediaItem(0, 0)
    
    if item then
        -- Get item start position
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local cur_pos = reaper.GetCursorPosition()

        -- If the cursor is at or before the start of the item, move to the previous item
        if cur_pos <= item_start then
            reaper.SetMediaItemSelected(item, false) -- Deselect current item
            reaper.Main_OnCommand(40416, 0) -- Move to previous item and select it
            reaper.Main_OnCommand(40319, 0) -- Move cursor to right edge of item
        else
            tab_to_previous_transient_in_item()
        end
    else
        reaper.Main_OnCommand(40416, 0) -- Move to previous item and select it
        reaper.Main_OnCommand(40319, 0) -- Move cursor to right edge of item
    end
end

-- Run the main function
main()
