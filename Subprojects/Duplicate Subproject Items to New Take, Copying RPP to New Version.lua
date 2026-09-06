-- @description Duplicate Subproject Items to New Take, Copying RPP to New Version
-- @author Stephen Schappler
-- @version 2.9
-- @about
--   Duplicate Subproject Items as New Takes with Versioning (Multiple Items) and Open Each New Subproject in a New Tab
-- @link https://www.stephenschappler.com
-- @changelog
--   09/06/26 - v2.9 Widened preview table columns and added CellPadding so the "(x2)"-style source suffix stops clipping against the next column; widened WIN_MIN_W to match.
--   09/06/26 - v2.8 New Version input text is now green while valid, red on a collision (matching the Resulting File column).
--   09/06/26 - v2.7 Preview table is now always visible (empty when nothing's selected), styled via the shared theme's new theme.TableFlags/TableHeadersRow (bold header, matching every other table in the repo), with monospace body rows.
--   09/06/26 - v2.6 Window width now stays constant instead of shrinking/growing as the preview table appears and disappears with the selection.
--   09/06/26 - v2.5 Added a warning when items sharing the same subproject lineage are on different current versions, explaining they should be aligned before duplicating.
--   09/06/26 - v2.4 Fixed: a single shared "New Version Name" pushed every selected source to the same version number regardless of its own current version. Each source in the preview table now gets its own editable version name, defaulted to its own current+1.
--   09/06/26 - v2.3 Replaced the single "Current Version" line with a per-source preview table (current vs. new version, live as you type), flagging filename collisions in red.
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

-- One row per unique subproject source among items_info (items sharing a
-- source collapse into a single row, since they'll get the same new
-- file). Each source needs its own version name -- one .rpp on v05 and
-- another still Original must not both be pushed to the same "next"
-- number -- so this seeds name_by_file[origFile] with that source's own
-- suggested next version ("_vNN" + 1) the first time it's seen, and
-- leaves it alone on every later frame (whether left at the default or
-- since edited by the user).
local function collect_preview_rows(items_info, name_by_file)
  local rows, seen = {}, {}
  for _, info in ipairs(items_info) do
    local row = seen[info.origFile]
    if not row then
      if name_by_file[info.origFile] == nil then
        name_by_file[info.origFile] = string.format("v%02d", (info.currentVer or 0) + 1)
      end
      row = { info = info, count = 0 }
      seen[info.origFile] = row
      rows[#rows + 1] = row
    end
    row.count = row.count + 1
  end
  return rows
end

-- Flags when the same subproject lineage (same base name once any "_vNN"
-- is stripped) shows up at more than one current version among the
-- preview rows -- e.g. one item's take still pointing at "Cool
-- Impact_v02.rpp" while another points at "Cool Impact_v05.rpp". Each row
-- is validated independently in build_plan, so this can't be caught by
-- the per-row filename-collision check (it only accidentally fires if a
-- stray file happens to already occupy the guessed next name) -- this is
-- a separate, always-on check for the underlying drift itself.
local function detect_version_mismatches(rows)
  local by_base, base_order = {}, {}
  for _, row in ipairs(rows) do
    local base = row.info.base
    local entry = by_base[base]
    if not entry then
      entry = { seen = {}, order = {} }
      by_base[base] = entry
      base_order[#base_order + 1] = base
    end
    local lbl = version_label(row.info.currentVer)
    if not entry.seen[lbl] then
      entry.seen[lbl] = true
      entry.order[#entry.order + 1] = lbl
    end
  end

  local warnings = {}
  for _, base in ipairs(base_order) do
    local entry = by_base[base]
    if #entry.order > 1 then
      warnings[#warnings + 1] = string.format(
        '"%s" has items on different versions (%s). Set every item on this subproject to the same version before duplicating, or the new version numbers won\'t match up.',
        base, table.concat(entry.order, ", "))
    end
  end
  return warnings
end

-- The resulting filename (and whether it collides with an existing file)
-- for one source given its own raw, not-yet-sanitized version name.
local function resulting_filename(info, raw_label)
  local sanitized = sanitize_label(raw_label)
  if sanitized == "" then
    return "\u{2013}", false
  end
  local new_name = string.format("%s_%s.%s", info.base, sanitized, info.ext)
  return new_name, file_exists(info.folder .. "/" .. new_name)
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

  return {
    numItems = numItems,
    parentProjectName = getCurrentProjectName(),
    selectedItems = selectedItems,
    items_info = items_info,
  }
end

-- ============================================================
-- Main action: validates the requested name, then duplicates each
-- selected item's subproject file under that name as a new take.
-- ============================================================

-- Phase A: resolve+validate every target file path before anything is
-- written, so a name collision on item 3 of 5 can't leave items 1-2
-- already mutated. Each source uses its own entry in name_by_file
-- (keyed by origFile), not one label shared across every source.
local function build_plan(name_by_file, items_info)
  local plan = {}
  local path_for_file = {}
  for _, info in ipairs(items_info) do
    local newFilePath = path_for_file[info.origFile]
    if not newFilePath then
      local sanitized = sanitize_label(name_by_file[info.origFile] or "")
      if sanitized == "" then
        return nil, string.format('Please enter a version name for "%s.%s".', info.base, info.ext)
      end
      newFilePath = string.format("%s/%s_%s.%s", info.folder, info.base, sanitized, info.ext)
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

local function perform_duplication(name_by_file, state, close_after)
  local plan, plan_err = build_plan(name_by_file, state.items_info)
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

local name_by_file = {} -- origFile -> that source's own version name (seeded per-source, see collect_preview_rows)
local error_msg = nil
local open = true
local close_after = reaper.GetExtState("DuplicateSubprojectVersion", "CloseAfterDuplication") == "true"

-- Width floor comfortably wider than the preview table's fixed columns
-- (200+80+100+220 = 600, plus its own CellPadding/borders) so the table
-- is never what's driving the window's width. Without this,
-- WindowFlags_AlwaysAutoResize shrinks the window down whenever the
-- table disappears (nothing/invalid selected) and grows it back the
-- moment it reappears -- visibly resizing on every selection change
-- instead of staying a constant width.
local WIN_MIN_W = 680

local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSizeConstraints(ctx, WIN_MIN_W, 0, 9999, 9999)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    -- Re-read the selection every frame, not just once at launch, so the
    -- window can sit open with nothing selected until the user picks
    -- items in the arrange view.
    local state = compute_selection_state()

    -- Each distinct subproject source gets its own row and its own
    -- editable version name -- a source on v05 and one still Original
    -- must not be pushed to the same "next" number, so there's no single
    -- shared name field anymore. Always visible (even with an empty or
    -- invalid selection, as just a header with no rows) so the window's
    -- width never depends on whether it's showing anything -- see
    -- WIN_MIN_W above. Fixed (not stretched) table columns: a stretch
    -- column has no fixed width to stretch against when the window's own
    -- width is derived from content, and the two fight over several
    -- frames instead of settling immediately.
    local rows = state.items_info and collect_preview_rows(state.items_info, name_by_file) or {}
    local any_blank, any_collision = not state.items_info, false

    -- Extra breathing room between/within cells (default CellPadding is
    -- tight -- 4,2 -- which is what was clipping "(\u{d7}2)" against the
    -- next column's edge in the Source cell).
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_CellPadding, 10, 6)
    if ImGui.BeginTable(ctx, "##preview", 4, theme.TableFlags) then
      ImGui.TableSetupColumn(ctx, "Source", ImGui.TableColumnFlags_WidthFixed, 200)
      ImGui.TableSetupColumn(ctx, "Current", ImGui.TableColumnFlags_WidthFixed, 80)
      ImGui.TableSetupColumn(ctx, "New Version", ImGui.TableColumnFlags_WidthFixed, 100)
      ImGui.TableSetupColumn(ctx, "Resulting File", ImGui.TableColumnFlags_WidthFixed, 220)
      theme.TableHeadersRow(ctx)

      theme.PushMonoFont(ctx)
      for _, row in ipairs(rows) do
        local info = row.info
        local origFile = info.origFile

        ImGui.TableNextRow(ctx)

        ImGui.TableSetColumnIndex(ctx, 0)
        local source = info.base .. "." .. info.ext
        if row.count > 1 then
          source = string.format("%s (\u{d7}%d)", source, row.count)
        end
        ImGui.Text(ctx, source)

        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, version_label(info.currentVer))

        ImGui.TableSetColumnIndex(ctx, 2)
        -- Green while the name is valid (non-blank, no collision), red on
        -- a collision, left default while blank -- same collision check
        -- as the Resulting File column, just against the not-yet-edited
        -- value (a frame behind on an edit that just fixed/broke it,
        -- same as that column's own recompute below is a frame ahead).
        local pre_name, pre_collides = resulting_filename(info, name_by_file[origFile])
        local name_colored = pre_name ~= "\u{2013}"
        if name_colored then
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, pre_collides and 0xFF5555FF or 0x5CD65CFF)
        end
        ImGui.SetNextItemWidth(ctx, -1)
        local _, new_val = ImGui.InputText(ctx, "##name_" .. origFile, name_by_file[origFile])
        if name_colored then ImGui.PopStyleColor(ctx) end
        if new_val ~= name_by_file[origFile] then
          name_by_file[origFile] = new_val
          error_msg = nil
        end

        ImGui.TableSetColumnIndex(ctx, 3)
        local new_name, collides = resulting_filename(info, name_by_file[origFile])
        if new_name == "\u{2013}" then any_blank = true end
        if collides then
          any_collision = true
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFF5555FF)
        end
        ImGui.Text(ctx, new_name)
        if collides then
          ImGui.PopStyleColor(ctx)
          if ImGui.IsItemHovered(ctx) then
            ImGui.SetTooltip(ctx, "A file with this name already exists.")
          end
        end
      end
      theme.PopMonoFont(ctx)

      ImGui.EndTable(ctx)
    end
    ImGui.PopStyleVar(ctx)

    -- Advisory only -- doesn't disable Duplicate, since each row is
    -- still validated and duplicated independently either way.
    for _, msg in ipairs(detect_version_mismatches(rows)) do
      ImGui.Spacing(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xFFB84DFF)
      theme.IconText(ctx, theme.Icons.WARNING)
      ImGui.SameLine(ctx)
      ImGui.TextWrapped(ctx, msg)
      ImGui.PopStyleColor(ctx)
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

    local disabled = not state.items_info or any_blank or any_collision
    if disabled then ImGui.BeginDisabled(ctx, true) end
    local clicked = theme.PrimaryButton(ctx, "Duplicate", -1, 0, nil, theme.Icons.DUPLICATE)
    if disabled then ImGui.EndDisabled(ctx) end

    local enter_pressed = not disabled and
      (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter))

    if not disabled and (clicked or enter_pressed) then
      reaper.SetExtState("DuplicateSubprojectVersion", "CloseAfterDuplication", close_after and "true" or "false", true)
      local ok, err = perform_duplication(name_by_file, state, close_after)
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
