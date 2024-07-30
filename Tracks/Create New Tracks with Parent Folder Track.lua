-- @description Create New Tracks with Parent Folder Track
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   Converting my custom action to a script for easy sharing. 
-- @link https://www.stephenschappler.com
-- @changelog 
--   7/30/24 Creating the script

function main()
    -- List of action IDs in the order they appear in the custom action
    local actionList = {
      "41067", -- Track: Insert multiple new tracks...
      "_SWS_SAVESEL", -- Save Selection
      "_SWS_INSRTTRKABOVE", -- Insert track above
      "_XENAKIOS_RENAMETRAXDLG", -- Replace with actual action ID
      "_SWS_RESTORESEL", -- Replace with actual action ID
      "_XENAKIOS_SELPREVTRACKKEEP", -- Replace with actual action ID
      "_SWS_SELCHILDREN2", -- Replace with actual action ID     
      "_SWS_MAKEFOLDER", -- Replace with actual action ID     
      "_SWS_RESTORESEL", -- Replace with actual action ID     
      "_SWS_SELPARENTS", -- Replace with actual action ID         
    }
  
    -- Begin the undo block
    reaper.Undo_BeginBlock()
  
    -- Loop through the actions and perform them
    for _, actionID in ipairs(actionList) do
      reaper.Main_OnCommand(reaper.NamedCommandLookup(actionID), 0)
    end
  
    -- End the undo block
    reaper.Undo_EndBlock("Converted Custom Action", -1)
  end
  
  -- Run the script
  main()
  