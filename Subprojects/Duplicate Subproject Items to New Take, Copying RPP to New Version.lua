-- @description Duplicate Subproject Items to New Take, Copying RPP to New Version
-- @author Stephen Schappler
-- @version 2.2
-- @about
--   Duplicate Subproject Items as New Takes with Versioning (Multiple Items) and Open Each New Subproject in a New Tab
-- @link https://www.stephenschappler.com
-- @changelog
--   09/06/26 - v2.2 Added a "Close Subproject After Duplication" option, matching Create Subproject's.
--   09/06/26 - v2.1 Dialog now opens with no items selected and picks up the selection live, instead of requiring items to be selected before launch.
--   09/06/26 - v2.0 Added a ReaImGui dialog to manually name the new version and see the current one; validates all target files before touching the project and fixed Undo blocks left unclosed on error.
--   02/12/25 - v1.2 Adding in take markers that show the name of the rpp version for each take
--   02/12/25 - v1.1 Modifying the script so that it takes the user back to the parent project at the end.
--   02/11/25 - v1.0 Creating the script.

-- ============================================================
-- ReaImGui dependency check + bootstrap
-- ============================================================
if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

-- ============================================================
-- Theme module
-- ============================================================
local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local theme_path  = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

-- ============================================================
-- Helper functions
-- ============================================================
local function file_exists(path)
  local f = io.open(path, "rb")
  if f then f:close() end
  return f ~= nil
end

local function getCurrentProjectName()
  return reaper.GetProjectName(0, "")
end

local function activateProjectByName(targetName)
  local projIndex = 0
  while true do
    local proj = reaper.EnumProjects(projIndex, "")
    if not proj then break end
    if reaper.GetProjectName(proj, "") == targetName then
      reaper.SelectProjectInstance(proj)
      break
    end
    projIndex = projIndex + 1
  end
end

local function saveSelectedItems()
  local savedItems = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    savedItems[#savedItems + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  return savedItems
end

local function restoreSelectedItems(savedItems)
  reaper.Main_OnCommand(40289, 0) -- Unselect all items
  for _, item in ipairs(savedItems) do
    reaper.SetMediaItemSelected(item, true)
  end
end

local function version_label(ver)
  return ver and string.format("v%02d", ver) or "Original"
end

-- Strips characters that aren't valid in a filename and trims whitespace.
local function sanitize_label(raw)
  local s = raw:gsub("^%s+", ""):gsub("%s+$", "")
  s = s:gsub('[\\/:%*%?"<>|]', "")
  return s
end

-- For each selected item, resolves its active take's subproject source
-- (folder/base name/extension, and any existing "_vNN" suffix) up front so
-- the dialog can show a version summary and the Duplicate action doesn't
-- have to re-derive this while mutating the project.
local function gather_items_info(items)
  local infos = {}
  for _, item in ipairs(items) do
    local take = reaper.GetActiveTake(item)
    if not take then
      return nil, "One of the selected items has no active take."
    end

    local src = reaper.GetMediaItemTake_Source(take)
    if not src then
      return nil, "Unable to retrieve source for one of the selected items."
    end

    local origFile = reaper.GetMediaSourceFileName(src, "")
    if not origFile or origFile == "" then
      return nil, "Could not determine subproject file path for one of the selected items."
    end

    local folder, filename = origFile:match("^(.-)[\\/]([^\\/]-)$")
    if not folder or not filename then
      return nil, "Failed to parse file path for one of the selected items."
    end

    local base, ext = filename:match("^(.*)%.([^.]+)$")
    if not base or ext:lower() ~= "rpp" then
      return nil, "One of the selected items is not a subproject (.rpp) item."
    end

    local origBase, currentVer = base:match("^(.*)_v(%d%d)$")
    infos[#infos + 1] = {
      item = item,
      take = take,
      origFile = origFile,
      folder = folder,
      base = origBase or base,
      ext = ext,
      currentVer = currentVer and tonumber(currentVer) or nil,
    }
  end
  return infos
end

-- Reads the current selection fresh (not a one-time snapshot at script
-- launch) so the dialog can open with nothing selected and pick up
-- whatever the user selects while it's sitting open. Returns a state
-- table describing what's currently selectable, or an .error string
-- explaining why nothing can be duplicated yet.
local function compute_selection_state()
  local selectedItems = saveSelectedItems()
  local numItems = #selectedItems

  if numItems == 0 then
    return { numItems = 0, error = "No media items selected." }
  end

  local items_info, info_err = gather_items_info(selectedItems)
  if not items_info then
    return { numItems = numItems, error = info_err }
  end

  -- Build the "Current Version" summary and a suggested next-version name.
  local max_ver = 0
  local unique_labels, label_seen = {}, {}
  for _, info in ipairs(items_info) do
    local lbl = version_label(info.currentVer)
    if not label_seen[lbl] then
      label_seen[lbl] = true
      unique_labels[#unique_labels + 1] = lbl
    end
    if info.currentVer and info.currentVer > max_ver then
      max_ver = info.currentVer
    end
  end

  return {
    numItems = numItems,
    parentProjectName = getCurrentProjectName(),
    selectedItems = selectedItems,
    items_info = items_info,
    current_version_display = table.concat(unique_labels, ", "),
    default_label = string.format("v%02d", max_ver + 1),
  }
end

-- ============================================================
-- Main action: validates the requested name, then duplicates each
-- selected item's subproject file under that name as a new take.
-- ============================================================

-- Phase A: resolve+validate every target file path before anything is
-- written, so a name collision on item 3 of 5 can't leave items 1-2
-- already mutated.
local function build_plan(label, items_info)
  local plan = {}
  local path_for_file = {}
  for _, info in ipairs(items_info) do
    local newFilePath = path_for_file[info.origFile]
    if not newFilePath then
      newFilePath = string.format("%s/%s_%s.%s", info.folder, info.base, label, info.ext)
      if file_exists(newFilePath) then
        local shown = newFilePath:match("([^\\/]+)$") or newFilePath
        return nil, string.format('A file named "%s" already exists. Choose a different version name.', shown)
      end
      path_for_file[info.origFile] = newFilePath
    end
    plan[#plan + 1] = { info = info, newFilePath = newFilePath }
  end
  return plan
end

local function perform_duplication(label, state, close_after)
  local sanitized = sanitize_label(label)
  if sanitized == "" then
    return false, "Please enter a name for the new version."
  end

  local plan, plan_err = build_plan(sanitized, state.items_info)
  if not plan then
    return false, plan_err
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local function fail(msg)
    reaper.PreventUIRefresh(-1)
    reaper.Undo_EndBlock("Duplicate Subprojects (cancelled)", -1)
    return false, msg
  end

  local copied = {}
  for _, p in ipairs(plan) do
    local info, newFilePath = p.info, p.newFilePath

    if not copied[info.origFile] then
      local infile = io.open(info.origFile, "rb")
      if not infile then
        return fail("Could not open subproject file:\n" .. info.origFile)
      end
      local content = infile:read("*all")
      infile:close()

      local outfile = io.open(newFilePath, "wb")
      if not outfile then
        return fail("Could not create new subproject file:\n" .. newFilePath)
      end
      outfile:write(content)
      outfile:close()

      copied[info.origFile] = true
    end

    local newTake = reaper.AddTakeToMediaItem(info.item)
    if not newTake then
      return fail("Failed to add take.")
    end

    local newSource = reaper.PCM_Source_CreateFromFile(newFilePath)
    if not newSource then
      return fail("Failed to create PCM source.")
    end
    reaper.SetMediaItemTake_Source(newTake, newSource)

    local origOffset = reaper.GetMediaItemTakeInfo_Value(info.take, "D_STARTOFFS")
    reaper.SetMediaItemTakeInfo_Value(newTake, "D_STARTOFFS", origOffset)

    local retval, origTakeName = reaper.GetSetMediaItemTakeInfo_String(info.take, "P_NAME", "", false)
    if retval then
      reaper.GetSetMediaItemTakeInfo_String(newTake, "P_NAME", origTakeName, true)
    end

    local takeCount = reaper.CountTakes(info.item)
    reaper.SetMediaItemInfo_Value(info.item, "I_CURTAKE", takeCount - 1)
  end

  -- Open each new subproject in turn so REAPER saves/renders its RPP.
  for _, p in ipairs(plan) do
    local item = p.info.item
    reaper.SetMediaItemSelected(item, true)
    for _, other in ipairs(plan) do
      if other.info.item ~= item then
        reaper.SetMediaItemSelected(other.info.item, false)
      end
    end
    reaper.Main_OnCommand(40109, 0) -- Open subproject
    reaper.Main_OnCommand(42332, 0) -- Save and render RPP
    if close_after then
      reaper.Main_OnCommand(40860, 0) -- Close current project tab
    end
  end

  activateProjectByName(state.parentProjectName)
  restoreSelectedItems(state.selectedItems)

  -- Take markers for each new take at the left-bound offset.
  for _, p in ipairs(plan) do
    local item = p.info.item
    local takeCount = reaper.CountTakes(item)
    if takeCount > 1 then
      local newTake = reaper.GetTake(item, takeCount - 1)
      if newTake then
        local src = reaper.GetMediaItemTake_Source(newTake)
        if src then
          local filePath = reaper.GetMediaSourceFileName(src, "")
          local newFileName = filePath:match("([^\\/]+)%.rpp$")
          if newFileName then
            local marker_offset = reaper.GetMediaItemTakeInfo_Value(newTake, "D_STARTOFFS")
            reaper.SetTakeMarker(newTake, -1, newFileName, marker_offset)
          end
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.TrackList_AdjustWindows(false)
  reaper.Undo_EndBlock("Duplicate Subprojects (Versioned, New Takes, Selection Restored, Markers)", -1)

  return true
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local script_title = "DUPLICATE SUBPROJECT"
local ctx = ImGui.CreateContext(script_title)

local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_AlwaysAutoResize
               | ImGui.WindowFlags_NoScrollWithMouse
               | ImGui.WindowFlags_NoSavedSettings

local name_buf = ""
local name_seeded = false -- true once name_buf has been prefilled from a real selection
local error_msg = nil
local open = true
local close_after = reaper.GetExtState("DuplicateSubprojectVersion", "CloseAfterDuplication") == "true"

-- Fixed, not stretched: a WidthStretch table column inside a
-- WindowFlags_AlwaysAutoResize window has no fixed width to stretch
-- against (the window's width is itself derived from content), so the
-- two fight over several frames -- visible as the window slowly
-- shrinking into place right after it opens. A plain fixed-width field
-- gives the window one stable target size from the very first frame.
local FIELD_W = 300

local function loop()
  local color_count, var_count = theme.Push(ctx)

  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    -- Re-read the selection every frame, not just once at launch, so the
    -- window can sit open with nothing selected until the user picks
    -- items in the arrange view.
    local state = compute_selection_state()

    if not name_seeded and state.items_info then
      name_buf = state.default_label
      name_seeded = true
    end

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "Current Version")
    ImGui.PopStyleColor(ctx)
    ImGui.Text(ctx, state.items_info and state.current_version_display or "\u{2013}")

    ImGui.Spacing(ctx)

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "New Version Name")
    ImGui.PopStyleColor(ctx)
    ImGui.SetNextItemWidth(ctx, FIELD_W)
    local _, new_name = ImGui.InputText(ctx, "##new_name", name_buf)
    if new_name ~= name_buf then
      name_buf = new_name
      error_msg = nil
    end

    ImGui.Spacing(ctx)
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    if state.items_info then
      local item_word = state.numItems == 1 and "item" or "items"
      ImGui.Text(ctx, string.format("Adds a new take to %d selected %s", state.numItems, item_word))
    else
      ImGui.Text(ctx, state.error)
    end
    ImGui.PopStyleColor(ctx)

    if error_msg then
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF5555FF)
      ImGui.TextWrapped(ctx, error_msg)
      ImGui.PopStyleColor(ctx)
    end

    ImGui.Spacing(ctx)
    local _, new_close_after = ImGui.Checkbox(ctx, "Close Subproject After Duplication", close_after)
    close_after = new_close_after
    if ImGui.IsItemHovered(ctx) then
      ImGui.SetTooltip(ctx, "Closes each newly created subproject's tab immediately after it's saved.")
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    local disabled = not state.items_info or sanitize_label(name_buf) == ""
    if disabled then ImGui.BeginDisabled(ctx, true) end
    local clicked = theme.PrimaryButton(ctx, "Duplicate", -1, 0, nil, theme.Icons.DUPLICATE)
    if disabled then ImGui.EndDisabled(ctx) end

    local enter_pressed = not disabled and
      (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter))

    if not disabled and (clicked or enter_pressed) then
      reaper.SetExtState("DuplicateSubprojectVersion", "CloseAfterDuplication", close_after and "true" or "false", true)
      local ok, err = perform_duplication(name_buf, state, close_after)
      if ok then
        open = false
      else
        error_msg = err
      end
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if still_open and open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
