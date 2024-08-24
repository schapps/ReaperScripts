-- @description Tab to Next Transient in Item, Like Pro Tools
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   A script to emulate the tab to transient behavior in Pro Tools
-- @link https://www.stephenschappler.com
-- @changelog 
--   08/23/24 Creating the script

-- Function to tab to the next transient within the selected item
function tab_to_transient_in_item()
    reaper.Main_OnCommand(40375, 0) -- Move edit cursor to next transient in item
end

-- Main function to decide what to do
function main()
    local item = reaper.GetSelectedMediaItem(0, 0)
    
    if item then
        -- Get item end position
        local item_end = reaper.GetMediaItemInfo_Value(item, "D_POSITION") + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local cur_pos = reaper.GetCursorPosition()

        -- If the cursor is at or past the end of the item, move to the next item
        if cur_pos >= item_end then
            reaper.SetMediaItemSelected(item, false) -- Deselect current item
            reaper.Main_OnCommand(40417, 0) -- Move to next item and select it
        else
            tab_to_transient_in_item()
        end
    else
        reaper.Main_OnCommand(40417, 0) -- Move to next item and select it
    end
end

-- Run the main function
main()
