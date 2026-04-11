-- @description Schapps Renamer - a fork of The Last Renamer
-- @author Aaron Cendan, modified by Stephen Schappler
-- @version 1.0
-- @about
--   # The Last Renamer (schapps fork)
--   Based on acendan_The Last Renamer v2.32 by Aaron Cendan
--   Self-contained: no external utility library dependency.
-- @provides
--   [main] .
--   Schemes/*.{yaml}
--   Meta/*.{yaml}
--   Lib/*.{lua}

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~ SCRIPT PATH & IMGUI ~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
local script_path = ({ reaper.get_action_context() })[2]:match("(.+[/\\])")

if reaper.ImGui_Key_0 then
  package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
  require 'imgui' '0.10.0.1'
else
  reaper.MB(
    "This script requires the ReaImGui API, which can be installed from:\n\nExtensions > ReaPack > Browse packages...",
    "Missing ReaImGui", 0)
  return
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~ INLINED UTILITIES ~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
local acendan = {}

-- Debug & Messages
function acendan.dbg(...)
  local args = {...}
  local str = ""
  for i = 1, #args do
    if type(args[i]) == "table" then
      str = str .. "[" .. table.concat(args[i], ", ") .. "]" .. "\n"
    else
      str = str .. tostring(args[i]) .. "\t"
    end
  end
  reaper.ShowConsoleMsg(str .. "\n")
end

function acendan.msg(msg, title)
  local title = title or "Info"
  reaper.MB(tostring(msg), title, 0)
end

-- OS / Path
function acendan.getOS()
  local win = string.find(reaper.GetOS(), "Win") ~= nil
  local sep = win and '\\' or '/'
  return win, sep
end

function acendan.pathBuilder(prefix, paths)
  local _, sep = acendan.getOS()
  local full = prefix
  for _, subpath in ipairs(paths) do
    full = full .. sep .. subpath
  end
  return full
end

-- String helpers
function acendan.stringStarts(str, start)
  return str:sub(1, #start) == start
end

function acendan.stringEnds(str, ending)
  return ending == "" or str:sub(-#ending) == ending
end

function acendan.encapsulate(str)
  if str:find("%s") then
    str = '"' .. str .. '"'
  end
  return str
end

function acendan.uncapsulate(str)
  if acendan.stringStarts(str, '"') and acendan.stringEnds(str, '"') then
    str = str:sub(2, -2)
  end
  return str
end

-- Table helpers
function acendan.tableLength(t)
  local i = 0
  for _ in pairs(t) do i = i + 1 end
  return i
end

function acendan.tableContainsVal(t, val)
  for index, value in ipairs(t) do
    if value == val then return index end
  end
  return false
end

function acendan.tableCountOccurrences(t, val)
  local occurrences = 0
  for _, value in ipairs(t) do
    if value == val then occurrences = occurrences + 1 end
  end
  return occurrences
end

-- File / Directory helpers
function acendan.fileExists(filename)
  return reaper.file_exists(filename)
end

function acendan.directoryExists(folder)
  local ok, err, code = os.rename(folder .. "/", folder .. "/")
  if not ok then
    if code == 13 then return true end
  end
  return ok, err
end

function acendan.promptForFile(message, start_dir, start_file, exts, allow_mult)
  if reaper.JS_Dialog_BrowseForSaveFile then
    local ret, file = reaper.JS_Dialog_BrowseForOpenFiles(message, start_dir or "", start_file or "", exts or "",
      allow_mult or false)
    if ret and file ~= "" then return file end
    return nil
  else
    acendan.msg(
      "Please install JS_ReaScript REAPER extension, available in Reapack extension, under ReaTeam Extensions repository.",
      "Missing JS API")
    return nil
  end
end

-- Media item selection helpers
function acendan.saveSelectedItems(items_table)
  for i = 1, reaper.CountSelectedMediaItems(0) do
    items_table[i] = reaper.GetSelectedMediaItem(0, i - 1)
  end
end

function acendan.restoreSelectedItems(items_table)
  reaper.Main_OnCommand(40289, 0) -- Unselect all media items
  for i = 1, acendan.tableLength(items_table) do
    reaper.SetMediaItemSelected(items_table[i], true)
  end
end

-- NVK folder item helpers
function acendan.isFolderItem(item)
  return select(2,
    reaper.GetSetMediaItemTakeInfo_String(reaper.GetActiveTake(item), 'P_EXT:nvk_take_source_type_v2', '', false)) ==
    'EMPTY'
end

function acendan.isTopLevelFolderItem(item, others)
  local track = reaper.GetMediaItem_Track(item)
  local parent = reaper.GetMediaTrackInfo_Value(track, "P_PARTRACK")
  local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_start + item_len
  if parent == 0 then return true end
  for _, other in ipairs(others) do
    local other_is_nvk = acendan.isFolderItem(other)
    local other_track = reaper.GetMediaItem_Track(other)
    local other_start = reaper.GetMediaItemInfo_Value(other, "D_POSITION")
    local other_len = reaper.GetMediaItemInfo_Value(other, "D_LENGTH")
    local other_end = other_start + other_len
    if other_is_nvk and parent == other_track and item_start >= other_start - 0.01 and item_end <= other_end + 0.01 then
      return false
    end
  end
  return true
end

-- Region / Marker helpers
function acendan.getRegionManagerListAndItemCount()
  local title = reaper.JS_Localize('Region/Marker Manager', 'common')
  local manager = reaper.JS_Window_Find(title, true)
  if not manager then
    reaper.Main_OnCommand(40326, 0)
    manager = reaper.JS_Window_Find(title, true)
  end
  if manager then
    reaper.DockWindowActivate(manager)
    local lv = reaper.JS_Window_FindChildByID(manager, 1071)
    local item_cnt = reaper.JS_ListView_GetItemCount(lv)
    return lv, item_cnt
  else
    reaper.MB("Unable to get Region/Marker Manager!", "Error", 0)
    return
  end
end

function acendan.getRegionsAndMarkerInManagerOrder(lv, cnt)
  local regions = {}
  local marker = {}
  for i = 0, cnt - 1 do
    local rgnMrkString_TEMP = reaper.JS_ListView_GetItemText(lv, i, 1)
    if rgnMrkString_TEMP:match("R%d") then
      local RGN_Index = string.gsub(rgnMrkString_TEMP, "R", "")
      regions[i] = tonumber(RGN_Index)
    elseif rgnMrkString_TEMP:match("M%d") then
      local MRK_Index = string.gsub(rgnMrkString_TEMP, "M", "")
      marker[i] = tonumber(MRK_Index)
    end
  end
  return regions, marker
end

function acendan.getSelectedRegions()
  local rgn_list, item_count = acendan.getRegionManagerListAndItemCount()
  if not rgn_list then return end
  local regionOrderInManager, _ = acendan.getRegionsAndMarkerInManagerOrder(rgn_list, item_count)
  if item_count == 0 then return end

  local indexSelRgn = {}
  local keys = {}
  for posInRgnMgn, markerNum in pairs(regionOrderInManager) do
    local sel = reaper.JS_ListView_GetItemState(rgn_list, posInRgnMgn)
    if sel > 1 then
      table.insert(keys, posInRgnMgn)
    end
  end
  table.sort(keys)
  for _, posInRgnMgn in ipairs(keys) do
    indexSelRgn[#indexSelRgn + 1] = regionOrderInManager[posInRgnMgn]
  end
  return indexSelRgn
end

function acendan.deleteProjectMarkers(delrgns, pos, contains, tolerance)
  tolerance = tolerance or 0.01
  local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
  local num_total = num_markers + num_regions
  if num_markers > 0 then
    local del_mkrs = {}
    local i = 0
    while i < num_total do
      local _, isrgn, mkpos, _, name, markrgnindexnumber, _ = reaper.EnumProjectMarkers3(0, i)
      if (isrgn == delrgns) and (math.abs(mkpos - pos) < 0.01) and name:find(contains) then
        del_mkrs[#del_mkrs + 1] = markrgnindexnumber
      end
      i = i + 1
    end
    for _, mkr in ipairs(del_mkrs) do
      reaper.DeleteProjectMarker(0, mkr, false)
    end
  end
end

-- ImGui style tables (defined after require 'imgui')
acendan.ImGui_Styles = {}
acendan.ImGui_Styles.colors = {
  { reaper.ImGui_Col_DragDropTarget,       0xCDA4DEFF },
  { reaper.ImGui_Col_FrameBg,              0x72727224 },
  { reaper.ImGui_Col_FrameBgHovered,       0x80808064 },
  { reaper.ImGui_Col_FrameBgActive,        0x80808080 },
  { reaper.ImGui_Col_CheckMark,            0xCDA4DEFF },
  { reaper.ImGui_Col_TitleBg,              0xB19CD932 },
  { reaper.ImGui_Col_TitleBgCollapsed,     0xB19CD932 },
  { reaper.ImGui_Col_TitleBgActive,        0x5A3F78CC },
  { reaper.ImGui_Col_Button,               0x60606066 },
  { reaper.ImGui_Col_ButtonHovered,        0x606060FF },
  { reaper.ImGui_Col_ButtonActive,         0x808080FF },
  { reaper.ImGui_Col_Text,                 0xFFFFFFDE },
  { reaper.ImGui_Col_TextDisabled,         0xFFFFFF61 },
  { reaper.ImGui_Col_TextSelectedBg,       0xD8BFD864 },
  { reaper.ImGui_Col_ResizeGrip,           0x80808000 },
  { reaper.ImGui_Col_ResizeGripHovered,    0x80808000 },
  { reaper.ImGui_Col_ResizeGripActive,     0x80808000 },
  { reaper.ImGui_Col_Separator,            0x80808080 },
  { reaper.ImGui_Col_SeparatorHovered,     0x808080C7 },
  { reaper.ImGui_Col_SeparatorActive,      0x808080FF },
  { reaper.ImGui_Col_Tab,                  0x60606066 },
  { reaper.ImGui_Col_TabHovered,           0x606060FF },
  { reaper.ImGui_Col_TabSelected,          0x6C6C6CFF },
  { reaper.ImGui_Col_WindowBg,             0x282828FF },
  { reaper.ImGui_Col_PopupBg,              0x1F1F1FF0 },
  { reaper.ImGui_Col_ScrollbarBg,          0x18181887 },
  { reaper.ImGui_Col_Header,               0x60606066 },
  { reaper.ImGui_Col_HeaderHovered,        0x606060FF },
  { reaper.ImGui_Col_HeaderActive,         0x808080FF },
  { reaper.ImGui_Col_TableRowBg,           0xFFFFFF00 },
  { reaper.ImGui_Col_TableRowBgAlt,        0xFFFFFF04 },
  { reaper.ImGui_Col_SliderGrab,           0xCDA4DEC8 },
  { reaper.ImGui_Col_SliderGrabActive,     0xD8BFD4DD },
  { reaper.ImGui_Col_PlotLines,            0xB19CD9FF },
  { reaper.ImGui_Col_PlotLinesHovered,     0xB19CD9FF },
  { reaper.ImGui_Col_PlotHistogram,        0xB19CD932 },
  { reaper.ImGui_Col_PlotHistogramHovered, 0xB19CD932 },
  { reaper.ImGui_Col_DockingPreview,       1123734963 },
  { reaper.ImGui_Col_TabDimmed,            640034552  },
  { reaper.ImGui_Col_TabDimmedSelected,    1819045119 },
  { reaper.ImGui_Col_Border,               -2139062144 },
  { reaper.ImGui_Col_TableBorderLight,     993737727  },
  { reaper.ImGui_Col_TableBorderStrong,    1330597887 },
  { reaper.ImGui_Col_TableHeaderBg,        858993663  },
}
acendan.ImGui_Styles.vars = {
  { reaper.ImGui_StyleVar_Alpha(),               1.0 },
  { reaper.ImGui_StyleVar_DisabledAlpha(),       0.6 },
  { reaper.ImGui_StyleVar_WindowPadding(),       { 8, 4 } },
  { reaper.ImGui_StyleVar_FramePadding(),        { 4, 3 } },
  { reaper.ImGui_StyleVar_CellPadding(),         { 4, 4 } },
  { reaper.ImGui_StyleVar_ItemSpacing(),         { 4, 4 } },
  { reaper.ImGui_StyleVar_ItemInnerSpacing(),    { 4, 4 } },
  { reaper.ImGui_StyleVar_IndentSpacing(),       21 },
  { reaper.ImGui_StyleVar_ScrollbarSize(),       14 },
  { reaper.ImGui_StyleVar_GrabMinSize(),         12 },
  { reaper.ImGui_StyleVar_WindowBorderSize(),    1 },
  { reaper.ImGui_StyleVar_ChildBorderSize(),     1 },
  { reaper.ImGui_StyleVar_PopupBorderSize(),     1 },
  { reaper.ImGui_StyleVar_FrameBorderSize(),     0 },
  { reaper.ImGui_StyleVar_WindowRounding(),      8 },
  { reaper.ImGui_StyleVar_ChildRounding(),       0 },
  { reaper.ImGui_StyleVar_FrameRounding(),       2 },
  { reaper.ImGui_StyleVar_PopupRounding(),       4 },
  { reaper.ImGui_StyleVar_ScrollbarRounding(),   4 },
  { reaper.ImGui_StyleVar_GrabRounding(),        2 },
  { reaper.ImGui_StyleVar_TabRounding(),         2 },
  { reaper.ImGui_StyleVar_WindowTitleAlign(),    { 0.5, 0.5 } },
  { reaper.ImGui_StyleVar_ButtonTextAlign(),     { 0.5, 0.5 } },
  { reaper.ImGui_StyleVar_SelectableTextAlign(), { 0, 0.5 } },
}
acendan.ImGui_Styles.scalable = {
  reaper.ImGui_StyleVar_WindowPadding(),
  reaper.ImGui_StyleVar_FramePadding(),
  reaper.ImGui_StyleVar_CellPadding(),
  reaper.ImGui_StyleVar_ItemSpacing(),
  reaper.ImGui_StyleVar_ItemInnerSpacing(),
  reaper.ImGui_StyleVar_IndentSpacing(),
  reaper.ImGui_StyleVar_ScrollbarSize(),
  reaper.ImGui_StyleVar_GrabMinSize(),
}
acendan.ImGui_Styles.font = nil

-- Hacky ChildWindow flag for autofill combo
if not reaper.ImGui_WindowFlags_ChildWindow then
  reaper.ImGui_WindowFlags_ChildWindow = function() return 1 << 24 end
end
acendan.ImGui_AutoFillComboFlags = reaper.ImGui_WindowFlags_ChildWindow() | reaper.ImGui_WindowFlags_NoMove()

-- ImGui settings persistence (ExtState)
function acendan.ImGui_GetSetting(key, default)
  return reaper.HasExtState("acendan_imgui", key) and reaper.GetExtState("acendan_imgui", key) or default
end

function acendan.ImGui_GetSettingBool(key, default)
  return acendan.ImGui_GetSetting(key, default and "true" or "false") == "true"
end

function acendan.ImGui_SetSetting(key, value)
  return reaper.SetExtState("acendan_imgui", key, value, true)
end

function acendan.ImGui_SetSettingBool(key, value)
  return acendan.ImGui_SetSetting(key, tostring(value))
end

-- ImGui color helper
function acendan.ImGui_HSV(h, s, v, a)
  local r, g, b = reaper.ImGui_ColorConvertHSVtoRGB(h, s, v)
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a or 1.0)
end

-- ImGui font & scale
function acendan.ImGui_SetFont(font_name, font_size)
  font_name = font_name or "Arial"
  font_size = math.floor((font_size or 14) * acendan.ImGui_GetScale())
  if acendan.ImGui_Styles.font then reaper.ImGui_Detach(ctx, acendan.ImGui_Styles.font) end
  acendan.ImGui_Styles.font = reaper.ImGui_CreateFont(font_name, font_size)
  reaper.ImGui_Attach(ctx, acendan.ImGui_Styles.font)
end

function acendan.ImGui_GetScale()
  return acendan.ImGui_GetSetting("ui_scale", 1.0)
end

function acendan.ImGui_SetScale(scale)
  acendan.ImGui_SetSetting("ui_scale", scale or acendan.ImGui_GetScale())
end

function acendan.ImGui_ScaleSlider(flags)
  local scale = acendan.ImGui_GetSetting("ui_scale", 1.0)
  local rv, scale = reaper.ImGui_SliderDouble(ctx, "UI Scale", scale, 0.5, 3.0, "%.2f",
    flags or reaper.ImGui_SliderFlags_AlwaysClamp())
  if rv then
    acendan.ImGui_SetSetting("ui_scale", scale)
    return true
  end
  acendan.ImGui_Tooltip("Adjust the scale of the GUI elements.\n\nCtrl+Click to type in values.")
  return false
end

-- ImGui style push/pop
function acendan.ImGui_PushStyles()
  local scale = acendan.ImGui_GetSetting("ui_scale", 1.0)
  for idx, value in ipairs(acendan.ImGui_Styles.colors) do
    if value[1] then
      reaper.ImGui_PushStyleColor(ctx, value[1](), value[2])
    else
      acendan.dbg("ImGui style color has been removed at acendan.ImGui_Styles.colors index:" .. idx)
    end
  end
  for _, value in ipairs(acendan.ImGui_Styles.vars) do
    local style_var = value[1]
    local style_val = value[2]
    local is_table = type(style_val) == "table"
    if acendan.tableContainsVal(acendan.ImGui_Styles.scalable, style_var) then
      if is_table then
        style_val = { style_val[1] * scale, style_val[2] * scale }
      else
        style_val = style_val * scale
      end
    end
    if is_table then
      reaper.ImGui_PushStyleVar(ctx, style_var, style_val[1], style_val[2])
    else
      reaper.ImGui_PushStyleVar(ctx, style_var, style_val)
    end
  end
  reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx))
end

function acendan.ImGui_PopStyles()
  reaper.ImGui_PopStyleColor(ctx, #acendan.ImGui_Styles.colors)
  reaper.ImGui_PopStyleVar(ctx, #acendan.ImGui_Styles.vars)
  reaper.ImGui_PopFont(ctx)
end

-- ImGui widgets
function acendan.ImGui_HelpMarker(desc, wrap_pos)
  wrap_pos = wrap_pos or 18.0
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextDisabled(ctx, '(?)')
  acendan.ImGui_Tooltip(desc, wrap_pos)
end

function acendan.ImGui_Tooltip(desc, wrap_pos)
  wrap_pos = wrap_pos or 18.0
  if reaper.ImGui_IsItemHovered(ctx) then
    if reaper.ImGui_BeginTooltip(ctx) then
      reaper.ImGui_PushTextWrapPos(ctx, reaper.ImGui_GetFontSize(ctx) * wrap_pos)
      reaper.ImGui_Text(ctx, desc)
      reaper.ImGui_PopTextWrapPos(ctx)
      reaper.ImGui_EndTooltip(ctx)
    end
  end
end

function acendan.ImGui_Button(label, callback, color)
  local col_normal, col_hover, col_active
  if type(color) == "table" then
    -- RGB mode: color = {r, g, b} in 0-255
    local r, g, b = color[1] / 255, color[2] / 255, color[3] / 255
    col_normal = reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, 1.0)
    col_hover  = reaper.ImGui_ColorConvertDouble4ToU32(math.min(r * 1.3, 1), math.min(g * 1.3, 1), math.min(b * 1.3, 1), 1.0)
    col_active = reaper.ImGui_ColorConvertDouble4ToU32(math.min(r * 1.6, 1), math.min(g * 1.6, 1), math.min(b * 1.6, 1), 1.0)
  else
    -- Hue mode: color = hue in 0-1
    col_normal = acendan.ImGui_HSV(color, 0.5, 0.5, 1.0)
    col_hover  = acendan.ImGui_HSV(color, 0.7, 0.7, 1.0)
    col_active = acendan.ImGui_HSV(color, 0.8, 0.8, 1.0)
  end
  reaper.ImGui_PushID(ctx, 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        col_normal)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), col_hover)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  col_active)
  if reaper.ImGui_Button(ctx, label) then
    reaper.PreventUIRefresh(1)
    reaper.Undo_BeginBlock()
    callback()
    reaper.Undo_EndBlock(label, -1)
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
  end
  reaper.ImGui_PopStyleColor(ctx, 3)
  reaper.ImGui_PopID(ctx)
end

function acendan.ImGui_ComboBox(ctx, title, items, selected)
  local ret = nil
  if reaper.ImGui_BeginCombo(ctx, title, items[selected]) then
    for i, value in ipairs(items) do
      local is_selected = selected == i
      if reaper.ImGui_Selectable(ctx, value, is_selected) then
        ret = { i, value }
      end
      if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushItemFlag(ctx, reaper.ImGui_ItemFlags_NoTabStop(), true)
  if reaper.ImGui_SmallButton(ctx, 'x##' .. title) then
    ret = { 0, "" }
  end
  reaper.ImGui_PopItemFlag(ctx)
  acendan.ImGui_Tooltip("Clear selection.")
  if ret then return true, ret[1], ret[2] end
end

function acendan.ImGui_AutoFillComboBox(ctx, title, items, selected, filter)
  assert(filter, "ImGui_AutoFillComboBox: filter is nil. Please create a filter with ImGui_TextFilter_Create()")
  local ret = nil
  local rv, str = reaper.ImGui_InputText(ctx, title .. "##" .. title .. "_filter",
    reaper.ImGui_TextFilter_Get(filter), reaper.ImGui_InputTextFlags_EscapeClearsAll())
  if rv and reaper.ImGui_IsItemActive(ctx) then reaper.ImGui_TextFilter_Set(filter, str) end
  local tabbed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Tab()) and
      not reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
  local arrowed = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_DownArrow()) or
      reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_UpArrow())
  local filteractive = reaper.ImGui_IsItemActive(ctx)
  local filterfocused = reaper.ImGui_IsItemFocused(ctx)
  local clicked = false
  local focused = false
  if filteractive then reaper.ImGui_OpenPopup(ctx, title .. "_popup") end
  local visible_items = {}
  local x_l, y_hi = reaper.ImGui_GetItemRectMin(ctx)
  local x_r, y_lo = reaper.ImGui_GetItemRectMax(ctx)
  reaper.ImGui_SetNextWindowPos(ctx, x_l, y_lo, reaper.ImGui_Cond_Always(), 0, 0)
  if reaper.ImGui_BeginPopup(ctx, title .. "_popup", acendan.ImGui_AutoFillComboFlags) then
    if not filterfocused and reaper.ImGui_IsWindowFocused(ctx) then reaper.ImGui_SetNextWindowFocus(ctx) end
    if arrowed and not reaper.ImGui_IsAnyItemFocused(ctx) then
      reaper.ImGui_SetWindowFocusEx(ctx, title .. "_popup")
    end
    if reaper.ImGui_BeginListBox(ctx, "##" .. title .. "_listbox") then
      for i, item in ipairs(items) do
        if reaper.ImGui_TextFilter_PassFilter(filter, item) then
          visible_items[#visible_items + 1] = item
          if reaper.ImGui_Selectable(ctx, item, item == items[selected]) then
            ret = { i, item }
            clicked = true
          end
          if arrowed and not focused and not reaper.ImGui_IsAnyItemFocused(ctx) and
              reaper.ImGui_IsItemVisible(ctx) then
            reaper.ImGui_SetKeyboardFocusHere(ctx, -1)
            focused = true
          end
        end
      end
      reaper.ImGui_EndListBox(ctx)
    end
    if tabbed or clicked then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end
  if tabbed and #visible_items > 0 then
    local first_visible_item = visible_items[1]
    ret = { acendan.tableContainsVal(items, first_visible_item), first_visible_item }
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushItemFlag(ctx, reaper.ImGui_ItemFlags_NoTabStop(), true)
  if reaper.ImGui_SmallButton(ctx, 'x##' .. title) then
    ret = { 0, "" }
    reaper.ImGui_TextFilter_Clear(filter)
  end
  reaper.ImGui_PopItemFlag(ctx)
  acendan.ImGui_Tooltip("Clear selection.")
  if filteractive and (tabbed or clicked) then reaper.ImGui_SetKeyboardFocusHere(ctx) end
  if ret then
    reaper.ImGui_TextFilter_Set(filter, ret[2])
    return true, ret[1], ret[2]
  end
end

-- YAML loader (uses script-relative Lib/yaml.lua)
acendan.loadYaml = function(filename)
  local _, sep = acendan.getOS()
  local yamllib = script_path .. "Lib" .. sep .. "yaml.lua"
  if not yaml and reaper.file_exists(yamllib) then dofile(yamllib) end
  if not yaml then
    acendan.msg("Failed to load YAML library!\n\nExpected: " .. yamllib, "The Last Renamer")
    return nil
  end
  if not reaper.file_exists(filename) then return nil end

  local function readAll(file)
    local f = io.open(file, "rb")
    local content = f:read("*all")
    f:close()
    return content
  end
  local content = readAll(filename)

  -- Replace $wildcards
  local new_content = ""
  local wildcards = {}
  for line in content:gmatch("([^\r\n]*)\r?\n?") do
    if line:sub(1, 1) == "$" and line:find(":") then
      local wc_key = line:match("%$(.-):")
      local wc_val = line:match(": (.*)")
      wildcards[wc_key] = wc_val
      line = ""
    else
      for k, v in pairs(wildcards) do
        line = line:gsub("%$" .. k, v)
      end
    end
    if #line > 0 then
      new_content = new_content .. line .. "\r\n"
    end
  end
  content = new_content

  return yaml.eval(content)
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ CONSTANTS ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

local WIN, SEP = acendan.getOS()
local SCRIPT_NAME = ({ reaper.get_action_context() })[2]:match("([^/\\_]+)%.lua$")
local SCRIPT_DIR  = ({ reaper.get_action_context() })[2]:sub(1,
  ({ reaper.get_action_context() })[2]:find(SEP .. "[^" .. SEP .. "]*$"))

local WINDOW_SIZE  = { width = 500, height = 100 }
local WINDOW_FLAGS = reaper.ImGui_WindowFlags_NoCollapse() | reaper.ImGui_WindowFlags_AlwaysAutoResize()
local CONFIG_FLAGS = reaper.ImGui_ConfigFlags_DockingEnable() | reaper.ImGui_ConfigFlags_NavEnableKeyboard()
local SLIDER_FLAGS = reaper.ImGui_SliderFlags_AlwaysClamp()
local FLT_MIN, FLT_MAX = reaper.ImGui_NumericLimits_Float()
local DBL_MIN, DBL_MAX = reaper.ImGui_NumericLimits_Double()

local SCHEMES_DIR = SCRIPT_DIR .. "Schemes" .. SEP
local BACKUPS_DIR = SCRIPT_DIR .. "Backups" .. SEP
local META_DIR    = SCRIPT_DIR .. "Meta" .. SEP

local META_MKR_PREFIX = "#META"

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ FUNCTIONS ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

function Init()
  wgt = {}
  wgt.schemes  = FetchSchemes()
  wgt.scheme   = GetPreviousValue("scheme", wgt.schemes[1])
  wgt.data     = nil
  wgt.meta     = nil
  wgt.name     = ""
  wgt.preset   = {}
  wgt.history  = {}
  wgt.dragdrop = {}
  wgt.serialize = {}
  wgt.values   = {}
  wgt.last_selected_item = nil

  wgt.targets = {}
  wgt.targets.Regions = { "Selected", "All", "Time Selection", "Edit Cursor" }
  wgt.targets.Items   = { "Selected", "All" }
  wgt.targets.Tracks  = { "Selected", "All" }

  if not LoadScheme(wgt.scheme) then wgt.scheme = nil end

  ctx = reaper.ImGui_CreateContext(SCRIPT_NAME, CONFIG_FLAGS)
  acendan.ImGui_SetFont()
  local scale = acendan.ImGui_GetScale()
  reaper.ImGui_SetNextWindowSize(ctx, 0, WINDOW_SIZE.height * scale)
  acendan.ImGui_SetScale(scale)
end

function LoadField(field)
  local unskippable = (field.skip and field.skip == false) or not field.skip
  local meta = field.meta and true or false
  local sep = (wgt.name == "" or meta) and "" or field.separator and field.separator or wgt.data.separator
  local value = ""
  local wildcard_help = ""
  local serialize = meta and wgt.meta.serialize or wgt.serialize

  if meta and not field.value then return end

  if type(field.value) == "number" or field.numwild then
    local rv, str = reaper.ImGui_InputText(ctx, field.field, tostring(field.value))
    if rv then
      if tonumber(str) then
        field.value = tonumber(str)
        field.numwild = false
      elseif str == "$num" then
        field.value = str
        field.numwild = true
      end
      AppendSerializedField(serialize, field.field, field.value)
    end
    if not meta then
      wgt.enumeration = {
        start    = field.value,
        zeroes   = field.zeroes or 1,
        singles  = field.singles or false,
        wildcard = "$enum",
        sep      = sep
      }
      value = field.numwild and "$num" or wgt.enumeration.wildcard
      wildcard_help = wildcard_help .. "$num: Use project number from renaming target.\n"
    end

  elseif type(field.value) == "string" then
    local rv, str = reaper.ImGui_InputTextWithHint(ctx, field.field, field.hint, field.value)
    if rv then
      field.value = str
      AppendSerializedField(serialize, field.field, field.value)
    end
    if not meta then
      value = field.value
      wildcard_help = wildcard_help .. "$name: Use original name from renaming target.\n"
    end

  elseif type(field.value) == "table" then
    if not field.selected then field.selected = field.default or 0 end
    if not field.filter then
      field.filter = reaper.ImGui_CreateTextFilter(field.value[field.selected] or "")
      reaper.ImGui_Attach(ctx, field.filter)
    end
    local rv, rownum, rowtext
    if GetPreviousValue("opt_autofill", false) == "true" then
      rv, rownum, rowtext = acendan.ImGui_AutoFillComboBox(ctx, field.field, field.value, field.selected, field.filter)
    else
      rv, rownum, rowtext = acendan.ImGui_ComboBox(ctx, field.field, field.value, field.selected)
    end
    if rv then
      field.selected = rownum
      AppendSerializedField(serialize, field.field, field.selected)
    end
    if not meta then
      value = (field.selected and field.short) and field.short[field.selected] or
          (field.selected) and field.value[field.selected] or ""
    end

  elseif type(field.value) == "boolean" then
    local rv, bool = reaper.ImGui_Checkbox(ctx, field.field, field.value)
    if rv then
      field.value = bool
      AppendSerializedField(serialize, field.field, field.value)
    end
    if not meta then
      value = field.value and field.btrue or field.bfalse
    end
  end

  if unskippable and value ~= "" and not meta then
    if field.capitalization then value = Capitalize(value, field.capitalization) end
    wgt.name = wgt.name .. sep .. value
    wgt.values[#wgt.values + 1] = value
  end

  local empty_short = (field.selected and field.short) and field.short[field.selected] == "" or false
  if field.required and value == "" and not empty_short then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, 0xFF0000FF, "*")
    if wgt.required == "" then wgt.required = field.field end
  end

  if field.help and wildcard_help ~= "" then
    acendan.ImGui_HelpMarker(field.help .. "\n\nWildcards\n" .. wildcard_help)
  elseif field.help then
    acendan.ImGui_HelpMarker(field.help)
  elseif wildcard_help ~= "" then
    acendan.ImGui_HelpMarker("Wildcards\n" .. wildcard_help)
  end
end

function PassesIDCheck(field, parent)
  if field.id == nil then return true end
  if not parent then return false end
  if type(field.id) == "table" then
    for i, id in ipairs(field.id) do
      if parent.value[parent.selected] == id then return true end
    end
    return false
  end
  if type(field.id) == "boolean" then
    return parent.value == field.id
  end
  return parent.value[parent.selected] == field.id
end

function LoadFields(fields, parent)
  for i, field in ipairs(fields) do
    if PassesIDCheck(field, parent) then
      LoadField(field)
      if field.fields then LoadFields(field.fields, field) end
    end
  end
end

function LoadTargets()
  if not wgt.target then wgt.target = GetPreviousValue("target", nil) end
  if not wgt.mode   then wgt.mode   = GetPreviousValue("mode",   nil) end

  if reaper.ImGui_BeginCombo(ctx, "Target", wgt.target) then
    for target, modes in pairs(wgt.targets) do
      if reaper.ImGui_Selectable(ctx, target, wgt.target == target) then
        wgt.target = target
        SetCurrentValue("target", target)
        wgt.mode = nil
        DeleteCurrentValue("mode")
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  if wgt.target then
    if reaper.ImGui_BeginCombo(ctx, "Mode", wgt.mode) then
      for i, mode in ipairs(wgt.targets[wgt.target]) do
        if reaper.ImGui_Selectable(ctx, mode, wgt.mode == mode) then
          wgt.mode = mode
          SetCurrentValue("mode", mode)
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end
  end

  if wgt.target == "Items" then
    if not wgt.overlap then wgt.overlap = GetPreviousValue("opt_overlap", false) == "true" end
    local rv, overlap = reaper.ImGui_Checkbox(ctx, "Respect Overlaps", wgt.overlap)
    if rv then
      wgt.overlap = overlap
      SetCurrentValue("opt_overlap", overlap)
    end
    acendan.ImGui_Tooltip("If checked, enumeration will not increment on items that overlap with neighbors on this track.")
  end

  if wgt.target == "Items" and wgt.mode == "Selected" and GetPreviousValue("opt_nvk_only", false) == "true" then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, 0x13BD99FF, "NVK")
    acendan.ImGui_Tooltip(
      "Only NVK Folder Items will be targeted when set to 'Items - Selected'.\n\nDisable this option in Settings if you want to target standard media items.")
  end
end

function ValidateFields(preview_name)
  wgt.invalid = nil
  if wgt.required ~= "" then
    wgt.invalid = "Missing field: " .. wgt.required; return
  end
  if wgt.name == "" then
    wgt.invalid = "Generated name is blank!"; return
  end
  if not wgt.target then
    wgt.invalid = "Please set a renaming target!"; return
  end
  if wgt.target and not wgt.mode then
    wgt.invalid = "Please set a renaming mode for target: " .. wgt.target; return
  end
  if wgt.data.maxchars and preview_name and #preview_name > wgt.data.maxchars then
    wgt.invalid = "Name length (" .. #preview_name .. ") exceeds max num characters (" .. wgt.data.maxchars .. ")."; return
  end
  if not wgt.data.dupes and #wgt.values > 0 then
    local dupes_tbl = {}
    for _, value in ipairs(wgt.values) do
      if wgt.data.separator and value:find(wgt.data.separator) then
        for part in value:gmatch("[^" .. wgt.data.separator .. "]+") do
          dupes_tbl[#dupes_tbl + 1] = part:lower()
        end
      else
        dupes_tbl[#dupes_tbl + 1] = value:lower()
      end
    end
    for _, value in ipairs(dupes_tbl) do
      if acendan.tableCountOccurrences(dupes_tbl, value:lower()) > 1 then
        wgt.invalid = "Duplicate field found: " .. value; return
      end
    end
  end
end

function FindField(fields, field)
  local field_name = field:match("([^:]+)")
  local field_ids = {}
  for id in field:gmatch(":(%w+)") do
    field_ids[#field_ids + 1] = id
  end
  for _, f in ipairs(fields) do
    if f.field == field_name then
      if #field_ids == 0 then return f end
      if f.id then
        for _, id in ipairs(field_ids) do
          if type(f.id) == "table" and acendan.tableContainsVal(f.id, id) or f.id == id then return f end
        end
      end
    end
    if f.fields then
      local find_field = FindField(f.fields, field)
      if find_field then return find_field end
    end
  end
end

function ClickLoadPreset()
  local preset = wgt.preset.presets[wgt.preset.idx]
  for field, value in pairs(preset) do
    if field ~= "preset" then
      local find_field = FindField(wgt.data.fields, field)
      if find_field then SetFieldValue(find_field, value) end
    end
  end
  wgt.serialize = {}
end

function LoadPresets()
  reaper.ImGui_SameLine(ctx)
  local scale = acendan.ImGui_GetScale()
  local btn_pad = 4 * scale * 2   -- FramePadding.x (4) * scale * 2 sides
  local btn_gap = 4 * scale       -- ItemSpacing.x (4) * scale
  local presets_w = reaper.ImGui_CalcTextSize(ctx, "Presets") + btn_pad
  local history_w = reaper.ImGui_CalcTextSize(ctx, "History") + btn_pad
  local total_w = presets_w + history_w + btn_gap
  reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + reaper.ImGui_GetContentRegionAvail(ctx) - total_w)
  if reaper.ImGui_Button(ctx, "Presets") then
    RecallPresets()
    reaper.ImGui_OpenPopup(ctx, "PresetPopup")
  end
  if reaper.ImGui_BeginPopup(ctx, "PresetPopup") then
    local items = {}
    for _, preset in ipairs(wgt.preset.presets) do
      items[#items + 1] = preset.preset
    end
    if reaper.ImGui_BeginListBox(ctx, "##PresetsList", -FLT_MIN,
        5 * reaper.ImGui_GetTextLineHeightWithSpacing(ctx)) then
      for n, v in ipairs(items) do
        local is_selected = wgt.preset.idx == n
        if reaper.ImGui_Selectable(ctx, v .. "##" .. tostring(n), is_selected,
            reaper.ImGui_SelectableFlags_AllowDoubleClick()) then
          wgt.preset.idx = n
          if reaper.ImGui_IsMouseDoubleClicked(ctx, reaper.ImGui_MouseButton_Left()) then
            ClickLoadPreset()
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
        end
        if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndListBox(ctx)
    end

    local enabled = wgt.preset.idx and wgt.preset.idx > 0
    if not enabled then reaper.ImGui_BeginDisabled(ctx) end
    acendan.ImGui_Button("Load", ClickLoadPreset, 0.42)
    acendan.ImGui_Tooltip(
      "Loads the selected preset into the naming fields.\n\nPro Tip: Double-click a preset to load and close this menu.")

    reaper.ImGui_SameLine(ctx)
    acendan.ImGui_Button("Overwrite", function()
      local preset = wgt.preset.presets[wgt.preset.idx].preset
      DeletePreset(wgt.preset.idx)
      StorePreset(preset)
    end, 0.15)
    acendan.ImGui_Tooltip("Overwrites the selected preset with the current naming fields.")

    reaper.ImGui_SameLine(ctx)
    acendan.ImGui_Button("Delete", function()
      DeletePreset(wgt.preset.idx)
      wgt.preset.idx = nil
    end, 0)
    if not enabled then reaper.ImGui_EndDisabled(ctx) end
    acendan.ImGui_Tooltip("Permanently deletes the selected preset.")

    reaper.ImGui_Separator(ctx)
    local rv, new_preset = reaper.ImGui_InputTextWithHint(ctx, "##new_preset", "Preset Name", wgt.preset.new)
    if rv then wgt.preset.new = new_preset end
    reaper.ImGui_SameLine(ctx)
    local enabled = wgt.preset.new and wgt.preset.new ~= ""
    if not enabled then reaper.ImGui_BeginDisabled(ctx) end
    acendan.ImGui_Button("Save", function()
      StorePreset(wgt.preset.new)
      wgt.preset.new = ""
    end, 0.42)
    acendan.ImGui_Tooltip("Saves the current naming fields as a new preset.")
    if not enabled then reaper.ImGui_EndDisabled(ctx) end

    reaper.ImGui_EndPopup(ctx)
  end
end

function ClickLoadHistory()
  local history = wgt.history.presets[wgt.history.idx]
  for field, value in pairs(history) do
    if field ~= "history" then
      local find_field = FindField(wgt.data.fields, field)
      if find_field then SetFieldValue(find_field, value) end
    end
  end
  wgt.serialize = {}
end

function LoadHistory()
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "History") then
    reaper.ImGui_OpenPopup(ctx, "HistoryPopup")
  end
  if reaper.ImGui_BeginPopup(ctx, "HistoryPopup") then
    local items = {}
    for _, history in ipairs(wgt.history.presets) do
      items[#items + 1] = history.history
    end
    if reaper.ImGui_BeginListBox(ctx, "##HistoryList", 300, 5 * reaper.ImGui_GetTextLineHeightWithSpacing(ctx)) then
      for n, v in ipairs(items) do
        local is_selected = wgt.history.idx == n
        if reaper.ImGui_Selectable(ctx, v .. "##" .. tostring(n), is_selected,
            reaper.ImGui_SelectableFlags_AllowDoubleClick()) then
          wgt.history.idx = n
          if reaper.ImGui_IsMouseDoubleClicked(ctx, reaper.ImGui_MouseButton_Left()) then
            ClickLoadHistory()
            reaper.ImGui_CloseCurrentPopup(ctx)
          end
        end
        acendan.ImGui_Tooltip(v)
        if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
      reaper.ImGui_EndListBox(ctx)
    end

    local enabled = wgt.history.idx and wgt.history.idx > 0
    if not enabled then reaper.ImGui_BeginDisabled(ctx) end
    acendan.ImGui_Button("Load", ClickLoadHistory, 0.42)
    acendan.ImGui_Tooltip(
      "Loads the selected history into the naming fields.\n\nPro Tip: Double-click a history to load and close this menu.")
    if not enabled then reaper.ImGui_EndDisabled(ctx) end

    reaper.ImGui_EndPopup(ctx)
  end
end

function TabNaming()
  if not LoadScheme(wgt.scheme) then
    wgt.load_failed = wgt.load_failed or
        (wgt.scheme and "Failed to load scheme:  " .. wgt.scheme or "Failed to load scheme!")
    reaper.ImGui_TextColored(ctx, 0xFFFF00BB,
      wgt.load_failed .. "\n\nPlease select a new scheme in the Settings tab.")
    wgt.scheme = nil
    return
  end
  wgt.load_failed = nil
  wgt.name     = ""
  wgt.required = ""
  wgt.values   = {}

  reaper.ImGui_AlignTextToFramePadding(ctx)
  reaper.ImGui_Text(ctx, wgt.data.title)
  reaper.ImGui_PushItemFlag(ctx, reaper.ImGui_ItemFlags_NoTabStop(), true)
  LoadPresets()
  LoadHistory()
  reaper.ImGui_PopItemFlag(ctx)
  local ext_app_btn = GetPreviousValue("opt_ext_app_btn", "None")
  if ext_app_btn == "Open Minori" then
    local localappdata = os.getenv("LOCALAPPDATA")
    if localappdata then
      if reaper.ImGui_Button(ctx, "Open Minori") then
        reaper.ExecProcess('"' .. localappdata .. '\\Programs\\Minori\\Minori.exe"', -1)
      end
    end
  elseif ext_app_btn == "Open Minoru" then
    if reaper.ImGui_Button(ctx, "Open Minoru") then
      reaper.ExecProcess('"C:\\Program Files\\Minoru\\Minoru.exe"', -1)
    end
  end
  reaper.ImGui_SeparatorText(ctx, "Naming Scheme")
  LoadFields(wgt.data.fields)

  local capture_label = "Capture Name"
  Button(capture_label, function()
    local sel_item = reaper.GetSelectedMediaItem(0, 0)
    if sel_item then AutoFillFromItem(sel_item, true) end
  end, "Captures the name of the currently selected item and populates the naming fields.\n\nUse this when Auto Populate is off, or to force-capture an item that doesn't match the current scheme.")

  reaper.ImGui_SameLine(ctx)
  local clear_label = "Clear All Fields"
  Button(clear_label, function()
    ClearFields(wgt.data.title, wgt.data.fields)
    SetScheme(wgt.scheme)
  end, "Clears out all fields, restoring them to their default state.")
  if not wgt.data then return end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, "Targets")
  LoadTargets()

  local preview_name = SanitizeName(wgt.name, wgt.enumeration, {}, true)
  ValidateFields(preview_name)
  reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + 20)
  reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx) * 1.5)
  if wgt.invalid then reaper.ImGui_BeginDisabled(ctx) end
  acendan.ImGui_Button("Rename", ApplyName, {86, 64, 110})
  if wgt.invalid then reaper.ImGui_EndDisabled(ctx) end
  reaper.ImGui_PopFont(ctx)
  acendan.ImGui_Tooltip("Applies your name to the given target!\n\nPro Tip: You can press the 'Enter' key to trigger renaming from any of the fields above.")

  local export_path = GetPreviousValue("opt_export_script", nil)
  local has_export = export_path and export_path ~= "" and export_path ~= "false"
  reaper.ImGui_SameLine(ctx, 0, 40)
  if not has_export then reaper.ImGui_BeginDisabled(ctx) end
  reaper.ImGui_PushFont(ctx, acendan.ImGui_Styles.font, reaper.ImGui_GetFontSize(ctx) * 1.5)
  acendan.ImGui_Button("Export", function()
    if reaper.file_exists(export_path) then
      local cmd_id = reaper.AddRemoveReaScript(true, 0, export_path, false)
      if cmd_id and cmd_id > 0 then
        reaper.Main_OnCommandEx(cmd_id, 0, 0)
      end
    else
      acendan.msg("Export script not found:\n\n" .. export_path, "Export")
    end
  end, {70, 160, 210})
  reaper.ImGui_PopFont(ctx)
  acendan.ImGui_Tooltip("Runs the export script configured in the Settings tab.")
  if not has_export then reaper.ImGui_EndDisabled(ctx) end

  if wgt.invalid then
    reaper.ImGui_TextColored(ctx, 0xFFFF00BB, wgt.invalid)
  elseif wgt.error then
    reaper.ImGui_TextColored(ctx, 0xFF0000FF, wgt.error)
  elseif reaper.ImGui_IsKeyReleased(ctx, reaper.ImGui_Key_Enter()) then
    ApplyName()
  end

  reaper.ImGui_SetCursorPosY(ctx, reaper.ImGui_GetCursorPosY(ctx) + 20)
  reaper.ImGui_SeparatorText(ctx, "Name Preview")

  reaper.ImGui_PushTextWrapPos(ctx, 0.0)
  reaper.ImGui_TextColored(ctx, 0xFFFFFFFF, preview_name)
  reaper.ImGui_PopTextWrapPos(ctx)
  if wgt.data and wgt.data.maxchars then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, "(" .. #preview_name .. "/" .. wgt.data.maxchars .. ")")
  end

  local copy_label = "Copy"
  local copy_w = reaper.ImGui_CalcTextSize(ctx, copy_label) + 4 * acendan.ImGui_GetScale() * 2
  reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + reaper.ImGui_GetContentRegionAvail(ctx) - copy_w)
  Button(copy_label, function()
    if not wgt.name or wgt.name == "" then return end
    reaper.CF_SetClipboard(SanitizeName(wgt.name, nil, {}, true))
  end, "Copies the generated name to your clipboard.\n\nUnfortunately, this can not resolve wildcards or enumeration.")
end

function ClearFields(title, fields)
  for i, field in ipairs(fields) do
    DeleteCurrentValue(title .. " - " .. field.field)
    if field.fields then ClearFields(title, field.fields) end
  end
end

function TabMetadata()
  if not ValidateMeta() then return end

  reaper.ImGui_Text(ctx, "Metadata")
  acendan.ImGui_HelpMarker(
    "Metadata fields are optional, and will be placed as a META marker after your target.\n\n'Add new metadata' setting must be enabled in the Render window!")
  LoadFields(wgt.meta.fields)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, "Targets")
  LoadTargets()

  local disabled = not wgt.target or wgt.target == "Tracks" or not wgt.mode
  if disabled then reaper.ImGui_BeginDisabled(ctx) end

  Button("Apply Metadata", ApplyMetadata,
    "Applies your metadata to the given target!\n\nPro Tip: You can press the 'Enter' key to trigger metadata application from any of the fields above.",
    0.42)

  if disabled then
    reaper.ImGui_SameLine(ctx)
    local warning = wgt.target and
        ((wgt.target == "Tracks" or wgt.mode) and "Unsupported metadata target: " .. wgt.target or
          "Please select a mode for: " .. wgt.target) or "Please select a target."
    reaper.ImGui_TextColored(ctx, 0xFFFF00BB, warning)
    reaper.ImGui_EndDisabled(ctx)
  elseif wgt.meta.error then
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, 0xFF0000FF, wgt.meta.error)
  elseif reaper.ImGui_IsKeyReleased(ctx, reaper.ImGui_Key_Enter()) then
    ApplyMetadata()
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Separator(ctx)
  Button("Clear All Fields", function()
    ClearFields("Metadata", wgt.meta.fields)
    wgt.meta = nil
  end, "Clears out all fields, restoring them to their default state.")
end

function TabSettings()
  reaper.ImGui_SeparatorText(ctx, "Scheme")

  if reaper.ImGui_BeginCombo(ctx, "Scheme", wgt.scheme) then
    for i, scheme in ipairs(wgt.schemes) do
      if reaper.ImGui_Selectable(ctx, scheme, wgt.scheme == scheme) then
        SetScheme(scheme)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  Button("Validate Scheme", function()
    if wgt.scheme and ValidateScheme(wgt.scheme) then
      acendan.msg("Scheme is valid!", "The Last Renamer")
    end
  end, "Check the selected scheme for YAML formatting errors.")

  Button("Add Shared Scheme", function()
    local shared_scheme = acendan.promptForFile("Select a shared scheme to import", "", "",
      "YAML Files (*.yaml)\0*.yaml\0\0")
    if shared_scheme then
      local shared_scheme_name = shared_scheme:match("[^/\\]+$")
      if shared_scheme:find(SCHEMES_DIR) then
        acendan.msg("Shared scheme must be outside of the schemes directory!", "The Last Renamer")
        return
      end
      local shared_schemes_table = GetSharedSchemes()
      for _, scheme in ipairs(shared_schemes_table) do
        if scheme == shared_scheme then
          acendan.msg("Shared scheme already exists!", "The Last Renamer")
          return
        end
      end
      shared_schemes_table[#shared_schemes_table + 1] = shared_scheme
      SetCurrentValue("shared_schemes", table.concat(shared_schemes_table, ";"))
      wgt.schemes = FetchSchemes()
      SetScheme("Shared: " .. shared_scheme_name)
    else
      acendan.msg("No shared scheme selected!", "The Last Renamer")
    end
  end,
    "Import a shared scheme from a YAML file outside of the schemes directory (for example, a file used by multiple team members via Perforce).\n\nNote: Shared Schemes can not have hyphens in their filename.")

  reaper.ImGui_SameLine(ctx)
  Button("Remove Shared Scheme", function()
    if not wgt.scheme:find("Shared: ") then
      acendan.msg("Selected scheme is not a shared scheme!", "The Last Renamer")
      return
    end
    local shared_scheme_name = wgt.scheme:match("Shared: ([^/\\]+)")
    local shared_schemes_table = GetSharedSchemes()
    for i, scheme in ipairs(shared_schemes_table) do
      if scheme:find(shared_scheme_name) then
        table.remove(shared_schemes_table, i)
        break
      end
    end
    SetCurrentValue("shared_schemes", table.concat(shared_schemes_table, ";"))
    wgt.schemes = FetchSchemes()
    SetScheme(wgt.schemes[1])
  end, "Removes the selected shared scheme from the schemes list.", 0)

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_Text(ctx, "File System")
  Button("Open Schemes Folder", function()
    reaper.CF_ShellExecute(SCHEMES_DIR)
  end, "Open the folder containing your schemes in a file browser.")

  reaper.ImGui_SameLine(ctx)
  Button("Rescan Folder", function()
    wgt.schemes = FetchSchemes()
  end, "Rescan the schemes directory for new scheme files.")

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, "Options")

  local auto_clear = GetPreviousValue("opt_auto_clear", false)
  local rv, auto_clear = reaper.ImGui_Checkbox(ctx, "Auto Clear Fields", auto_clear == "true" and true or false)
  if rv then SetCurrentValue("opt_auto_clear", auto_clear) end
  acendan.ImGui_Tooltip("Automatically clear all fields when loading scheme (opening tool or switching scheme).")

  local enable_meta = GetPreviousValue("opt_enable_meta", false)
  local rv, enable_meta = reaper.ImGui_Checkbox(ctx, "Enable Metadata Tab", enable_meta == "true" and true or false)
  if rv then SetCurrentValue("opt_enable_meta", enable_meta) end
  acendan.ImGui_Tooltip(
    "Enable the metadata tab for adding metadata to your renaming targets.\n\nRequires 'Add new metadata' setting in the Render window!")

  local autofill = GetPreviousValue("opt_autofill", false)
  local rv, autofill = reaper.ImGui_Checkbox(ctx, "Enable Autofill Dropdowns", autofill == "true" and true or false)
  if rv then SetCurrentValue("opt_autofill", autofill) end
  acendan.ImGui_Tooltip(
    "Experimental - Overrides standard dropdowns with custom dropdowns that auto-fill with tab while typing.\n\nMay be buggy!")

  local nvk_only = GetPreviousValue("opt_nvk_only", false)
  local rv, nvk_only = reaper.ImGui_Checkbox(ctx, "NVK Folder Items", nvk_only == "true" and true or false)
  if rv then SetCurrentValue("opt_nvk_only", nvk_only) end
  acendan.ImGui_Tooltip("Only target NVK Folder Items when set to 'Items - Selected'. If unsure, leave unchecked.")

  local auto_populate = GetPreviousValue("opt_auto_populate", false)
  local rv, auto_populate = reaper.ImGui_Checkbox(ctx, "Auto Populate from Selected Item", auto_populate == "true" and true or false)
  if rv then
    SetCurrentValue("opt_auto_populate", auto_populate)
    wgt.last_selected_item = nil -- reset so it re-evaluates on next frame
  end
  acendan.ImGui_Tooltip("When enabled, selecting an item in Reaper will automatically parse its name and populate the naming fields based on the current scheme.")

  local ext_app_options = { "None", "Open Minori", "Open Minoru" }
  local ext_app_btn = GetPreviousValue("opt_ext_app_btn", "None")
  if reaper.ImGui_BeginCombo(ctx, "External App Button", ext_app_btn) then
    for _, option in ipairs(ext_app_options) do
      if reaper.ImGui_Selectable(ctx, option, ext_app_btn == option) then
        SetCurrentValue("opt_ext_app_btn", option)
      end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  acendan.ImGui_Tooltip("Show a button in the main panel to open an external app.")

  if acendan.ImGui_ScaleSlider() then wgt.set_font = true end

  local num_hist = tonumber(GetPreviousValue("opt_num_hist", 10))
  local rv, num_hist = reaper.ImGui_SliderInt(ctx, "History Count", num_hist, 1, 50)
  if rv then SetCurrentValue("opt_num_hist", num_hist) end
  acendan.ImGui_Tooltip("Number of history entries to store for each scheme.")

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, "Export Script")

  local export_path = GetPreviousValue("opt_export_script", nil)
  local display_path = (export_path and export_path ~= "" and export_path ~= "false")
                       and export_path or "None configured"
  reaper.ImGui_PushTextWrapPos(ctx, 0.0)
  reaper.ImGui_TextDisabled(ctx, display_path)
  reaper.ImGui_PopTextWrapPos(ctx)

  if reaper.ImGui_Button(ctx, "Browse...") then
    local path = acendan.promptForFile("Select export script", "", "", "Lua Scripts (*.lua)\0*.lua\0\0")
    if path then SetCurrentValue("opt_export_script", path) end
  end
  acendan.ImGui_Tooltip("Select the Reaper Lua script to run when the Export button is clicked.")

  if export_path and export_path ~= "" and export_path ~= "false" then
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Clear") then
      SetCurrentValue("opt_export_script", "")
    end
    acendan.ImGui_Tooltip("Remove the configured export script.")
  end

  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_SeparatorText(ctx, "Backup")

  Button("Export Presets", function()
    local presets = {}
    while true do
      local preset_title = wgt.data.title .. " - Preset" .. tostring(#presets + 1)
      local preset = GetPreviousValue(preset_title, nil)
      if not preset then break end
      presets[#presets + 1] = { title = preset_title, preset = preset }
    end
    if #presets == 0 then
      acendan.msg("No presets found for scheme: " .. wgt.data.title, "The Last Renamer")
      return
    end

    local start_ini_path = acendan.encapsulate(BACKUPS_DIR .. "TheLastRenamer_" .. wgt.scheme:gsub("yaml", "ini"))
    local ini_path = start_ini_path
    if not acendan.directoryExists(BACKUPS_DIR) then
      reaper.RecursiveCreateDirectory(BACKUPS_DIR, 0)
      if not acendan.directoryExists(BACKUPS_DIR) then
        acendan.msg("Error creating backups directory:\n\n" .. BACKUPS_DIR, "The Last Renamer")
        return
      end
    end
    local i = 1
    while acendan.fileExists(ini_path) do
      ini_path = start_ini_path:gsub(".ini", "_" .. tostring(i) .. ".ini")
      i = i + 1
    end

    local file, err = io.open(ini_path, "w")
    if not file or err then
      acendan.msg("Error creating ini file:\n\n" .. tostring(err), "The Last Renamer")
      return
    end
    file:write("[The Last Renamer]\n")
    for _, preset in ipairs(presets) do
      file:write(preset.title .. "=" .. preset.preset .. "\n")
    end
    file:close()

    reaper.CF_SetClipboard(ini_path)
    acendan.msg(tostring(#presets) .. " preset(s) exported to:\n\n" .. ini_path .. "\n\nPath copied to clipboard.",
      "The Last Renamer")
  end, "Exports all presets for the selected scheme to an ini file.")

  reaper.ImGui_SameLine(ctx)
  Button("Import Presets", function()
    if #wgt.dragdrop == 0 then
      acendan.msg("No preset files found to import! Please drag-drop preset .ini files below.", "The Last Renamer")
      return
    end

    local presets = {}
    for _, file in ipairs(wgt.dragdrop) do
      local i = 1
      while true do
        local preset_title = wgt.data.title .. " - Preset" .. tostring(i)
        local ret, preset = reaper.BR_Win32_GetPrivateProfileString("The Last Renamer", preset_title, "", file)
        if not ret or not preset or preset == "" then break end
        presets[#presets + 1] = {
          title  = wgt.data.title .. " - Preset" .. tostring(#presets + 1),
          preset = preset
        }
        i = i + 1
      end
    end

    if GetPreviousValue("opt_overwrite", false) == "true" then
      local num_presets = #wgt.preset.presets
      for i = 1, num_presets do
        local preset_title = wgt.data.title .. " - Preset" .. tostring(i)
        if HasValue(preset_title) then DeleteCurrentValue(preset_title) end
      end
      wgt.preset.presets = {}
    end

    for _, preset in ipairs(presets) do
      StorePreset(preset.title, nil, nil, preset.preset)
    end
    acendan.msg(tostring(#presets) .. " preset(s) imported from " .. tostring(#wgt.dragdrop) .. " files!",
      "The Last Renamer")
  end, "Imports presets from ini file(s) drag-dropped below. Only imports presets for the active scheme.")

  reaper.ImGui_SameLine(ctx)
  local overwrite = GetPreviousValue("opt_overwrite", false)
  local rv, overwrite = reaper.ImGui_Checkbox(ctx, "Overwrite?", overwrite == "true" and true or false)
  if rv then SetCurrentValue("opt_overwrite", overwrite) end
  acendan.ImGui_Tooltip(
    "If unchecked, imported presets will be added to existing ones. If checked, will erase pre-existing presets on import.\n\nIf you enable this, back up existing ones with the Export button first!")

  if reaper.ImGui_BeginChild(ctx, '##drop_files', 300, 50, reaper.ImGui_ChildFlags_FrameStyle()) then
    if #wgt.dragdrop == 0 then
      reaper.ImGui_Text(ctx, 'Drag-drop preset file(s) to import...')
    else
      reaper.ImGui_Text(ctx, ('Ready to import %d file(s):'):format(#wgt.dragdrop))
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_SmallButton(ctx, 'Clear') then wgt.dragdrop = {} end
    end
    for _, file in ipairs(wgt.dragdrop) do
      reaper.ImGui_Bullet(ctx)
      reaper.ImGui_TextWrapped(ctx, file:match('[^/\\]+$'))
    end
    reaper.ImGui_EndChild(ctx)
  end

  if reaper.ImGui_BeginDragDropTarget(ctx) then
    local rv, count = reaper.ImGui_AcceptDragDropPayloadFiles(ctx)
    if rv then
      wgt.dragdrop = {}
      for i = 0, count - 1 do
        local filename
        rv, filename = reaper.ImGui_GetDragDropPayloadFile(ctx, i)
        if rv and filename:match("%.ini$") then
          table.insert(wgt.dragdrop, filename)
        end
      end
    end
    reaper.ImGui_EndDragDropTarget(ctx)
  end
end

function Main()
  -- Auto-fill fields from selected item's take name when selection changes
  if wgt.data and GetPreviousValue("opt_auto_populate", false) == "true" then
    local sel_item = reaper.GetSelectedMediaItem(0, 0)
    if sel_item ~= wgt.last_selected_item then
      wgt.last_selected_item = sel_item
      if sel_item then AutoFillFromItem(sel_item) end
    end
  end

  if wgt.set_font then
    acendan.ImGui_SetFont(); wgt.set_font = false
  end
  acendan.ImGui_PushStyles()

  local rv, open = reaper.ImGui_Begin(ctx, "The Last Renamer - Schapps Edition", true, WINDOW_FLAGS)
  if not rv then return open end

  if reaper.ImGui_BeginTabBar(ctx, "TabBar") then
    TabItem("Naming",   TabNaming)
    TabItem("Metadata", TabMetadata, "opt_enable_meta")
    TabItem("Settings", TabSettings)

    if reaper.ImGui_TabItemButton(ctx, '?',
        reaper.ImGui_TabItemFlags_Trailing() | reaper.ImGui_TabItemFlags_NoTooltip()) then
      reaper.CF_ShellExecute("https://github.com/acendan/reascripts/wiki/The-Last-Renamer")
    end

    reaper.ImGui_EndTabBar(ctx)
  end

  if reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_Escape()) and
      not reaper.ImGui_IsPopupOpen(ctx, "", reaper.ImGui_PopupFlags_AnyPopupId()) then
    open = false
  end

  reaper.ImGui_End(ctx)
  acendan.ImGui_PopStyles()
  if open then reaper.defer(Main) else return end
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ UTILITIES ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

function FetchSchemes()
  local schemes = {}
  if SCHEMES_DIR ~= nil then
    local file_idx = 0
    repeat
      schemes[#schemes + 1] = reaper.EnumerateFiles(SCHEMES_DIR, file_idx)
      file_idx = file_idx + 1
    until not reaper.EnumerateFiles(SCHEMES_DIR, file_idx)
  else
    acendan.msg("Schemes directory not found: " .. SCHEMES_DIR)
    return schemes
  end
  local shared_schemes_table = GetSharedSchemes()
  for _, shared_scheme in ipairs(shared_schemes_table) do
    local shared_scheme_name = shared_scheme:match("[^/\\]+$")
    schemes[#schemes + 1] = "Shared: " .. shared_scheme_name
  end
  if #schemes == 0 then
    acendan.msg("No schemes found in: " .. SCHEMES_DIR)
  end
  return schemes
end

function SetScheme(scheme)
  wgt.scheme = scheme
  wgt.data   = nil
  SetCurrentValue("scheme", scheme)
end

function LoadScheme(scheme)
  if wgt.data then return true end
  wgt.data = ValidateScheme(scheme)
  if not wgt.data then return false end
  RecallSettings(wgt.data.title, wgt.data.fields)

  wgt.preset.presets = nil
  RecallPresets()

  wgt.history.presets = nil
  RecallHistories()

  if GetPreviousValue("opt_auto_clear", false) == "true" then ClearFields(wgt.data.fields) end
  return true
end

function ValidateScheme(scheme)
  if not scheme then return nil end
  local scheme_path = ""
  if scheme:find("Shared: ") then
    local shared_schemes_table = GetSharedSchemes()
    for _, shared_scheme in ipairs(shared_schemes_table) do
      local shared_scheme_name = shared_scheme:match("[^/\\]+$")
      if scheme:find(shared_scheme_name) then
        scheme_path = shared_scheme
        break
      end
    end
  else
    scheme_path = SCHEMES_DIR .. scheme
  end
  local status, result = pcall(acendan.loadYaml, scheme_path)
  if not status then
    acendan.msg("Error loading scheme: " .. scheme .. "\n\n" .. tostring(result), "The Last Renamer")
    return nil
  end
  return result
end

function ValidateMeta()
  if wgt.meta then return true end
  local status, result = pcall(acendan.loadYaml, META_DIR .. "meta.yaml")
  if not status then
    reaper.ImGui_TextColored(ctx, 0xFF0000FF, "Error loading metadata!\n\n" .. tostring(result))
    return false
  end
  wgt.meta = result
  wgt.meta.serialize = {}
  RecallSettings("Metadata", wgt.meta.fields, wgt.meta.serialize)
  return true
end

function GetPreviousValue(key, default)
  return HasValue(key) and reaper.GetExtState(SCRIPT_NAME, key) or default
end

function SetCurrentValue(key, value)
  reaper.SetExtState(SCRIPT_NAME, key, tostring(value), true)
end

function DeleteCurrentValue(key)
  reaper.DeleteExtState(SCRIPT_NAME, key, true)
end

function HasValue(key)
  return reaper.HasExtState(SCRIPT_NAME, key)
end

function StoreSettings(title, serialize)
  title     = title     or wgt.data.title
  serialize = serialize or wgt.serialize
  for i = 1, #serialize do
    local field, value = table.unpack(serialize[i])
    SetCurrentValue(title .. " - " .. field, value)
  end
end

function RecallSettings(title, fields, serialize)
  serialize = serialize or wgt.serialize
  for i, field in ipairs(fields) do
    local prev = GetPreviousValue(title .. " - " .. field.field, nil)
    if prev then SetFieldValue(field, prev) end
    if field.fields then RecallSettings(title, field.fields) end
  end
  serialize = {}
end

function GetFieldValue(field, short)
  short = short == nil or short
  if type(field.value) == "table" then
    if field.selected then
      if field.short and short then
        return field.short[field.selected]
      else
        return field.value[field.selected]
      end
    end
  else
    return tostring(field.value)
  end
  return ""
end

function SetFieldValue(field, value)
  if type(field.value) == "table" then
    field.selected = tonumber(value)
    if field.filter then reaper.ImGui_TextFilter_Set(field.filter, field.value[field.selected]) end
  elseif type(field.value) == "number" then
    if type(value) == "number" then
      field.value = tonumber(value)
    elseif value == "$num" then
      field.numwild = true
      field.value   = value
    end
  elseif type(field.value) == "boolean" then
    field.value = value == "true" and true or false
  elseif type(field.value) == "string" then
    field.value = value
  end
end

function StoreHistory()
  local prefix = "History"
  local i      = 1
  local max    = tonumber(GetPreviousValue("opt_num_hist", 10))
  local history = {}
  while true do
    local prev = GetPreviousValue(wgt.data.title .. " - " .. prefix .. i, nil)
    if not prev then break end
    if i >= max then
      DeleteCurrentValue(wgt.data.title .. " - " .. prefix .. i)
    else
      history[#history + 1] = prev
    end
    i = i + 1
  end

  for i, hist in ipairs(history) do
    SetCurrentValue(wgt.data.title .. " - " .. prefix .. tostring(i + 1), hist)
  end
  DeleteCurrentValue(wgt.data.title .. " - " .. prefix .. "1")

  StorePreset(wgt.name, prefix, wgt.history)

  wgt.history.presets = nil
  RecallHistories()
end

function StorePreset(preset, prefix, settings, preserialized)
  prefix   = prefix   or "Preset"
  settings = settings or wgt.preset
  local function SerializeFields(fields)
    for _, field in ipairs(fields) do
      local name = tostring(field.field)
      if field.id ~= nil then
        if type(field.id) == "table" then
          for _, id in ipairs(field.id) do
            name = name .. ":" .. acendan.encapsulate(tostring(id))
          end
        else
          name = name .. ":" .. acendan.encapsulate(tostring(field.id))
        end
      end
      if type(field.value) == "table" then
        if field.selected then
          settings.buf = settings.buf .. name .. "=" .. acendan.encapsulate(tostring(field.selected)) .. "||"
        end
      else
        local valstr = tostring(field.value)
        if valstr ~= "" then
          settings.buf = settings.buf .. name .. "=" .. acendan.encapsulate(tostring(field.value)) .. "||"
        end
      end
      if field.fields then SerializeFields(field.fields) end
    end
  end

  local i = 1
  while true do
    local prev = GetPreviousValue(wgt.data.title .. " - " .. prefix .. i, nil)
    if not prev then
      if preserialized then
        settings.buf = preserialized
      else
        settings.buf = prefix:lower() .. "=" .. preset .. "||"
        SerializeFields(wgt.data.fields)
      end
      SetCurrentValue(wgt.data.title .. " - " .. prefix .. i, settings.buf)
      break
    end
    i = i + 1
  end

  settings.presets[#settings.presets + 1] = RecallPreset(#settings.presets + 1, prefix)
end

function RecallPresets(prefix, settings)
  prefix   = prefix   or "Preset"
  settings = settings or wgt.preset
  if settings.presets then return end
  settings.presets = {}
  local i = 1
  while true do
    local preset = GetPreviousValue(wgt.data.title .. " - " .. prefix .. i, nil)
    if not preset then break end
    settings.presets[#settings.presets + 1] = RecallPreset(i, prefix)
    i = i + 1
  end
end

function RecallHistories()
  if wgt.history.presets then return end
  wgt.history.presets = {}
  local prefix = "History"
  local i      = 1
  while true do
    local history = GetPreviousValue(wgt.data.title .. " - " .. prefix .. i, nil)
    if not history then break end
    wgt.history.presets[#wgt.history.presets + 1] = RecallPreset(i, prefix)
    i = i + 1
  end
end

function RecallPreset(idx, prefix)
  local function DeserializePreset(preset)
    local fields = {}
    for field, value in preset:gmatch('([^=]+)=([^|]+)||') do
      fields[acendan.uncapsulate(field)] = acendan.uncapsulate(value)
    end
    return fields
  end
  local preset = GetPreviousValue(wgt.data.title .. " - " .. prefix .. idx, nil)
  if not preset then return nil end
  return DeserializePreset(preset)
end

function DeletePreset(idx, prefix)
  prefix = prefix or "Preset"
  DeleteCurrentValue(wgt.data.title .. " - " .. prefix .. idx)
  wgt.preset.presets[idx] = nil
  local i = idx + 1
  while true do
    local preset = GetPreviousValue(wgt.data.title .. " - " .. prefix .. i, nil)
    if not preset then break end
    SetCurrentValue(wgt.data.title .. " - " .. prefix .. i - 1, preset)
    wgt.preset.presets[i - 1] = wgt.preset.presets[i]
    i = i + 1
  end
  DeleteCurrentValue(wgt.data.title .. " - " .. prefix .. i - 1)
  wgt.preset.presets[i - 1] = nil
end

function Capitalize(str, capitalization)
  local lowstr = str:lower()
  if lowstr == "$name" or lowstr == "$enum" then return lowstr end
  if not capitalization or capitalization == "" then return str end
  local caps = capitalization:lower()
  if caps:find("title") then
    return str:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest:lower() end)
  elseif caps:find("pascal") then
    return str:gsub("(%a)([%w_']*)", function(first, rest) return first:upper() .. rest end):gsub(" ", "")
  elseif caps:find("up") then
    return str:upper()
  elseif caps:find("low") then
    return str:lower()
  else
    return str
  end
end

function GetSharedSchemes()
  local shared_schemes = GetPreviousValue("shared_schemes", "")
  local shared_schemes_table = {}
  for shared_scheme in shared_schemes:gmatch("[^;]+") do
    shared_schemes_table[#shared_schemes_table + 1] = shared_scheme
  end
  return shared_schemes_table
end

function AppendSerializedField(serialize, field, value)
  for i, entry in ipairs(serialize) do
    if entry[1] == field then
      table.remove(serialize, i)
      break
    end
  end
  serialize[#serialize + 1] = { field, value }
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~ AUTOFILL ~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Split a string by a literal separator string (not a Lua pattern)
local function SplitBySep(str, sep)
  local escaped = sep:gsub("([^%w])", "%%%1")
  local parts = {}
  for part in (str .. sep):gmatch("(.-)" .. escaped) do
    if part ~= "" then parts[#parts + 1] = part end
  end
  return parts
end

-- Normalize a display value for name-matching: replace spaces with the separator,
-- lowercase. This mirrors how SanitizeName collapses spaces via wgt.data.find/replace.
local function NormalizeValue(val, sep)
  return val:gsub(" ", sep):lower()
end

-- Try to match one or more consecutive name parts starting at idx against a
-- dropdown candidate (val or short). Returns the number of parts consumed, or 0.
-- Uses longest-match so "Battle Rifle" beats "Battle" when both are present.
local function MatchDropdownOptions(options, parts, idx, sep)
  local best_i, best_n = nil, 0
  for i, val in ipairs(options) do
    if val ~= "" then
      local normalized = NormalizeValue(val, sep)
      local n = #SplitBySep(normalized, sep)  -- how many parts this option spans
      if n > best_n and idx + n - 1 <= #parts then
        local candidate = table.concat(parts, sep, idx, idx + n - 1):lower()
        if candidate == normalized then
          best_i, best_n = i, n
        end
      end
    end
  end
  return best_i, best_n
end

-- Try to match parts[idx...] against a field.
-- Returns match_type, match_value, parts_consumed  — or nil if no match.
local function TryMatchField(field, parts, idx)
  local sep = wgt.data.separator

  if type(field.value) == "table" then
    -- Try full dropdown values (longest match wins)
    local best_i, best_n = MatchDropdownOptions(field.value, parts, idx, sep)
    -- Try short/abbreviated values (longest match wins, only beats full if longer)
    if field.short then
      local si, sn = MatchDropdownOptions(field.short, parts, idx, sep)
      if si and sn > best_n then best_i, best_n = si, sn end
    end
    if best_i then return "selected", best_i, best_n end
    return nil

  elseif type(field.value) == "string" then
    -- Don't consume pure-numeric parts (e.g. "01", "003") — leave them for enumeration fields
    if parts[idx]:match("^%d+$") then return nil end
    return "string", parts[idx], 1

  elseif type(field.value) == "number" or field.numwild then
    local num = tonumber(parts[idx])   -- tonumber handles "01" -> 1, "010" -> 10
    if num then return "number", num, 1 end
    return nil

  elseif type(field.value) == "boolean" then
    local p = parts[idx]:lower()
    if field.btrue  and field.btrue:lower()  == p then return "boolean", true,  1 end
    if field.bfalse and field.bfalse:lower() == p then return "boolean", false, 1 end
    return "boolean", false, 0  -- keyword absent: default to false, consume no parts
  end
end

-- Apply a matched value to a field
local function ApplyFieldMatch(field, match_type, match_val)
  if match_type == "selected" then
    field.selected = match_val
    if field.filter then
      reaper.ImGui_TextFilter_Set(field.filter, field.value[match_val])
    end
  elseif match_type == "string" then
    field.value = match_val
  elseif match_type == "number" then
    field.value   = match_val
    field.numwild = false
  elseif match_type == "boolean" then
    field.value = match_val
  end
end

-- Count how many parts the fields at indices [start_i..#fields] will consume,
-- scanning from the END of parts. Used to reserve space for trailing fields
-- so a greedy text field doesn't swallow them.
local function CountTrailingParts(fields, start_i, parent, parts, from_idx)
  local count = 0
  for i = #fields, start_i, -1 do
    local f = fields[i]
    if PassesIDCheck(f, parent) then
      local part_idx = #parts - count
      if part_idx < from_idx then break end
      if type(f.value) == "boolean" then
        if f.btrue and parts[part_idx]:lower() == f.btrue:lower() then
          count = count + 1
        end
        -- else: boolean absent, takes 0 parts
      elseif type(f.value) == "number" or f.numwild then
        count = count + 1
      elseif type(f.value) == "table" then
        count = count + 1
      elseif type(f.value) == "string" then
        count = count + 1
      end
    end
  end
  return count
end

-- Recursively walk fields in order, consuming name parts as they match.
-- state.idx is shared across all recursive calls via the table reference.
local function FillFields(fields, parent, parts, state)
  for i, field in ipairs(fields) do
    if state.idx > #parts then return end
    if not PassesIDCheck(field, parent) then
      if field.fields then FillFields(field.fields, field, parts, state) end
    else
      local match_type, match_val, n

      if type(field.value) == "string" then
        -- Greedy text field: consume all parts not reserved by trailing fields
        local trailing = CountTrailingParts(fields, i + 1, parent, parts, state.idx)
        local available = #parts - state.idx + 1
        n = math.max(1, available - trailing)
        local val = table.concat(parts, wgt.data.separator, state.idx, state.idx + n - 1)
        if not val:match("^%d+$") then
          match_type, match_val = "string", val
        end
      else
        match_type, match_val, n = TryMatchField(field, parts, state.idx)
      end

      if match_type then
        ApplyFieldMatch(field, match_type, match_val)
        state.idx = state.idx + (n or 0)
      end
      if field.fields then FillFields(field.fields, field, parts, state) end
    end
  end
end

function AutoFillFromItem(item, force)
  if not wgt.data or not wgt.data.fields or not wgt.data.separator then return end
  local take = reaper.GetActiveTake(item)
  if not take then return end
  local _, name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if not name or name == "" then return end

  local parts = SplitBySep(name, wgt.data.separator)
  if #parts == 0 then return end

  -- Guard: skip autofill if the name doesn't match the scheme's first meaningful field.
  -- This prevents overwriting fields when the user selects unprocessed items.
  -- Bypassed when force=true (manual "Capture Name" button).
  if not force then
    local gate_passed = false
    for _, field in ipairs(wgt.data.fields) do
      if PassesIDCheck(field, nil) and type(field.value) ~= "boolean" then
        local match_type = TryMatchField(field, parts, 1)
        gate_passed = (match_type ~= nil)
        break
      end
    end
    if not gate_passed then return end
  end

  local state = { idx = 1 }
  FillFields(wgt.data.fields, nil, parts, state)
  wgt.serialize = {}
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~ IMGUI ~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

function Button(name, callback, help, color)
  if color then
    acendan.ImGui_Button(name, callback, color)
  elseif reaper.ImGui_Button(ctx, name, color) then
    callback()
  end
  if help then acendan.ImGui_Tooltip(help) end
end

function TabItem(name, tab, setting)
  if setting and GetPreviousValue(setting, false) ~= "true" then return end
  if reaper.ImGui_BeginTabItem(ctx, name) then
    tab()
    reaper.ImGui_EndTabItem(ctx)
  end
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~ RENAMING ~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~

function ApplyName()
  reaper.Undo_BeginBlock()
  wgt.error = Rename(wgt.target, wgt.mode, wgt.name, wgt.enumeration)
  reaper.Undo_EndBlock("The Last Renamer - " .. wgt.data.title, -1)
  StoreSettings()
  StoreHistory()
end

function Rename(target, mode, name, enumeration)
  if not target or not mode then
    return "Missing renaming target!"
  elseif not name then
    return "Attempting rename with empty name!"
  elseif not enumeration then
    if FindField(wgt.data.fields, "Enumeration") then
      return "Missing enumeration!"
    else
      enumeration = {
        start    = 1,
        zeroes   = 1,
        singles  = false,
        wildcard = "$enum",
        sep      = wgt.data.separator
      }
    end
  end

  if target == "Regions" then
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    if num_regions > 0 then
      return ProcessRegions(mode, num_markers + num_regions, name, enumeration)
    end
  elseif target == "Items" then
    local num_items = reaper.CountMediaItems(0)
    if num_items > 0 then
      return ProcessItems(mode, num_items, name, enumeration)
    end
  elseif target == "Tracks" then
    local num_tracks = reaper.CountTracks(0)
    if num_tracks > 0 then
      return ProcessTracks(mode, num_tracks, name, enumeration)
    end
  end

  return "Project has no " .. target .. " to rename!"
end

function SanitizeName(name, enumeration, wildcards, skipincrement)
  local function GetEnumeration(enumeration)
    if not enumeration or (enumeration.num == 1 and not enumeration.singles) then
      return ""
    elseif type(enumeration.start) == "string" then
      return enumeration.sep
    end
    local num_str = PadZeroes(enumeration.start, enumeration.zeroes)
    if not skipincrement then
      enumeration.start = enumeration.start + 1
    end
    return enumeration.sep .. num_str
  end

  local wild = name
  for _, wildcard in ipairs(wildcards) do
    wild = wild:gsub(wildcard.find, wildcard.replace)
  end

  if enumeration then
    wild = wild:gsub(enumeration.sep .. enumeration.wildcard, GetEnumeration(enumeration))
  end

  local stripped = wild:match("^%s*(.-)%s*$")
  local illegal = wgt.data.illegal or { ":", "*", "?", "\"", "<", ">", "|", "\\", "/" }
  for _, char in ipairs(illegal) do
    stripped = stripped:gsub(char, "")
  end

  if wgt.data.find and wgt.data.replace then
    for _, char in ipairs(wgt.data.find) do
      stripped = stripped:gsub(char, wgt.data.replace)
    end
  end
  return stripped
end

function PadZeroes(num, zeroes)
  local num_str = tostring(num)
  local num_len = string.len(num_str)
  local pad     = (zeroes and zeroes or 1) - num_len + 1
  if pad > 0 then
    for j = 1, pad do num_str = "0" .. num_str end
  end
  return num_str
end

function ProcessRegions(mode, num_mkrs_rgns, name, enumeration, meta)
  local error = nil
  local queue = {}

  if mode == "Time Selection" then
    local start_time_sel, end_time_sel = reaper.GetSet_LoopTimeRange(0, 0, 0, 0, 0)
    if start_time_sel ~= end_time_sel then
      local i = 0
      while i < num_mkrs_rgns do
        local _, isrgn, pos, rgnend, rgnname, markrgnindexnumber, color = reaper.EnumProjectMarkers3(0, i)
        if isrgn then
          if pos >= start_time_sel and rgnend <= end_time_sel then
            local wildcards = { { find = "$name", replace = rgnname }, { find = "$num", replace = PadZeroes(markrgnindexnumber) } }
            queue[#queue + 1] = { i, pos, rgnend, color, markrgnindexnumber, wildcards }
          end
        end
        i = i + 1
      end
    else
      error = "You haven't made a time selection!"
    end
  elseif mode == "All" then
    local i = 0
    while i < num_mkrs_rgns do
      local _, isrgn, pos, rgnend, rgnname, markrgnindexnumber, color = reaper.EnumProjectMarkers3(0, i)
      if isrgn then
        local wildcards = { { find = "$name", replace = rgnname }, { find = "$num", replace = PadZeroes(markrgnindexnumber) } }
        queue[#queue + 1] = { i, pos, rgnend, color, markrgnindexnumber, wildcards }
      end
      i = i + 1
    end
  elseif mode == "Edit Cursor" then
    local _, regionidx = reaper.GetLastMarkerAndCurRegion(0, reaper.GetCursorPosition())
    if regionidx ~= nil then
      local _, isrgn, pos, rgnend, rgnname, markrgnindexnumber, color = reaper.EnumProjectMarkers3(0, regionidx)
      if isrgn then
        local wildcards = { { find = "$name", replace = rgnname }, { find = "$num", replace = PadZeroes(markrgnindexnumber) } }
        queue[#queue + 1] = { regionidx, pos, rgnend, color, markrgnindexnumber, wildcards }
      end
    end
  elseif mode == "Selected" then
    local sel_rgn_table = acendan.getSelectedRegions()
    if sel_rgn_table then
      for _, regionidx in pairs(sel_rgn_table) do
        local i = 0
        while i < num_mkrs_rgns do
          local _, isrgn, pos, rgnend, rgnname, markrgnindexnumber, color = reaper.EnumProjectMarkers3(0, i)
          if isrgn and markrgnindexnumber == regionidx then
            local wildcards = { { find = "$name", replace = rgnname }, { find = "$num", replace = PadZeroes(markrgnindexnumber) } }
            queue[#queue + 1] = { i, pos, rgnend, color, markrgnindexnumber, wildcards }
            break
          end
          i = i + 1
        end
      end
    else
      error = "No regions selected!\n\nPlease go to View > Region/Marker Manager to select regions."
    end
  end

  if #queue > 0 then
    if meta then return queue end
    enumeration.num = #queue
    for _, item in ipairs(queue) do
      local i, pos, rgnend, color, markrgnindexnumber, wildcards = table.unpack(item)
      reaper.SetProjectMarkerByIndex(0, i, true, pos, rgnend, markrgnindexnumber,
        SanitizeName(name, enumeration, wildcards), color)
    end
  else
    error = "No regions to rename (" .. mode .. ")!"
  end

  return error
end

function ProcessItems(mode, num_items, name, enumeration, meta)
  local error         = nil
  local queue         = {}
  local ini_sel_items = {}

  if mode == "Selected" then
    if GetPreviousValue("opt_nvk_only", false) == "true" then
      acendan.saveSelectedItems(ini_sel_items)
      for _, item in ipairs(ini_sel_items) do
        if not acendan.isFolderItem(item) or not acendan.isTopLevelFolderItem(item, ini_sel_items) then
          reaper.SetMediaItemSelected(item, false)
        end
      end
      if reaper.CountSelectedMediaItems(0) == 0 then
        acendan.restoreSelectedItems(ini_sel_items)
        ini_sel_items = {}
      end
    end

    local num_sel_items = reaper.CountSelectedMediaItems(0)
    if num_sel_items > 0 then
      for i = 0, num_sel_items - 1 do
        local item       = reaper.GetSelectedMediaItem(0, i)
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
        local take       = reaper.GetActiveTake(item)
        local _, item_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        local item_num   = math.floor(reaper.GetMediaItemInfo_Value(item, "IP_ITEMNUMBER") + 1)
        if take ~= nil then
          local wildcards = { { find = "$name", replace = item_name }, { find = "$num", replace = PadZeroes(item_num) } }
          queue[#queue + 1] = { item, take, wildcards, item_start, item_end, item_num }
        end
      end
    else
      error = "No items selected!"
    end

    if #ini_sel_items > 0 then acendan.restoreSelectedItems(ini_sel_items) end

  elseif mode == "All" then
    for i = 0, num_items - 1 do
      local item       = reaper.GetMediaItem(0, i)
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_end   = item_start + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local take       = reaper.GetActiveTake(item)
      local _, item_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      local item_num   = math.floor(reaper.GetMediaItemInfo_Value(item, "IP_ITEMNUMBER") + 1)
      if take ~= nil then
        local wildcards = { { find = "$name", replace = item_name }, { find = "$num", replace = PadZeroes(item_num) } }
        queue[#queue + 1] = { item, take, wildcards, item_start, item_end, item_num }
      end
    end
  end

  if #queue > 0 then
    if meta then return queue end
    enumeration.num = #queue
    local prev_had_overlap = false
    for _, item_data in ipairs(queue) do
      local item, take, wildcards, item_start, item_end, item_num = table.unpack(item_data)

      local has_overlap = false
      if wgt.overlap then
        local track            = reaper.GetMediaItem_Track(item)
        local track_num_items  = reaper.CountTrackMediaItems(track)
        if track_num_items > 0 then
          for i = 0, track_num_items - 1 do
            local track_item       = reaper.GetTrackMediaItem(track, i)
            if item ~= track_item then
              local track_item_start = reaper.GetMediaItemInfo_Value(track_item, "D_POSITION")
              local track_item_end   = track_item_start + reaper.GetMediaItemInfo_Value(track_item, "D_LENGTH")
              has_overlap = item_start < track_item_end and item_end > track_item_start
              if has_overlap then break end
            elseif i == 0 then
              has_overlap = true
              break
            end
          end
        end
        -- Pre-increment only when transitioning OUT of an overlap group.
        -- Non-overlap items after a pure non-overlap sequence use SanitizeName's
        -- own auto-increment instead, so the first item correctly starts at `start`.
        if not has_overlap and prev_had_overlap then
          enumeration.start = enumeration.start + 1
        end
        prev_had_overlap = has_overlap
      end

      -- Overlap items: skip auto-increment (they share the same number).
      -- Non-overlap items: allow auto-increment so each gets a unique number.
      local new_name = SanitizeName(name, enumeration, wildcards, has_overlap)
      reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", new_name, true)
    end
  else
    error = "No items to rename (" .. mode .. ")!"
  end

  return error
end

function ProcessTracks(mode, num_tracks, name, enumeration)
  local error = nil
  local queue = {}

  if mode == "Selected" then
    local num_sel_tracks = reaper.CountSelectedTracks(0)
    if num_sel_tracks > 0 then
      for i = 0, num_sel_tracks - 1 do
        local track     = reaper.GetSelectedTrack(0, i)
        local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        local track_num = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
        local wildcards = { { find = "$name", replace = track_name }, { find = "$num", replace = PadZeroes(track_num) } }
        queue[#queue + 1] = { track, wildcards }
      end
    else
      error = "No tracks selected!"
    end
  elseif mode == "All" then
    for i = 0, num_tracks - 1 do
      local track     = reaper.GetTrack(0, i)
      local _, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
      local track_num = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
      local wildcards = { { find = "$name", replace = track_name }, { find = "$num", replace = PadZeroes(track_num) } }
      queue[#queue + 1] = { track, wildcards }
    end
  end

  if #queue > 0 then
    enumeration.num = #queue
    for _, item in ipairs(queue) do
      local track, wildcards = table.unpack(item)
      reaper.GetSetMediaTrackInfo_String(track, "P_NAME", SanitizeName(name, enumeration, wildcards), true)
    end
  else
    error = "No tracks to rename (" .. mode .. ")!"
  end

  return error
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~ META ~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

function ApplyMetadata()
  wgt.meta.error = nil

  local marker = GenerateMetadataMarker()
  if not marker or marker == "" then
    wgt.meta.error = "No metadata to apply!"
    return
  end

  StoreSettings("Metadata", wgt.meta.serialize)

  reaper.Undo_BeginBlock()

  if wgt.target == "Regions" then
    local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
    if num_regions > 0 then
      local queue = ProcessRegions(wgt.mode, num_markers + num_regions, nil, nil, true)
      if type(queue) == "table" then
        for _, rgn in ipairs(queue) do
          local _, _, rgnend, _, idx, _ = table.unpack(rgn)
          SetMetadataMarker(marker, rgnend, idx)
        end
      else
        wgt.meta.error = queue
      end
    else
      wgt.meta.error = "No regions to apply metadata to!"
    end
  elseif wgt.target == "Items" then
    local num_items = reaper.CountMediaItems(0)
    if num_items > 0 then
      local queue = ProcessItems(wgt.mode, num_items, nil, nil, true)
      if type(queue) == "table" then
        for _, item in ipairs(queue) do
          local _, _, _, _, item_end, item_num = table.unpack(item)
          SetMetadataMarker(marker, item_end, item_num)
        end
      else
        wgt.meta.error = queue
      end
    else
      wgt.meta.error = "No items to apply metadata to!"
    end
  end

  reaper.Undo_EndBlock("The Last Renamer - Metadata", -1)
end

function GenerateMetadataMarker()
  local function SetRenderMetadata(marker, meta, key, val)
    if val == "" then return marker end
    for _, metaspec in ipairs(meta) do
      reaper.GetSetProjectInfo_String(0, "RENDER_METADATA", metaspec .. "|$marker(" .. key .. ")[;]", true)
    end
    return marker .. key .. "=" .. tostring(val) .. ";"
  end

  local function GenerateMarkerString(fields, marker, parent)
    for _, field in ipairs(fields) do
      if field.value and PassesIDCheck(field, parent) and not field.skip then
        marker = SetRenderMetadata(marker, field.meta, field.field, GetFieldValue(field))
      end
      if field.fields then
        marker = GenerateMarkerString(field.fields, marker, field)
      end
    end
    return marker
  end

  local function ResolveMetaRefs(fields, marker, refs)
    if not fields or not refs then return marker end
    for _, field in ipairs(fields) do
      if type(field.id) == "table" then
        for _, id in ipairs(field.id) do
          local find_field = FindField(refs, id)
          if find_field then
            marker = SetRenderMetadata(marker, field.meta, field.field, GetFieldValue(find_field, field.short))
          end
        end
      else
        local field_name = field.id:match("([^:]+)")
        for id in field.id:gmatch(":(%w+)") do
          local find_field = FindField(refs, id)
          if find_field then
            field_name = field_name .. ":" .. GetFieldValue(find_field, field.short)
          end
        end
        local find_field = FindField(refs, field_name)
        if find_field then
          marker = SetRenderMetadata(marker, field.meta, field.field, GetFieldValue(find_field, field.short))
        end
      end
    end
    return marker
  end

  local function ApplyHardCodedFields(hardcoded)
    if not hardcoded then return end
    for _, field in ipairs(hardcoded) do
      if field.hard then
        for _, metaspec in ipairs(field.meta) do
          reaper.GetSetProjectInfo_String(0, "RENDER_METADATA", metaspec .. "|" .. field.hard, true)
        end
      end
    end
  end

  local marker = META_MKR_PREFIX .. ";"
  marker = GenerateMarkerString(wgt.meta.fields, marker, nil)
  marker = ResolveMetaRefs(wgt.meta.refs, marker, wgt.data and wgt.data.fields or nil)
  ApplyHardCodedFields(wgt.meta.hardcoded)
  return marker
end

function SetMetadataMarker(marker, pos, num)
  acendan.deleteProjectMarkers(false, pos, META_MKR_PREFIX)
  reaper.AddProjectMarker(0, false, pos, 0, marker, num and num or -1)
  reaper.AddProjectMarker(0, false, pos + 0.001, 0, META_MKR_PREFIX, num and num or -1)
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~ MAIN ~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Init()
Main()
