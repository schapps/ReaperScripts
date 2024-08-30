-- @description Rearrange Selected Item Position Based on Color
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Rearrange Selected Item Position Based on Color
-- @link https://www.stephenschappler.com
-- @changelog 
--   8/30/24 v1.0 - Creating the script

function main()
    local item_count = reaper.CountSelectedMediaItems(0)
    if item_count == 0 then return end
    
    local items = {}
    local color_groups = {}
    
    -- Collect items and group them by color
    for i = 0, item_count - 1 do
        local item = reaper.GetSelectedMediaItem(0, i)
        local color = reaper.GetMediaItemInfo_Value(item, "I_CUSTOMCOLOR")
        local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        
        if not color_groups[color] then
            color_groups[color] = {}
        end
        
        table.insert(color_groups[color], {item=item, position=position})
    end
    
    -- Flatten the color groups into a single list, maintaining original order within each color
    local sorted_items = {}
    
    for _, group in pairs(color_groups) do
        -- Sort items within the same color group by their original position
        table.sort(group, function(a, b)
            return a.position < b.position
        end)
        
        -- Add sorted items to the final list
        for _, item_data in ipairs(group) do
            table.insert(sorted_items, item_data.item)
        end
    end
    
    -- Reposition items in order
    local track = reaper.GetMediaItem_Track(sorted_items[1])
    local current_position = reaper.GetMediaItemInfo_Value(sorted_items[1], "D_POSITION")
    
    for _, item in ipairs(sorted_items) do
        reaper.SetMediaItemPosition(item, current_position, false)
        current_position = current_position + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    end
    
    reaper.UpdateArrange()
end

reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Rearrange items by color", -1)
