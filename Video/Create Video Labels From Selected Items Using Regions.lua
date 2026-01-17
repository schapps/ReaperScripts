-- @description Create Video Labels From Selected Items Using Regions
-- @author Aaron Cendan, modified by Stephen Schappler
-- @version 1.3
-- @link https://aaroncendan.me
-- @changelog
--   Create regions from selected items and build video labels from regions, adding options for overlapping items with automatic vertical text offsets

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~ USER CONFIG - EDIT THESE ~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Name for new track at top of project with video processor items
local track_name = "Video Regions"

-- Parameter presets for video processor text
local parm_TEXT_HEIGHT = 0.07
local parm_Y_POSITION  = 0.9
local parm_X_POSITION  = 0.05 
local parm_BORDER      = 0.1
local parm_TEXT_BRIGHT = 1
local parm_TEXT_ALPHA  = 1
local parm_BG_BRIGHT   = 0.55
local parm_BG_ALPHA    = 0.4

-- Toggle 'true' to skip blank/un-named regions. Otherwise, if false, uses "Region #X"
local skip_blanks = false

-- When regions overlap, offset Y position upward by this amount per overlap
local overlap_y_step = 0.1

-- Toggle 'true' to delete created regions after video items are built
local delete_regions_after_create = false

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~ GLOBAL VARS ~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Get this script's name and directory
local script_name = ({reaper.get_action_context()})[2]:match("([^/\\_]+)%.lua$")
local script_directory = ({reaper.get_action_context()})[2]:sub(1,({reaper.get_action_context()})[2]:find("\\[^\\]*$"))
local separator = reaper.GetOS():find("Win") and "\\" or "/"
local text_preset = script_directory .. separator .. "acendan_Text Overlay Preset.txt"
local template_preset = script_directory .. separator .. ".." .. separator .. "TrackTemplates" .. separator .. "Video Text Overlay.RTrackTemplate"

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ FUNCTIONS ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

function insertRegionsFromSelectedItems()
  local num_sel_items = reaper.CountSelectedMediaItems(0)
  if num_sel_items == 0 then
    reaper.MB("No items selected!","Insert Regions", 0)
    return 0
  end

  for i=0, num_sel_items - 1 do
    local item = reaper.GetSelectedMediaItem( 0, i )
    local item_start = reaper.GetMediaItemInfo_Value( item, "D_POSITION" )
    local item_len = reaper.GetMediaItemInfo_Value( item, "D_LENGTH" )
    local take = reaper.GetActiveTake( item )
    local ret, name = reaper.GetSetMediaItemTakeInfo_String( take, "P_NAME", "", false )

    if ret then 
      reaper.AddProjectMarker( 0, 1, item_start, item_start + item_len, name, -1 )
    else
      reaper.AddProjectMarker( 0, 1, item_start, item_start + item_len, "", -1 )
    end
  end

  return num_sel_items
end

function SetTimeSelectionToSelectedItems()
  local num_sel_items = reaper.CountSelectedMediaItems(0)
  if num_sel_items == 0 then
    return nil
  end

  local min_pos = nil
  local max_end = nil
  for i=0, num_sel_items - 1 do
    local item = reaper.GetSelectedMediaItem( 0, i )
    local item_start = reaper.GetMediaItemInfo_Value( item, "D_POSITION" )
    local item_len = reaper.GetMediaItemInfo_Value( item, "D_LENGTH" )
    local item_end = item_start + item_len
    if not min_pos or item_start < min_pos then min_pos = item_start end
    if not max_end or item_end > max_end then max_end = item_end end
  end

  reaper.GetSet_LoopTimeRange(1, 0, min_pos, max_end, 0)
  return min_pos, max_end
end

function DeleteRegionsInTimeSelection(sel_start, sel_end)
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local num_total = num_markers + num_regions
  for i = num_total - 1, 0, -1 do
    local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers3( 0, i )
    if isrgn then
      local overlaps = rgnend > sel_start and pos < sel_end
      if overlaps then
        reaper.DeleteProjectMarker(0, markrgnindexnumber, true)
      end
    end
  end
end

function DeleteVideoRegionItems()
  local ret, trk_guid = reaper.GetProjExtState(0,"acendan_vid_rgns","trk_guid")
  if ret then
    local vid_track = reaper.BR_GetMediaTrackByGUID(0,trk_guid)
    if vid_track then
      reaper.SetOnlyTrackSelected(vid_track)
      reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_DELALLITEMS"),0) -- SWS: Delete all items on selected track(s)
    end
  end
end

function main()
  local ret, num_markers, num_regions = reaper.CountProjectMarkers(0)
  
  -- Confirm regions in project
  if num_regions > 0 then 
    
    -- Try to find existing vid title track
    local ret, trk_guid = reaper.GetProjExtState(0,"acendan_vid_rgns","trk_guid")
    if ret then
      track = reaper.BR_GetMediaTrackByGUID(0,trk_guid)
      if not track then PrepProjectVidTrack() end
    else
      PrepProjectVidTrack()
    end
    reaper.SetOnlyTrackSelected(track)
    reaper.Main_OnCommand(reaper.NamedCommandLookup("_SWS_DELALLITEMS"),0) -- SWS: Delete all items on selected track(s)
    
    local region_entries = BuildRegionEntries(num_markers + num_regions)
    local created_regions = {}
    local j = 0
    for _, entry in ipairs(region_entries) do
      -- Insert new video processor item at region position, length matches region
      reaper.Main_OnCommand(40020,0) -- Time selection: Remove time selection and loop points
      reaper.SetEditCurPos(entry.pos,false,false)
      reaper.GetSet_LoopTimeRange(1, 0, entry.pos, entry.rgnend, 0)
      reaper.Main_OnCommand(41932,0) -- Insert dedicated video processor item
      
      -- Add video processor FX
      local item = reaper.GetTrackMediaItem(track,j)
      local take = reaper.GetActiveTake(item)
      local vidfx_pos = reaper.TakeFX_AddByName(take,"Video processor",1)
      local name = entry.name
      
      -- Write code for text overlay to video processor
      local ok_preset, preset_msg = AddTextPresetToVideoProcessor(item)
      if not ok_preset then
        reaper.MB(preset_msg, "Create Video Labels", 0)
        return
      end
      
      -- Set name in video processor chunk to region name
      local ok_text, text_msg = SetTextInVideoProcessor(item, name)
      if not ok_text then
        reaper.MB(text_msg, "Create Video Labels", 0)
        return
      end
      
      -- Set preset values, offset Y if overlapping
      local y_pos = parm_Y_POSITION - (overlap_y_step * entry.lane)
      if y_pos < 0 then y_pos = 0 end
      SetTextOverlayParameters(take, y_pos)
      
      -- Ensure vid fx window is closed
      reaper.TakeFX_SetOpen(take, vidfx_pos, false)
    
      if entry.markrgnindexnumber then
        created_regions[#created_regions + 1] = entry.markrgnindexnumber
      end
      j = j + 1
    end

    if delete_regions_after_create and #created_regions > 0 then
      table.sort(created_regions, function(a, b) return a > b end)
      for _, idx in ipairs(created_regions) do
        reaper.DeleteProjectMarker(0, idx, true)
      end
    end
  
  else
    reaper.MB("Project has no regions!","",0)
  end
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ UTILITIES ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- No vid track found, prepare session with video track
function PrepProjectVidTrack()
  reaper.Main_OnCommand(reaper.NamedCommandLookup("_XENAKIOS_INSNEWTRACKTOP"), 0) -- Xenakios/SWS: Insert new track at the top of track list
  track = reaper.GetTrack(0,0)
  trk_guid = reaper.GetTrackGUID(track)
  reaper.SetProjExtState(0,"acendan_vid_rgns","trk_guid",trk_guid)
  reaper.GetSetMediaTrackInfo_String(track,"P_NAME",track_name,true)
end

function BuildRegionEntries(num_total)
  local regions = {}
  for i=0, num_total - 1 do
    local retval, isrgn, pos, rgnend, name, markrgnindexnumber = reaper.EnumProjectMarkers3( 0, i )
    if isrgn then
      if not (name == "" and skip_blanks) then
        if name == "" then name = "Region #" .. tostring(markrgnindexnumber) end
        regions[#regions + 1] = {
          pos = pos,
          rgnend = rgnend,
          name = name,
          markrgnindexnumber = markrgnindexnumber,
        }
      end
    end
  end

  table.sort(regions, function(a, b)
    if a.pos == b.pos then
      return a.rgnend < b.rgnend
    end
    return a.pos < b.pos
  end)

  local lanes = {}
  for _, region in ipairs(regions) do
    local lane = nil
    for i=1, #lanes do
      if lanes[i] <= region.pos then
        lane = i
        break
      end
    end
    if not lane then
      lane = #lanes + 1
    end
    lanes[lane] = region.rgnend
    region.lane = lane - 1
  end

  return regions
end

-- Store the contents of the preset text file into local text
function GetPreset()
  preset_code_block = ""
  local file = io.open(text_preset)
  if not file then return false end
  io.input(file)
  for line in io.lines() do
    preset_code_block = preset_code_block .. line .. "\n"
  end
  io.close(file)
  return true
end

function GetPresetFromTemplate()
  local file = io.open(template_preset, "r")
  if not file then return false end

  local in_block = false
  local block_lines = {}
  local saw_overlay = false
  for line in file:lines() do
    if not in_block then
      if line:match("^%s*<TAKEFX") then
        in_block = true
        block_lines = {line}
        saw_overlay = false
      end
    else
      table.insert(block_lines, line)
      if line:find("Text/timecode overlay", 1, true) then
        saw_overlay = true
      end
      if line:match("^%s*>%s*$") then
        if saw_overlay then
          file:close()
          preset_code_block = table.concat(block_lines, "\n") .. "\n"
          return true
        end
        in_block = false
      end
    end
  end
  file:close()
  return false
end

-- Adds the preset as text because Reaper won't let me reference native presets for some reason 
function AddTextPresetToVideoProcessor(item)
  if not preset_code_block then
    if not GetPreset() then
      GetPresetFromTemplate()
    end
  end
  if not preset_code_block or preset_code_block == "" then
    return false, "Missing text overlay preset. Expected " .. text_preset .. " or " .. template_preset
  end

  local _bool, StateChunk=reaper.GetItemStateChunk(item, "", false)
  if StateChunk:match("VIDEO_EFFECT")==nil then return false, "No Video Processor found in this item" end
  local part1, code, part2=StateChunk:match("^(.-)(<TAKEFX[%s%S]-\n%s*>)([%s%S]*)$")
  if not part1 then return false, "Unable to replace TAKEFX block" end
  StateChunk=part1..preset_code_block..part2
  return reaper.SetItemStateChunk(item, StateChunk, false), "Done"
end

-- Adapted from Meo Mespotine's solution on the Reaper forums
-- https://forums.cockos.com/showpost.php?p=2006396&postcount=12
function SetTextInVideoProcessor(item, text)
  if reaper.ValidatePtr2(0, item, "MediaItem*")==false then return false, "No valid MediaItem" end
  if type(text)~="string" then return false, "Must be a string" end
  local _bool, StateChunk=reaper.GetItemStateChunk(item, "", false)
  if StateChunk:match("VIDEO_EFFECT")==nil then return false, "No Video Processor found in this item" end
  local part1, code, part2=StateChunk:match("^(.-)(<TAKEFX[%s%S]-\n%s*>)([%s%S]*)$")
  if not part1 then return false, "Unable to locate TAKEFX block" end
  
  if code:match("// Text overlay")==nil and code:match("// Text/timecode overlay")==nil then
    return false, "Only text overlay presets are supported. Please select accordingly."
  else 
    local c1,test,c3=code:match("(.-#text=\")(.-)(\".*)")
    if not c1 then
      c1,test,c3=code:match("(.-text=\")(.-)(\".*)")
    end
    if not c1 then return false, "Unable to find text field in preset" end
    text=string.gsub(text, "\n", "\\n")
    code=c1..text..c3
  end
  StateChunk=part1..code..part2
  return reaper.SetItemStateChunk(item, StateChunk, false), "Done"
end

-- Adapted from Meo Mespotine's solution on the Reaper forums
-- https://forums.cockos.com/showpost.php?p=2006396&postcount=12
function GetTextInVideoProcessor(item)
  if reaper.ValidatePtr2(0, item, "MediaItem*")==false then return false, "No valid MediaItem" end
  local _bool, StateChunk=reaper.GetItemStateChunk(item, "", false)
  if StateChunk:match("VIDEO_EFFECT")==nil then return false, "No Video Processor found in this item" end
  local part1, code, part2=StateChunk:match("^(.-)(<TAKEFX[%s%S]-\n%s*>)([%s%S]*)$")
  if not part1 then return false, "Unable to locate TAKEFX block" end
  --reaper.ShowConsoleMsg(code)
  if code:match("// Text overlay")==nil and code:match("// Text/timecode overlay")==nil then
    return false, "Only text overlay presets are supported. Please select accordingly."
  else 
    local c1,test,c3=code:match("(.-#text=\")(.-)(\".*)")
    if not c1 then
      c1,test,c3=code:match("(.-text=\")(.-)(\".*)")
    end
    if not c1 then return false, "Unable to find text field in preset" end
    test=string.gsub(test, "\\n", "\n")
    return true, test
  end
end

-- Set text overlay parameter values
function SetTextOverlayParameters(take, y_position)
  reaper.TakeFX_SetParam(take,0,0,parm_TEXT_HEIGHT)
  reaper.TakeFX_SetParam(take,0,1,y_position or parm_Y_POSITION)
  reaper.TakeFX_SetParam(take,0,2,parm_X_POSITION)
  reaper.TakeFX_SetParam(take,0,3,parm_BORDER)
  reaper.TakeFX_SetParam(take,0,4,parm_TEXT_BRIGHT)
  reaper.TakeFX_SetParam(take,0,5,parm_TEXT_ALPHA)
  reaper.TakeFX_SetParam(take,0,6,parm_BG_BRIGHT)
  reaper.TakeFX_SetParam(take,0,7,parm_BG_ALPHA)
end

-- Save original time/loop selection
function saveLoopTimesel()
  init_start_timesel, init_end_timesel = reaper.GetSet_LoopTimeRange(0, 0, 0, 0, 0)
  init_start_loop, init_end_loop = reaper.GetSet_LoopTimeRange(0, 1, 0, 0, 0)
end

-- Restore original time/loop selection
function restoreLoopTimesel()
  reaper.GetSet_LoopTimeRange(1, 0, init_start_timesel, init_end_timesel, 0)
  reaper.GetSet_LoopTimeRange(1, 1, init_start_loop, init_end_loop, 0)
end

-- Save original cursor position
function saveCursorPos()
  init_cur_pos = reaper.GetCursorPosition()
end

-- Restore original cursor position
function restoreCursorPos()
  reaper.SetEditCurPos(init_cur_pos,false,false)
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~ MAIN ~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
reaper.PreventUIRefresh(1)

reaper.Undo_BeginBlock()

saveLoopTimesel()
saveCursorPos()

local sel_start, sel_end = SetTimeSelectionToSelectedItems()
if not sel_start then
  reaper.MB("No items selected!","Create Video Labels", 0)
  restoreLoopTimesel()
  restoreCursorPos()
  reaper.Undo_EndBlock(script_name,-1)
  reaper.PreventUIRefresh(-1)
  return
end

DeleteRegionsInTimeSelection(sel_start, sel_end)
DeleteVideoRegionItems()

local inserted = insertRegionsFromSelectedItems()
if inserted > 0 then
  main()
end

restoreLoopTimesel()
restoreCursorPos()

reaper.Undo_EndBlock(script_name,-1)

reaper.PreventUIRefresh(-1)

reaper.UpdateArrange()
