-- @description Insert Marker at Start of Selected Items
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Insert Marker at Start of Selected Items
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/30/24 Creating the script

function main()
    -- Get the number of selected items
    local num_items = reaper.CountSelectedMediaItems(0)
    
    -- Loop through each selected item
    for i = 0, num_items - 1 do
      -- Get the media item
      local item = reaper.GetSelectedMediaItem(0, i)
      
      -- Get the position of the item
      local position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      
      -- Add a project marker at the item's position with a blank name
      reaper.AddProjectMarker(0, false, position, 0, "", -1)
    end
  end
  
  -- Begin the undo block
  reaper.Undo_BeginBlock()
  
  -- Execute the main function
  main()
  
  -- End the undo block
  reaper.Undo_EndBlock("Add project marker at start of selected items with blank name", -1)
  
  -- Update the arrange view
  reaper.UpdateArrange()
  