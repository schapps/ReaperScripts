-- @description Color Subproject Items
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   This is a simple script to find subproject items in your project and color them a specific color.
--   If you want to change the color used, scroll down and edit the RGB values after reaper.ColorToNatives.
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/29/24 Creating the script

-- Function to check if a string contains a substring
function containsString(str, substr)
    return string.find(str, substr, 1, true) ~= nil
end

-- Main function
function main()
    reaper.Undo_BeginBlock() -- Begin undo block

    local item_count = reaper.CountMediaItems(0) -- Get the number of items in the project

    -- Create a table to store the selected items
    local selected_items = {}

    -- Iterate through each item in the project
    for i = 0, item_count - 1 do
        local item = reaper.GetMediaItem(0, i) -- Get the current item

        local take_count = reaper.CountTakes(item) -- Get the number of takes in the item

        -- Iterate through each take in the item
        for j = 0, take_count - 1 do
            local take = reaper.GetTake(item, j) -- Get the current take

            local source = reaper.GetMediaItemTake_Source(take) -- Get the media source of the take
            local source_filename = reaper.GetMediaSourceFileName(source, "") -- Get the filename of the media source

            -- Check if the media source filename contains ".rpp"
            if containsString(source_filename, ".rpp") then
                selected_items[#selected_items + 1] = item -- Add the item to the selected items table
                break -- Exit the loop after finding a matching take
            end
        end
    end

    -- Select and color the items in the selected_items table
    for _, item in ipairs(selected_items) do
        reaper.SetMediaItemSelected(item, true)

        -- Set the color of the item here in RGB values.
        reaper.SetMediaItemInfo_Value(item, "I_CUSTOMCOLOR", reaper.ColorToNative(161, 145, 227) | 0x01000000)
    end

    reaper.UpdateArrange() -- Update the arrangement

    reaper.Undo_EndBlock("Select and color items with '.rpp' in take media source", -1) -- End undo block
end

-- Run the main function
main()
