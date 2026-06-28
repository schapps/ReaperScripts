-- @description Find and Select Items by Name
-- @author Stephen Schappler
-- @version 1.2
-- @about
--   ReaImGUI interface for finding and selecting items whose active take name
--   contains the search string. Scope can be limited to selected tracks.
--   Requires: Schapps Script Resources (install from this repository first).
-- @link https://www.stephenschappler.com
-- @changelog
--   6/28/26 - v1.2 Add case sensitive checkbox
--   6/28/26 - v1.1 Fix search box clearing on action; Enter key via window focus
--   6/28/26 - v1.0 Initial release with ReaImGUI interface and scope dropdown

-- ============================================================
-- ReaImGUI dependency check + bootstrap
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
-- Context + state
-- ============================================================
local script_title = "FIND ITEMS BY NAME"
local ctx = ImGui.CreateContext(script_title)

local WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
               | ImGui.WindowFlags_NoCollapse
               | ImGui.WindowFlags_AlwaysAutoResize
               | ImGui.WindowFlags_NoScrollWithMouse

local SCOPE_PROJECT = 0
local SCOPE_TRACKS  = 1
local SCOPE_ITEMS   = {"Entire Project", "Selected Track(s)"}

local saved_search     = reaper.GetExtState("FindItemsByName", "SearchString")
local saved_scope      = reaper.GetExtState("FindItemsByName", "Scope")
local saved_case       = reaper.GetExtState("FindItemsByName", "CaseSensitive")
local search_buf       = saved_search or ""
local scope            = (saved_scope ~= "" and tonumber(saved_scope)) or SCOPE_PROJECT
local case_sensitive   = saved_case == "true"
local status_msg       = ""

-- ============================================================
-- Core logic
-- ============================================================
local function findAndSelect()
  if search_buf == "" then
    status_msg = "Enter a search string"
    return
  end

  local needle = case_sensitive and search_buf or search_buf:lower()

  -- Build selected-track set when scope requires it
  local selected_tracks
  if scope == SCOPE_TRACKS then
    selected_tracks = {}
    for i = 0, reaper.CountSelectedTracks(0) - 1 do
      selected_tracks[reaper.GetSelectedTrack(0, i)] = true
    end
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  reaper.Main_OnCommand(40289, 0)  -- Item: Unselect all items

  local count = 0
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local item = reaper.GetMediaItem(0, i)
    if selected_tracks == nil or selected_tracks[reaper.GetMediaItem_Track(item)] then
      local take = reaper.GetActiveTake(item)
      if take then
        local name = case_sensitive and reaper.GetTakeName(take) or reaper.GetTakeName(take):lower()
        if name:find(needle, 1, true) then
          reaper.SetMediaItemSelected(item, true)
          count = count + 1
        end
      end
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Find and select items by name", -1)

  local word = count == 1 and "item" or "items"
  status_msg = count > 0
    and (count .. " " .. word .. " selected")
    or "No matching items found"
end

-- ============================================================
-- ImGui render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSizeConstraints(ctx, 280, 0, 9999, 9999)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    -- Search input (no EnterReturnsTrue — that flag causes the binding to return
    -- an empty buffer on the frame after Enter, which would wipe the search text)
    ImGui.SetNextItemWidth(ctx, -1)
    local _, new_buf = ImGui.InputTextWithHint(ctx, "##search", "search by take name", search_buf)
    if new_buf ~= search_buf then
      search_buf = new_buf
      reaper.SetExtState("FindItemsByName", "SearchString", search_buf, false)
      status_msg = ""
    end

    ImGui.Spacing(ctx)

    -- Scope dropdown
    ImGui.SetNextItemWidth(ctx, -1)
    local scope_changed, new_scope = ImGui.Combo(ctx, "##scope", scope,
      table.concat(SCOPE_ITEMS, "\0") .. "\0")
    if scope_changed then
      scope = new_scope
      reaper.SetExtState("FindItemsByName", "Scope", tostring(scope), true)
      status_msg = ""
    end

    ImGui.Spacing(ctx)

    -- Case sensitive checkbox
    local case_changed, new_case = ImGui.Checkbox(ctx, "Case Sensitive", case_sensitive)
    if case_changed then
      case_sensitive = new_case
      reaper.SetExtState("FindItemsByName", "CaseSensitive", tostring(case_sensitive), true)
      status_msg = ""
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Status line
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    local total = reaper.CountMediaItems(0)
    ImGui.Text(ctx, status_msg ~= "" and status_msg or (total .. " total items in project"))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    -- Find and Select button; Enter anywhere in the focused window also triggers it
    local no_input = search_buf == ""
    if no_input then ImGui.BeginDisabled(ctx, true) end
    local clicked = ImGui.Button(ctx, "Find and Select", -1, 0)
    if no_input then ImGui.EndDisabled(ctx) end

    local win_focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
    local enter_pressed = win_focused and
      (ImGui.IsKeyPressed(ctx, ImGui.Key_Enter) or ImGui.IsKeyPressed(ctx, ImGui.Key_KeypadEnter))

    if (clicked or enter_pressed) and not no_input then
      findAndSelect()
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if still_open then
    reaper.defer(loop)
  end
end

-- ============================================================
-- Entry point
-- ============================================================
reaper.defer(loop)
