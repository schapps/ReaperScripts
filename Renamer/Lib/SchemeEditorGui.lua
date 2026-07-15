-- @noindex
-- SchemeEditorGui: ImGui-facing half of the scheme-editing feature. Renders
-- the dropdown combos plus their right-click context menus (dropdown-level
-- "Add Item...", per-item "Move Up"/"Move Down") and the Add Item popup.
-- Depends on SchemeEditor.lua (the pure logic/file-I/O module) and on the
-- main script's `acendan` helper table, both injected via init() since
-- dofile'd chunks don't share the main script's `local` variables.

local SchemeEditorGui = {}

local Editor, Helpers

function SchemeEditorGui.init(scheme_editor, helpers)
  Editor = scheme_editor
  Helpers = helpers
end

-- Data-driven action lists so future actions (Delete, Rename, Sort, ...)
-- are just new entries here, not a restructure of the rendering code.
SchemeEditorGui.LIST_ACTIONS = {
  { label = "Add Item...", handler = function(field)
      field.__new_value_input = ""
      field.__new_short_input = ""
      field.__new_item_error  = nil
      field.__open_add_item_popup = true
    end },
}

SchemeEditorGui.ITEM_ACTIONS = {
  { label = "Move Up", enabled = function(i, n) return i > 1 end,
    handler = function(field, source_path, i) return Editor.CommitMoveItem(field, source_path, i, -1) end },
  { label = "Move Down", enabled = function(i, n) return i < n end,
    handler = function(field, source_path, i) return Editor.CommitMoveItem(field, source_path, i, 1) end },
}

-- Ambient (non-interactive) notice shown at the top of a wildcard-backed
-- field's menus/popup: this list is a shared `$name` definition reused by
-- other field(s) in the scheme, so editing it here has a wider blast radius
-- than a normal per-field list.
local function DrawWildcardWarning(ctx, field)
  if not field.__wildcard_key then return end
  reaper.ImGui_TextColored(ctx, 0xFFAA00FF, "Shared list ($" .. field.__wildcard_key .. ")")
  reaper.ImGui_TextDisabled(ctx, "Changes here affect every field using $" .. field.__wildcard_key .. ".")
  reaper.ImGui_Separator(ctx)
end

-- Right-click menu attached to the dropdown control itself (whole-list
-- actions). Must be called immediately after the widget it should attach
-- to (the combo box, or the filter InputText), before any other widget is
-- drawn, since BeginPopupContextItem binds to "the last item".
local function DrawListContextMenu(ctx, field, title)
  if not field.__value_line then return end
  if reaper.ImGui_BeginPopupContextItem(ctx, "ListCtx_" .. title) then
    DrawWildcardWarning(ctx, field)
    for _, action in ipairs(SchemeEditorGui.LIST_ACTIONS) do
      if reaper.ImGui_MenuItem(ctx, action.label) then action.handler(field) end
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- Right-click menu attached to one option row (per-item actions). Must be
-- called immediately after that row's Selectable(), before the next one.
local function DrawItemContextMenu(ctx, field, source_path, title, i)
  if not field.__value_line then return nil end
  local reload_requests = nil
  if reaper.ImGui_BeginPopupContextItem(ctx, "ItemCtx_" .. title .. "_" .. i) then
    DrawWildcardWarning(ctx, field)
    for _, action in ipairs(SchemeEditorGui.ITEM_ACTIONS) do
      local en = action.enabled(i, #field.value)
      if not en then reaper.ImGui_BeginDisabled(ctx) end
      if reaper.ImGui_MenuItem(ctx, action.label) then
        local ok, err, rr = action.handler(field, source_path, i)
        if ok then
          reload_requests = rr
        else
          Helpers.msg(err, "The Last Renamer")
        end
      end
      if not en then reaper.ImGui_EndDisabled(ctx) end
    end
    reaper.ImGui_EndPopup(ctx)
  end
  return reload_requests
end

-- Popup opened by the "Add Item..." menu entry - ported from the former
-- "+"-button popup, now triggered via field.__open_add_item_popup instead.
local function DrawAddItemPopup(ctx, field, source_path, title)
  if field.__open_add_item_popup then
    field.__open_add_item_popup = nil
    reaper.ImGui_OpenPopup(ctx, "AddItem_" .. title)
  end

  local reload_requests = nil
  if reaper.ImGui_BeginPopup(ctx, "AddItem_" .. title) then
    reaper.ImGui_Text(ctx, "Add option to \"" .. field.field .. "\"")
    DrawWildcardWarning(ctx, field)

    local rv
    rv, field.__new_value_input = reaper.ImGui_InputText(ctx, "New Value##" .. title,
      field.__new_value_input or "")
    if field.short then
      rv, field.__new_short_input = reaper.ImGui_InputText(ctx, "Short Code##" .. title,
        field.__new_short_input or "")
    end

    local trimmed_value = (field.__new_value_input or ""):match("^%s*(.-)%s*$")
    local trimmed_short  = (field.__new_short_input or ""):match("^%s*(.-)%s*$")

    local err = nil
    if trimmed_value == "" then
      err = "Value cannot be blank."
    else
      for _, existing in ipairs(field.value) do
        if tostring(existing):lower() == trimmed_value:lower() then
          err = "\"" .. trimmed_value .. "\" already exists in this list."
          break
        end
      end
    end
    if not err and field.short and trimmed_short == "" then
      err = "Short code cannot be blank."
    end

    if err then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, err)
    elseif field.__new_item_error then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, field.__new_item_error)
    end

    local can_submit = not err
    if not can_submit then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Save") then
      local ok, save_err, rr = Editor.CommitAddItem(field, source_path, trimmed_value,
        field.short and trimmed_short or nil)
      if ok then
        field.__new_item_error = nil
        reload_requests = rr
        reaper.ImGui_CloseCurrentPopup(ctx)
      else
        field.__new_item_error = save_err
      end
    end
    if not can_submit then reaper.ImGui_EndDisabled(ctx) end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel") then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
  return reload_requests
end

-- Returns rv, rownum, rowtext, reload_requests. rv/rownum/rowtext mirror the
-- old acendan.ImGui_ComboBox; reload_requests is a non-nil array of
-- {path, new_value} entries when an Add/Move action just wrote to disk and
-- the caller (LoadField) should schedule a scheme reload (usually one entry,
-- but a shared $wildcard list can affect more than one field at once).
function SchemeEditorGui.ComboBox(ctx, field, source_path)
  local ret, reload_requests = nil, nil
  local title = field.field

  if reaper.ImGui_BeginCombo(ctx, title, field.value[field.selected]) then
    for i, value in ipairs(field.value) do
      local is_selected = field.selected == i
      if reaper.ImGui_Selectable(ctx, value, is_selected) then
        ret = { i, value }
      end
      if is_selected then reaper.ImGui_SetItemDefaultFocus(ctx) end
      local rr = DrawItemContextMenu(ctx, field, source_path, title, i)
      if rr then reload_requests = rr end
    end
    reaper.ImGui_EndCombo(ctx)
  end

  DrawListContextMenu(ctx, field, title)
  local rr_add = DrawAddItemPopup(ctx, field, source_path, title)
  if rr_add then reload_requests = rr_add end

  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushItemFlag(ctx, reaper.ImGui_ItemFlags_NoTabStop(), true)
  if reaper.ImGui_SmallButton(ctx, 'x##' .. title) then
    ret = { 0, "" }
  end
  reaper.ImGui_PopItemFlag(ctx)
  Helpers.ImGui_Tooltip("Clear selection.")

  if ret then return true, ret[1], ret[2], reload_requests end
  return nil, nil, nil, reload_requests
end

function SchemeEditorGui.AutoFillComboBox(ctx, field, source_path, filter)
  assert(filter, "AutoFillComboBox: filter is nil. Please create a filter with ImGui_TextFilter_Create()")
  local title = field.field
  local items, selected = field.value, field.selected
  local ret, reload_requests = nil, nil

  local rv, str = reaper.ImGui_InputText(ctx, title .. "##" .. title .. "_filter",
    reaper.ImGui_TextFilter_Get(filter), reaper.ImGui_InputTextFlags_EscapeClearsAll())
  if rv and reaper.ImGui_IsItemActive(ctx) then reaper.ImGui_TextFilter_Set(filter, str) end

  -- Attached here, immediately after the filter InputText, while it's still
  -- "the last item" - must come before any other widget is drawn below.
  DrawListContextMenu(ctx, field, title)
  local rr_add = DrawAddItemPopup(ctx, field, source_path, title)
  if rr_add then reload_requests = rr_add end

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
  if reaper.ImGui_BeginPopup(ctx, title .. "_popup", Helpers.ImGui_AutoFillComboFlags) then
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
          local rr_item = DrawItemContextMenu(ctx, field, source_path, title, i)
          if rr_item then reload_requests = rr_item end
        end
      end
      reaper.ImGui_EndListBox(ctx)
    end
    if tabbed or clicked then reaper.ImGui_CloseCurrentPopup(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end
  if tabbed and #visible_items > 0 then
    local first_visible_item = visible_items[1]
    ret = { Helpers.tableContainsVal(items, first_visible_item), first_visible_item }
  end
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_PushItemFlag(ctx, reaper.ImGui_ItemFlags_NoTabStop(), true)
  if reaper.ImGui_SmallButton(ctx, 'x##' .. title) then
    ret = { 0, "" }
    reaper.ImGui_TextFilter_Clear(filter)
  end
  reaper.ImGui_PopItemFlag(ctx)
  Helpers.ImGui_Tooltip("Clear selection.")
  if filteractive and (tabbed or clicked) then reaper.ImGui_SetKeyboardFocusHere(ctx) end
  if ret then
    reaper.ImGui_TextFilter_Set(filter, ret[2])
    return true, ret[1], ret[2], reload_requests
  end
  return nil, nil, nil, reload_requests
end

return SchemeEditorGui
