-- @description Copy File Name of Selected Item to Clipboard
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Copies the file name of the selected item to the clipboard. 
--   Santizes the name if there is a long number string at the end. You can comment out that feature below if you want.
-- @link https://www.stephenschappler.com
-- @changelog 
--   12/23/24 - v 1.0 - adding the script

-- Get the first selected item
local item = reaper.GetSelectedMediaItem(0, 0)

if item then
    -- Get the active take from the selected item
    local take = reaper.GetActiveTake(item)

    if take and not reaper.TakeIsMIDI(take) then
        -- Get the source of the take
        local source = reaper.GetMediaItemTake_Source(take)

        -- Get the file name of the source
        local file_path = reaper.GetMediaSourceFileName(source, "")

        if file_path and file_path ~= "" then
            -- Extract the file name without the extension
            local file_name = file_path:match("([^\\/]+)$"):gsub("%.%w+$", "")

            if file_name then
                -- Remove "_<long_number>" patterns
                local sanitized_name = file_name:gsub("_[%d]+$", function(match)
                    return #match > 3 and "" or match -- Only remove if more than two digits
                end)

                -- Copy the sanitized file name to the clipboard
                reaper.CF_SetClipboard(sanitized_name)
                --reaper.ShowMessageBox("File name copied to clipboard:\n" .. sanitized_name, "Success", 0)
            else
                reaper.ShowMessageBox("Could not extract file name.", "Error", 0)
            end
        else
            reaper.ShowMessageBox("Could not retrieve file name.", "Error", 0)
        end
    else
        reaper.ShowMessageBox("Selected item has no valid audio take.", "Error", 0)
    end
else
    reaper.ShowMessageBox("No item selected.", "Error", 0)
end
