-- @description Find and Select All Items Based on Color
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Define the color to match (example: green)
--   Colors in Reaper are in BGR format (0xRRGGBB)
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/29/24 Creating the script


local targetColor = 0x1387A24  -- Green

-- Function to check if the item's color matches the target color
local function isColorMatch(item, targetColor)
    local itemColor = reaper.GetDisplayedMediaItemColor(item)
    return itemColor == targetColor
end

-- Iterate through all items in the project
local itemCount = reaper.CountMediaItems(0)
for i = 0, itemCount - 1 do
    local item = reaper.GetMediaItem(0, i)
    if isColorMatch(item, targetColor) then
        -- Select the item if the color matches
        reaper.SetMediaItemSelected(item, true)
    end
end

-- Update the arrangement view
reaper.UpdateArrange()
