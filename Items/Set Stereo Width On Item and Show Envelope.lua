-- @description Set Stereo Width On Item and Show Envelope
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Set Stereo Width On Item and Show Envelope
-- @link https://www.stephenschappler.com
-- @changelog 
--   9/3/24 v1.0 - Creating the script

function main()
    -- Get the number of selected media items
    local numItems = reaper.CountSelectedMediaItems(0)
    if numItems == 0 then return end

    for i = 0, numItems - 1 do
        -- Get the selected media item
        local item = reaper.GetSelectedMediaItem(0, i)
        if not item then goto continue end

        -- Get the take in the media item
        local take = reaper.GetActiveTake(item)
        if not take or reaper.TakeIsMIDI(take) then goto continue end

        -- Add the JS plugin to the take
        local fxIndex = reaper.TakeFX_AddByName(take, "Adjustable Stereo Width", -1)
        if fxIndex == -1 then goto continue end

        -- Hide the floating FX window by closing all possible FX windows for the take
        reaper.TakeFX_Show(take, fxIndex, 2) -- 2 ensures all FX windows for this take are closed

        -- Try to directly set the envelope visible for the FX parameter (Stereo Width %)
        local paramIndex = 0 -- Assuming 'Stereo Width %' is the first parameter
        reaper.TakeFX_GetEnvelope(take, fxIndex, paramIndex, true)

        ::continue::
    end

    reaper.UpdateArrange() -- Update the arrangement view
end

reaper.Undo_BeginBlock() -- Begin undo block
main()
reaper.Undo_EndBlock("Apply Simple Stereo Width Control Plugin for Selected Items", -1) -- End undo block
