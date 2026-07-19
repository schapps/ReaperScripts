-- @noindex
-- SchemeStructureEditorGui: the field-creation/editing form popup, right-
-- click context menus ("Add Top-Level Field...", "Add Child Field...",
-- "Edit Field...", "Delete Field..."), and the "Undo Last Change" control
-- for the Visual Editor window. The same form popup serves both creating a
-- new field and editing an existing one (form.action = "create" | "edit"),
-- since the two share almost the entire property-editing UI.
--
-- Depends on SchemeStructureEditor.lua (pure logic/file-I/O) and the main
-- script's `acendan` helper table, both injected via init() since dofile'd
-- chunks don't share the main script's `local` variables.

local SchemeStructureEditorGui = {}

local Editor, Helpers

function SchemeStructureEditorGui.init(structure_editor, helpers)
  Editor = structure_editor
  Helpers = helpers
end

local CAPITALIZATION_OPTIONS = { "None", "Title", "PascalCase", "UPPER", "lower" }
local TYPE_OPTIONS = { "Dropdown", "Text", "Boolean", "Number" }
local TYPE_KEYS = { "dropdown", "text", "boolean", "number" }

-- Module-local form state - only one creation popup can be open at a time
-- across the whole Visual Editor window, so this doesn't need per-call
-- instancing (mirrors the field.__new_value_input-style state already used
-- for the Add-Item popup elsewhere in this codebase, just not tied to a
-- specific field object since a "create" has no pre-existing field yet).
local form = {
  pending_open = false,
  action = "create",   -- "create" | "edit"
  target_field = nil,  -- the field being edited, only set when action == "edit"
  mode = nil,          -- "top_level" | "child"
  parent_field = nil,
  target = nil,
  type_idx = 1,
  label = "",
  required = false,
  skip = false,
  capitalization_idx = 1,
  separator = "",
  help = "",
  options = {},         -- dropdown: array of { value = "", short = "" }
  use_short = false,
  use_wildcard = false, -- dropdown: use an existing $wildcard instead of literal options
  wildcard_ref = nil,   -- dropdown: the selected wildcard's name (no leading $)
  text_value = "",
  hint = "",
  bool_value = false,
  btrue = "",
  bfalse = "",
  num_value = "1",
  zeroes = "",
  singles = false,
  id_checks = {},       -- child mode: option-string (or "true"/"false") -> bool
  error = nil,
}

-- Module-local delete-confirmation state - same "only one at a time"
-- reasoning as `form` above.
local delete_state = {
  pending_open = false,
  field = nil,
  error = nil,
}

-- Module-local "Extract to $wildcard" popup state - same "only one at a
-- time" reasoning as `form`/`delete_state` above.
local extract_state = {
  pending_open = false,
  field = nil,
  name_input = "",
  error = nil,
}

-- Module-local "Link to $wildcard" popup state - the inverse of
-- extract_state: points a field at an ALREADY-EXISTING wildcard instead of
-- creating a new one. `defs` is rebuilt fresh from disk each time the
-- popup opens (list-type wildcards only, since a dropdown's value must be
-- a list).
local link_state = {
  pending_open = false,
  field = nil,
  defs = nil,
  selected_idx = 1,
  error = nil,
}

-- Module-local "Manage Wildcards" popup state. `rows` is rebuilt fresh from
-- disk (via Editor.ListWildcardDefinitions) each time the popup opens, and
-- again after every successful commit inside it - each row wraps one
-- definition with its own mutable UI buffers (editable items/value, a
-- rename buffer, a per-row error).
local wildcards_state = {
  pending_open = false,
  rows = nil,
}

-- Module-local "Root Settings" popup state - same "read fresh from disk on
-- open, edit in local buffers, Save commits, popup stays open across a
-- successful save" pattern as wildcards_state. `.present` on each entry
-- tracks whether the key currently exists in the file at all (most of these
-- six keys are frequently absent), so "Clear" can be disabled when there's
-- nothing to clear.
local root_settings_state = {
  pending_open = false,
  separator = { present = false, buf = "" },
  illegal   = { present = false, items = {} },
  find      = { present = false, items = {} },
  replace   = { present = false, buf = "" },
  maxchars  = { present = false, buf = "" },
  dupes     = { present = false, value = false },
  error = nil,
}

-- Module-local "Move to..." popup state - same "only one at a time"
-- reasoning as the others above. `destinations` is rebuilt each time the
-- popup opens: "Top Level" plus every dropdown/boolean field in the tree
-- except `field` itself, its own descendants, and its CURRENT parent
-- (reparenting to the same parent is refused server-side too, but excluding
-- it here keeps the destination list from offering a choice that always fails).
local move_state = {
  pending_open = false,
  field = nil,
  destinations = nil,
  selected_idx = 1,
  ref_field = nil,  -- nil = append at the end of the destination's children;
                    -- set = insert immediately after this specific sibling instead
  id_checks = {},
  error = nil,
}

local function FormatIdForLabel(id)
  if type(id) == "table" then
    local parts = {}
    for _, v in ipairs(id) do parts[#parts + 1] = tostring(v) end
    return table.concat(parts, ", ")
  end
  return tostring(id)
end

-- Recursively collects every dropdown/boolean field under `fields` that
-- could accept `field` as a new child - excluding `field` itself, anything
-- inside its own subtree (via Editor.ContainsField), and its current parent.
-- `ancestor_label` (the immediate parent's own label, nil at the top level)
-- gets folded into the destination's displayed label, since field labels
-- aren't unique across the tree - e.g. Example.yaml has three separate
-- "Manufacturer" fields, all children of the SAME "Country" field, each
-- under a different id condition, so the parent's label alone wouldn't
-- disambiguate them either; the id condition is included too.
local function CollectMoveDestinations(fields, field, current_parent, ancestor_label, out)
  for _, f in ipairs(fields) do
    if f ~= field and f ~= current_parent and not Editor.ContainsField(field, f) then
      if type(f.value) == "table" or type(f.value) == "boolean" then
        local label = f.field
        if ancestor_label then
          label = label .. "  (under " .. ancestor_label ..
            (f.id ~= nil and (" = " .. FormatIdForLabel(f.id)) or "") .. ")"
        end
        out[#out + 1] = { label = label, target_field = f }
      end
    end
    if f.fields then CollectMoveDestinations(f.fields, field, current_parent, f.field, out) end
  end
end

local function BuildMoveDestinations(top_level_fields, field, current_parent)
  local destinations = { { label = "Top Level", target_field = nil } }
  CollectMoveDestinations(top_level_fields, field, current_parent, nil, destinations)
  return destinations
end

-- Drag-and-drop's entry point into the exact same "Move to..." machinery
-- the right-click menu uses - the destination is already chosen (whatever
-- node the user dropped onto), so this just seeds `move_state` with that
-- destination pre-selected and opens the SAME DrawMoveToPopup, skipping
-- straight to the id-condition picker. Nothing commits without the user
-- still clicking "Move" in that popup - a drop only ever pre-fills the
-- destination, never bypasses confirmation.
--
-- Returns nil on success (popup now pending-open), or an error string if
-- `dropped_on_field` isn't a valid destination for `field` at all (dropped
-- onto itself, a non-container field, one of its own descendants, or its
-- current parent) - BuildMoveDestinations already excludes all of those,
-- so "not found in the list" is exactly the same validation the menu path
-- gets, just surfaced as a message instead of a disabled combo entry.
function SchemeStructureEditorGui.OpenMoveToPopupForDrop(field, current_parent, top_level_fields, dropped_on_field)
  local destinations = BuildMoveDestinations(top_level_fields, field, current_parent)
  local match_idx = nil
  for i, dest in ipairs(destinations) do
    if dest.target_field == dropped_on_field then match_idx = i; break end
  end
  if not match_idx then
    return "Can't move \"" .. field.field .. "\" there - the target must be a dropdown or checkbox " ..
      "field, and not " .. field.field .. "'s own current parent or one of its descendants."
  end

  move_state.pending_open = true
  move_state.field = field
  move_state.destinations = destinations
  move_state.selected_idx = match_idx
  move_state.ref_field = nil
  move_state.id_checks = {}
  move_state.error = nil
  return nil
end

-- Drag-and-drop's entry point when the dropped-on node CAN'T be a parent
-- (not a dropdown/checkbox) - rather than refusing outright, the next best
-- interpretation is "become a sibling of the dropped-on field, positioned
-- immediately after it". The actual reparent destination is
-- `dropped_on_parent` (that field's OWN current parent - nil for
-- top-level), not `dropped_on_field` itself (which can't have children);
-- `dropped_on_field` only ever supplies the position to anchor after.
--
-- Returns nil on success (popup now pending-open, pre-selected to
-- `dropped_on_parent` with `ref_field` set), or an error string if
-- `dropped_on_field` is `field` itself or one of its own descendants -
-- can't become a sibling of either of those either.
function SchemeStructureEditorGui.OpenMoveToPopupForSiblingDrop(field, current_parent, top_level_fields, dropped_on_field, dropped_on_parent)
  if dropped_on_field == field or Editor.ContainsField(field, dropped_on_field) then
    return "Can't move \"" .. field.field .. "\" there - it can't be positioned relative to itself or one of its own descendants."
  end

  local destinations = BuildMoveDestinations(top_level_fields, field, current_parent)
  local match_idx = nil
  for i, dest in ipairs(destinations) do
    if dest.target_field == dropped_on_parent then match_idx = i; break end
  end
  if not match_idx then
    return "Can't move \"" .. field.field .. "\" there."
  end

  move_state.pending_open = true
  move_state.field = field
  move_state.destinations = destinations
  move_state.selected_idx = match_idx
  move_state.ref_field = dropped_on_field
  move_state.id_checks = {}
  move_state.error = nil
  return nil
end

-- Drag-and-drop's entry point for REORDERING: dropping a field onto one of
-- its own current siblings (same parent) moves it to sit immediately after
-- that sibling - immediately, no popup, since nothing about parent/id-
-- condition is changing (matches Move Up/Down's existing immediate style).
-- Thin wrapper so SchemeVisualizer.lua doesn't need its own separate
-- dependency on SchemeStructureEditor - it already only talks to this module.
function SchemeStructureEditorGui.CommitReorderForDrop(source_path, siblings, field, ref_field)
  return Editor.CommitReorderFieldTo(source_path, siblings, field, ref_field)
end

local function ResetForm(mode, parent_field, target)
  form.pending_open = true
  form.action = "create"
  form.target_field = nil
  form.mode = mode
  form.parent_field = parent_field
  form.target = target
  form.type_idx = 1
  form.label = ""
  form.required = false
  form.skip = false
  form.capitalization_idx = 1
  form.separator = ""
  form.help = ""
  form.options = { { value = "", short = "" } }
  form.use_short = false
  form.use_wildcard = false
  form.wildcard_ref = nil
  form.text_value = ""
  form.hint = ""
  form.bool_value = false
  form.btrue = ""
  form.bfalse = ""
  form.num_value = "1"
  form.zeroes = ""
  form.singles = false
  form.id_checks = {}
  form.error = nil
end

-- Finds the index of `value` in `list` (linear search over a plain array),
-- or 1 as a safe fallback if not found - used to preselect the type/
-- capitalization combos when populating the form from an existing field.
local function IndexOf(list, value)
  for i, v in ipairs(list) do
    if v == value then return i end
  end
  return 1
end

-- Populates the form from an EXISTING field's current properties, for the
-- "Edit Field..." action - the inverse of BuildFieldSpec/BuildIdValue
-- below. `parent_field` is needed (not derivable from `field` alone, since
-- fields don't store a back-reference) to know which options the id-
-- condition picker should offer - threaded in from the visualizer's node
-- layout, which already tracks it for edge-drawing purposes.
local function ResetFormForEdit(field, parent_field)
  form.pending_open = true
  form.action = "edit"
  form.target_field = field
  form.mode = field.id ~= nil and "child" or "top_level"
  form.parent_field = parent_field
  form.target = nil

  form.label = field.field
  form.required = field.required or false
  form.skip = field.skip or false
  form.capitalization_idx = IndexOf(CAPITALIZATION_OPTIONS, field.capitalization)
  form.separator = field.separator or ""
  form.help = field.help or ""

  form.options = { { value = "", short = "" } }
  form.use_short = false
  form.use_wildcard = false
  form.wildcard_ref = nil
  form.text_value = ""
  form.hint = ""
  form.bool_value = false
  form.btrue = ""
  form.bfalse = ""
  form.num_value = "1"
  form.zeroes = ""
  form.singles = false

  if type(field.value) == "table" then
    form.type_idx = IndexOf(TYPE_KEYS, "dropdown")
    form.options = {}
    for i, v in ipairs(field.value) do
      form.options[i] = { value = tostring(v), short = field.short and field.short[i] or "" }
    end
    form.use_short = field.short ~= nil
  elseif type(field.value) == "boolean" then
    form.type_idx = IndexOf(TYPE_KEYS, "boolean")
    form.bool_value = field.value
    form.btrue = field.btrue or ""
    form.bfalse = field.bfalse or ""
  elseif type(field.value) == "number" then
    form.type_idx = IndexOf(TYPE_KEYS, "number")
    form.num_value = tostring(field.value)
    form.zeroes = field.zeroes and tostring(field.zeroes) or ""
    form.singles = field.singles or false
  else
    form.type_idx = IndexOf(TYPE_KEYS, "text")
    form.text_value = field.value or ""
    form.hint = field.hint or ""
  end

  form.id_checks = {}
  if form.mode == "child" then
    if type(field.id) == "table" then
      for _, v in ipairs(field.id) do form.id_checks[v] = true end
    elseif type(field.id) == "boolean" then
      form.id_checks[tostring(field.id)] = true
    else
      form.id_checks[field.id] = true
    end
  end

  form.error = nil
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~ CONTEXT MENUS ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Right-click empty canvas background -> whole-scheme actions. Must be
-- called right after the canvas child window begins, before any node is
-- drawn, since BeginPopupContextWindow binds to the current window itself.
function SchemeStructureEditorGui.DrawCanvasContextMenu(ctx)
  -- NoOpenOverItems: without it, right-clicking a node (drawn on top of
  -- this same canvas child window) would ALSO trigger this window-level
  -- menu underneath it, alongside the node's own context menu.
  local flags = reaper.ImGui_PopupFlags_MouseButtonRight() | reaper.ImGui_PopupFlags_NoOpenOverItems()
  if reaper.ImGui_BeginPopupContextWindow(ctx, "CanvasCtx", flags) then
    if reaper.ImGui_MenuItem(ctx, "Add Top-Level Field...") then
      ResetForm("top_level", nil, { kind = "top_level_append" })
    end
    reaper.ImGui_EndPopup(ctx)
  end
end

-- Right-click a node -> "Add Child Field...", only meaningful under a
-- dropdown or boolean parent (PassesIDCheck only resolves an id condition
-- against a table- or boolean-valued parent's .selected - a string/number
-- parent has no such branching, and every existing nesting parent in the
-- real scheme corpus is one of these two types). Shown disabled with an
-- explanatory tooltip otherwise, rather than hidden.
--
-- Returns a reload_requests array (non-nil) if "Move Up"/"Move Down" was
-- clicked and committed successfully this frame (the only immediate,
-- non-popup-mediated action here), else nil - every other action is
-- deferred-open (a popup drawn later this same frame).
function SchemeStructureEditorGui.DrawNodeContextMenu(ctx, field, node_id, parent_field, top_level_fields, source_path)
  local reload_requests = nil
  if reaper.ImGui_BeginPopupContextItem(ctx, "StructNodeCtx_" .. node_id) then
    if reaper.ImGui_MenuItem(ctx, "Edit Field...") then
      ResetFormForEdit(field, parent_field)
    end

    local can_have_children = type(field.value) == "table" or type(field.value) == "boolean"
    if not can_have_children then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_MenuItem(ctx, "Add Child Field...") then
      ResetForm("child", field, { kind = "child_append", parent_field = field })
    end
    if not can_have_children then
      reaper.ImGui_EndDisabled(ctx)
      Helpers.ImGui_Tooltip("Only dropdown or checkbox fields can have conditional children.")
    end

    -- Only a literal (non-wildcard-backed) dropdown has a `value: [...]`
    -- list of its own to extract - a shared list already IS a wildcard, and
    -- non-dropdown types have nothing list-shaped to share.
    local can_extract = type(field.value) == "table" and not field.__wildcard_key
    if not can_extract then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_MenuItem(ctx, "Extract to $wildcard...") then
      extract_state.pending_open = true
      extract_state.field = field
      extract_state.name_input = ""
      extract_state.error = nil
    end
    if not can_extract then
      reaper.ImGui_EndDisabled(ctx)
      Helpers.ImGui_Tooltip(field.__wildcard_key
        and "This field's value is already a shared $wildcard."
        or "Only dropdown fields can be extracted to a shared wildcard.")
    end

    -- Same enable condition as "Extract to $wildcard..." (a literal,
    -- non-wildcard dropdown) - linking replaces that same value: [...] list
    -- with a $name reference, just to an EXISTING definition instead of a
    -- brand-new one.
    if not can_extract then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_MenuItem(ctx, "Link to $wildcard...") then
      link_state.pending_open = true
      link_state.field = field
      link_state.defs = {}
      for _, def in ipairs(Editor.ListWildcardDefinitions(source_path)) do
        if def.is_list then link_state.defs[#link_state.defs + 1] = def end
      end
      link_state.selected_idx = 1
      link_state.error = nil
    end
    if not can_extract then
      reaper.ImGui_EndDisabled(ctx)
      Helpers.ImGui_Tooltip(field.__wildcard_key
        and "This field's value is already a shared $wildcard."
        or "Only dropdown fields can be linked to a shared wildcard.")
    end

    reaper.ImGui_Separator(ctx)

    -- Reorder among siblings - executed IMMEDIATELY (no confirmation), low
    -- risk and already covered by undo, matching the main window's existing
    -- immediate "Move Up"/"Move Down" for dropdown options.
    local siblings = parent_field and parent_field.fields or top_level_fields
    local index = nil
    for i, f in ipairs(siblings) do if f == field then index = i; break end end
    local can_move_up = index and index > 1
    local can_move_down = index and index < #siblings

    if not can_move_up then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_MenuItem(ctx, "Move Up") then
      local ok, err, reqs = Editor.CommitMoveFieldBlock(source_path, siblings, field, -1)
      if ok then reload_requests = reqs else Helpers.msg(err, "The Last Renamer") end
    end
    if not can_move_up then reaper.ImGui_EndDisabled(ctx) end

    if not can_move_down then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_MenuItem(ctx, "Move Down") then
      local ok, err, reqs = Editor.CommitMoveFieldBlock(source_path, siblings, field, 1)
      if ok then reload_requests = reqs else Helpers.msg(err, "The Last Renamer") end
    end
    if not can_move_down then reaper.ImGui_EndDisabled(ctx) end

    if reaper.ImGui_MenuItem(ctx, "Move to...") then
      move_state.pending_open = true
      move_state.field = field
      move_state.destinations = BuildMoveDestinations(top_level_fields, field, parent_field)
      move_state.selected_idx = 1
      move_state.ref_field = nil
      move_state.id_checks = {}
      move_state.error = nil
    end

    reaper.ImGui_Separator(ctx)
    -- Warning-colored text, distinct from the plain menu items above -
    -- clicking it opens a confirmation dialog rather than deleting
    -- immediately (see DrawDeleteConfirmPopup), since a single accidental
    -- menu click on a node with a large subtree (e.g. UCS.yaml's Category,
    -- ~80 nested Subcategory blocks) would otherwise be a bad experience
    -- even with the backup/undo safety net.
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xFF6B6BFF)
    if reaper.ImGui_MenuItem(ctx, "Delete Field...") then
      delete_state.pending_open = true
      delete_state.field = field
      delete_state.error = nil
    end
    reaper.ImGui_PopStyleColor(ctx)

    reaper.ImGui_EndPopup(ctx)
  end
  return reload_requests
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~ FORM -> FIELD SPEC ~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Extracted so DrawMoveToPopup can build an id value against an arbitrary
-- (not necessarily `form.parent_field`) target parent too.
local function BuildIdValueFrom(parent_field, id_checks)
  local selected = {}
  if type(parent_field.value) == "boolean" then
    if id_checks["true"] then selected[#selected + 1] = true end
    if id_checks["false"] then selected[#selected + 1] = false end
  else
    for _, opt in ipairs(parent_field.value) do
      if id_checks[opt] then selected[#selected + 1] = opt end
    end
  end
  if #selected == 0 then return nil end
  if #selected == 1 then return selected[1] end
  return selected
end

local function BuildIdValue()
  if form.mode ~= "child" then return nil end
  return BuildIdValueFrom(form.parent_field, form.id_checks)
end

local function BuildFieldSpec()
  local type_key = TYPE_KEYS[form.type_idx]
  local spec = {
    type = type_key,
    label = (form.label or ""):match("^%s*(.-)%s*$"),
    required = form.required,
    skip = form.skip,
    capitalization = CAPITALIZATION_OPTIONS[form.capitalization_idx],
    separator = form.separator ~= "" and form.separator or nil,
    help = form.help ~= "" and form.help or nil,
  }

  if type_key == "dropdown" then
    if form.use_wildcard then
      spec.wildcard_ref = form.wildcard_ref
    else
      spec.options, spec.short = {}, form.use_short and {} or nil
      for _, opt in ipairs(form.options) do
        local v = (opt.value or ""):match("^%s*(.-)%s*$")
        if v ~= "" then
          spec.options[#spec.options + 1] = v
          if form.use_short then spec.short[#spec.short + 1] = opt.short or "" end
        end
      end
    end
  elseif type_key == "text" then
    spec.value = form.text_value
    spec.hint = form.hint ~= "" and form.hint or nil
  elseif type_key == "boolean" then
    spec.value = form.bool_value
    -- Unlike hint/help/separator (genuinely optional - many real fields
    -- omit them), a boolean field's btrue/bfalse must ALWAYS both be
    -- written, even as "", matching every existing hand-authored boolean
    -- field in the real scheme corpus - LoadField's rendering does
    -- `field.value and field.btrue or field.bfalse`, which crashes with
    -- "attempt to concatenate a nil value" if the branch actually taken
    -- resolves to a genuinely absent (nil, not merely blank) key.
    spec.btrue = form.btrue or ""
    spec.bfalse = form.bfalse or ""
  elseif type_key == "number" then
    spec.value = tonumber(form.num_value) or 0
    spec.zeroes = tonumber(form.zeroes)
    spec.singles = form.singles
  end

  return spec, BuildIdValue()
end

-- Live, client-side pre-check for enabling/disabling the Create button and
-- showing an inline error - the authoritative validation still happens
-- inside CommitCreateField itself on submit, same "check both places"
-- pattern already used by the Add-Item popup elsewhere in this codebase.
local function ValidateForSubmit(spec, id_value)
  if spec.label == "" then return "Field name cannot be blank." end
  if spec.type == "dropdown" then
    if spec.wildcard_ref then
      if spec.wildcard_ref == "" then return "Select a wildcard." end
    elseif not spec.options or #spec.options == 0 then
      return "Add at least one option."
    end
  end
  if form.mode == "child" and id_value == nil then
    return "Select at least one value that shows this field."
  end
  return nil
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ THE FORM ~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

local function DrawDropdownFields(ctx, source_path)
  local rv
  rv, form.use_wildcard = reaper.ImGui_Checkbox(ctx, "Use an existing $wildcard", form.use_wildcard)

  if form.use_wildcard then
    local defs = {}
    for _, def in ipairs(Editor.ListWildcardDefinitions(source_path)) do
      if def.is_list then defs[#defs + 1] = def end
    end
    if #defs == 0 then
      reaper.ImGui_TextDisabled(ctx, "This scheme has no list-type $wildcards yet - create one via \"Extract to $wildcard...\" first.")
      return
    end

    if not form.wildcard_ref then form.wildcard_ref = defs[1].name end
    reaper.ImGui_Text(ctx, "Wildcard")
    local current
    for _, def in ipairs(defs) do if def.name == form.wildcard_ref then current = def end end
    if reaper.ImGui_BeginCombo(ctx, "##FormWildcard", current and ("$" .. current.name) or "") then
      for i, def in ipairs(defs) do
        if reaper.ImGui_Selectable(ctx, "$" .. def.name .. "##" .. i, form.wildcard_ref == def.name) then
          form.wildcard_ref = def.name
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    if current then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Text(ctx, "Items:")
      for _, v in ipairs(current.items) do
        reaper.ImGui_BulletText(ctx, tostring(v))
      end
    end
    return
  end

  reaper.ImGui_Text(ctx, "Options")
  rv, form.use_short = reaper.ImGui_Checkbox(ctx, "Use short codes", form.use_short)

  local remove_idx, swap_idx = nil, nil
  for i, opt in ipairs(form.options) do
    reaper.ImGui_PushID(ctx, i)
    rv, opt.value = reaper.ImGui_InputText(ctx, "##OptValue", opt.value)
    if form.use_short then
      reaper.ImGui_SameLine(ctx)
      rv, opt.short = reaper.ImGui_InputText(ctx, "##OptShort", opt.short)
    end
    reaper.ImGui_SameLine(ctx)
    if i == 1 then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_SmallButton(ctx, "^") then swap_idx = i - 1 end
    if i == 1 then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_SameLine(ctx)
    if i == #form.options then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_SmallButton(ctx, "v") then swap_idx = i end
    if i == #form.options then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "x") then remove_idx = i end
    reaper.ImGui_PopID(ctx)
  end
  if swap_idx then
    form.options[swap_idx], form.options[swap_idx + 1] = form.options[swap_idx + 1], form.options[swap_idx]
  end
  if remove_idx then table.remove(form.options, remove_idx) end
  if reaper.ImGui_Button(ctx, "+ Add Option") then
    form.options[#form.options + 1] = { value = "", short = "" }
  end
end

-- Takes `parent_field`/`id_checks` explicitly (rather than reading
-- `form.*` directly) so both the create/edit form AND DrawMoveToPopup's
-- separate `move_state` can share this without duplicating the
-- boolean-vs-dropdown branching.
local function DrawIdConditionPicker(ctx, parent_field, id_checks)
  reaper.ImGui_Text(ctx, "Show when parent is:")
  local rv
  if type(parent_field.value) == "boolean" then
    rv, id_checks["true"]  = reaper.ImGui_Checkbox(ctx, "True",  id_checks["true"]  or false)
    reaper.ImGui_SameLine(ctx)
    rv, id_checks["false"] = reaper.ImGui_Checkbox(ctx, "False", id_checks["false"] or false)
  else
    for _, opt in ipairs(parent_field.value) do
      rv, id_checks[opt] = reaper.ImGui_Checkbox(ctx, tostring(opt), id_checks[opt] or false)
    end
  end
end

-- Opened via ResetForm (deferred, matching the field.__open_add_item_popup
-- pattern already used elsewhere: setting a flag here, and the actual
-- reaper.ImGui_OpenPopup call happening on the very next check, since a
-- MenuItem click that triggered ResetForm is itself still closing its own
-- enclosing context-menu popup this same frame).
--
-- Returns a reload_requests array (non-nil) once a field is successfully
-- created this frame, else nil.
function SchemeStructureEditorGui.DrawCreatePopup(ctx, source_path, top_level_fields)
  if form.pending_open then
    form.pending_open = false
    reaper.ImGui_OpenPopup(ctx, "CreateFieldPopup")
  end

  local reload_requests = nil
  if reaper.ImGui_BeginPopup(ctx, "CreateFieldPopup") then
    local title
    if form.action == "edit" then
      title = "Edit \"" .. form.target_field.field .. "\""
    elseif form.mode == "child" then
      title = "Add Child Field under \"" .. form.parent_field.field .. "\""
    else
      title = "Add Top-Level Field"
    end
    reaper.ImGui_Text(ctx, title)
    reaper.ImGui_Separator(ctx)

    local rv
    reaper.ImGui_Text(ctx, "Name")
    rv, form.label = reaper.ImGui_InputText(ctx, "##NewFieldLabel", form.label)

    -- Changing a field's fundamental type isn't supported (delete + recreate
    -- is the agreed workaround) - shown but disabled in edit mode so the
    -- user can still SEE the type without being able to change it.
    reaper.ImGui_Text(ctx, "Type")
    if form.action == "edit" then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_BeginCombo(ctx, "##NewFieldType", TYPE_OPTIONS[form.type_idx]) then
      for i, label in ipairs(TYPE_OPTIONS) do
        if reaper.ImGui_Selectable(ctx, label, form.type_idx == i) then form.type_idx = i end
      end
      reaper.ImGui_EndCombo(ctx)
    end
    if form.action == "edit" then
      reaper.ImGui_EndDisabled(ctx)
      Helpers.ImGui_Tooltip("To change a field's type, delete it and create a new one.")
    end

    reaper.ImGui_Spacing(ctx)
    local type_key = TYPE_KEYS[form.type_idx]
    if type_key == "dropdown" then
      DrawDropdownFields(ctx, source_path)
    elseif type_key == "text" then
      reaper.ImGui_Text(ctx, "Initial Value")
      rv, form.text_value = reaper.ImGui_InputText(ctx, "##TextValue", form.text_value)
      reaper.ImGui_Text(ctx, "Hint")
      rv, form.hint = reaper.ImGui_InputText(ctx, "##Hint", form.hint)
    elseif type_key == "boolean" then
      rv, form.bool_value = reaper.ImGui_Checkbox(ctx, "Initial Value (checked)", form.bool_value)
      reaper.ImGui_Text(ctx, "True Suffix")
      rv, form.btrue = reaper.ImGui_InputText(ctx, "##BTrue", form.btrue)
      reaper.ImGui_Text(ctx, "False Suffix")
      rv, form.bfalse = reaper.ImGui_InputText(ctx, "##BFalse", form.bfalse)
    elseif type_key == "number" then
      reaper.ImGui_Text(ctx, "Initial Value")
      rv, form.num_value = reaper.ImGui_InputText(ctx, "##NumValue", form.num_value)
      reaper.ImGui_Text(ctx, "Zero Padding")
      rv, form.zeroes = reaper.ImGui_InputText(ctx, "##Zeroes", form.zeroes)
      rv, form.singles = reaper.ImGui_Checkbox(ctx, "Singles", form.singles)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)

    if form.mode == "child" then
      DrawIdConditionPicker(ctx, form.parent_field, form.id_checks)
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
    end

    rv, form.required = reaper.ImGui_Checkbox(ctx, "Required", form.required)
    reaper.ImGui_SameLine(ctx)
    rv, form.skip = reaper.ImGui_Checkbox(ctx, "Skip (don't include in name)", form.skip)

    reaper.ImGui_Text(ctx, "Capitalization")
    if reaper.ImGui_BeginCombo(ctx, "##Capitalization", CAPITALIZATION_OPTIONS[form.capitalization_idx]) then
      for i, c in ipairs(CAPITALIZATION_OPTIONS) do
        if reaper.ImGui_Selectable(ctx, c, form.capitalization_idx == i) then form.capitalization_idx = i end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    reaper.ImGui_Text(ctx, "Separator (optional)")
    rv, form.separator = reaper.ImGui_InputText(ctx, "##Separator", form.separator)

    reaper.ImGui_Text(ctx, "Help Text (optional)")
    rv, form.help = reaper.ImGui_InputText(ctx, "##Help", form.help)

    reaper.ImGui_Spacing(ctx)
    local field_spec, id_value = BuildFieldSpec()
    local err = ValidateForSubmit(field_spec, id_value)

    if err then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, err)
    elseif form.error then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, form.error)
    end

    local can_submit = not err
    if not can_submit then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, form.action == "edit" and "Save" or "Create") then
      field_spec.id = id_value
      local ok, save_err, reqs
      if form.action == "edit" then
        ok, save_err, reqs = Editor.CommitEditField(source_path, form.target_field, field_spec, form.mode == "child")
      else
        ok, save_err, reqs = Editor.CommitCreateField(source_path, top_level_fields, form.target, field_spec)
      end
      if ok then
        form.error = nil
        reload_requests = reqs
        reaper.ImGui_CloseCurrentPopup(ctx)
      else
        form.error = save_err
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

-- Opened via the "Delete Field..." menu entry (deferred-open, same pattern
-- as DrawCreatePopup). Shows a descendant-count warning when the field has
-- nested children, since deleting it removes the whole subtree. Returns a
-- reload_requests array (non-nil) once a field is successfully deleted
-- this frame, else nil.
function SchemeStructureEditorGui.DrawDeleteConfirmPopup(ctx, source_path)
  if delete_state.pending_open then
    delete_state.pending_open = false
    reaper.ImGui_OpenPopup(ctx, "DeleteFieldPopup")
  end

  local reload_requests = nil
  if reaper.ImGui_BeginPopup(ctx, "DeleteFieldPopup") then
    local field = delete_state.field
    reaper.ImGui_Text(ctx, "Delete \"" .. field.field .. "\"?")

    local descendant_count = Editor.CountDescendants(field)
    if descendant_count > 0 then
      reaper.ImGui_TextColored(ctx, 0xFF6B6BFF,
        "This will also delete " .. descendant_count .. " nested field" ..
        (descendant_count == 1 and "" or "s") .. ".")
    end

    if delete_state.error then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, delete_state.error)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xB33A3AFF)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xCC4747FF)
    if reaper.ImGui_Button(ctx, "Delete") then
      local ok, err, reqs = Editor.CommitDeleteField(source_path, field)
      if ok then
        delete_state.error = nil
        delete_state.field = nil
        reload_requests = reqs
        reaper.ImGui_CloseCurrentPopup(ctx)
      else
        delete_state.error = err
      end
    end
    reaper.ImGui_PopStyleColor(ctx, 2)

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel") then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
  return reload_requests
end

-- Opened via the "Extract to $wildcard..." menu entry (deferred-open, same
-- pattern as DrawCreatePopup/DrawDeleteConfirmPopup). Returns a
-- reload_requests array (non-nil) once the extraction succeeds this frame,
-- else nil.
function SchemeStructureEditorGui.DrawExtractToWildcardPopup(ctx, source_path)
  if extract_state.pending_open then
    extract_state.pending_open = false
    reaper.ImGui_OpenPopup(ctx, "ExtractToWildcardPopup")
  end

  local reload_requests = nil
  if reaper.ImGui_BeginPopup(ctx, "ExtractToWildcardPopup") then
    reaper.ImGui_Text(ctx, "Extract \"" .. extract_state.field.field .. "\" to a shared $wildcard")
    reaper.ImGui_Separator(ctx)

    reaper.ImGui_Text(ctx, "Wildcard Name")
    local rv
    rv, extract_state.name_input = reaper.ImGui_InputText(ctx, "##WildcardName", extract_state.name_input)
    Helpers.ImGui_Tooltip("Letters, numbers, and underscores only - referenced elsewhere as $" ..
      (extract_state.name_input ~= "" and extract_state.name_input or "name") .. ".")

    if extract_state.error then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, extract_state.error)
    end

    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Extract") then
      local ok, err, reqs = Editor.CommitExtractToWildcard(source_path, extract_state.field, extract_state.name_input)
      if ok then
        extract_state.error = nil
        reload_requests = reqs
        reaper.ImGui_CloseCurrentPopup(ctx)
      else
        extract_state.error = err
      end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Cancel") then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
  return reload_requests
end

-- Opened via the "Link to $wildcard..." menu entry (deferred-open, same
-- pattern as the other popups) - the inverse of the extract popup: instead
-- of naming a brand-new wildcard, pick one that already exists from a
-- combo (list-type only), with a live preview of its current items so
-- linking's effect (the field's current literal options are discarded in
-- favor of whatever the wildcard already holds) is visible before
-- confirming. Warns if the field also has `short:` codes, since those stay
-- field-owned and may no longer line up with the newly-linked list.
function SchemeStructureEditorGui.DrawLinkToWildcardPopup(ctx, source_path)
  if link_state.pending_open then
    link_state.pending_open = false
    reaper.ImGui_OpenPopup(ctx, "LinkToWildcardPopup")
  end

  local reload_requests = nil
  if reaper.ImGui_BeginPopup(ctx, "LinkToWildcardPopup") then
    reaper.ImGui_Text(ctx, "Link \"" .. link_state.field.field .. "\" to an existing $wildcard")
    reaper.ImGui_Separator(ctx)

    local defs = link_state.defs or {}
    if #defs == 0 then
      reaper.ImGui_TextDisabled(ctx, "This scheme has no list-type $wildcards yet - create one via \"Extract to $wildcard...\" first.")
    else
      reaper.ImGui_Text(ctx, "Wildcard")
      local current = defs[link_state.selected_idx]
      if reaper.ImGui_BeginCombo(ctx, "##LinkWildcard", current and ("$" .. current.name) or "") then
        for i, def in ipairs(defs) do
          if reaper.ImGui_Selectable(ctx, "$" .. def.name .. "##" .. i, link_state.selected_idx == i) then
            link_state.selected_idx = i
          end
        end
        reaper.ImGui_EndCombo(ctx)
      end

      if current then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Text(ctx, "Items:")
        for _, v in ipairs(current.items) do
          reaper.ImGui_BulletText(ctx, tostring(v))
        end
      end

      if link_state.field.short then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, 0xFFAA00FF,
          "This field has its own short codes, which will stay as-is and may no longer line up with $" ..
          (current and current.name or "...") .. "'s items.")
      end
    end

    if link_state.error then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, link_state.error)
    end

    reaper.ImGui_Spacing(ctx)
    local can_submit = #defs > 0
    if not can_submit then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Link") then
      local def = defs[link_state.selected_idx]
      local ok, err, reqs = Editor.CommitLinkToWildcard(source_path, link_state.field, def.name)
      if ok then
        link_state.error = nil
        reload_requests = reqs
        reaper.ImGui_CloseCurrentPopup(ctx)
      else
        link_state.error = err
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

-- Opened via the "Move to..." menu entry (deferred-open, same pattern as
-- the other popups). `top_level_fields` is needed both to build the
-- destination list (already done in DrawNodeContextMenu, stored on
-- move_state.destinations) and as CommitReparentField's own anchor
-- parameter for a "Top Level" destination. Returns a reload_requests array
-- (non-nil) once the move succeeds this frame, else nil.
function SchemeStructureEditorGui.DrawMoveToPopup(ctx, source_path, top_level_fields)
  if move_state.pending_open then
    move_state.pending_open = false
    reaper.ImGui_OpenPopup(ctx, "MoveToPopup")
  end

  local reload_requests = nil
  if reaper.ImGui_BeginPopup(ctx, "MoveToPopup") then
    reaper.ImGui_Text(ctx, "Move \"" .. move_state.field.field .. "\" to...")
    reaper.ImGui_Separator(ctx)

    local destinations = move_state.destinations or {}
    reaper.ImGui_Text(ctx, "Destination")
    local current = destinations[move_state.selected_idx]
    if reaper.ImGui_BeginCombo(ctx, "##MoveDestination", current and current.label or "") then
      for i, dest in ipairs(destinations) do
        -- Field labels aren't unique across the tree (e.g. Example.yaml has
        -- three separate "Manufacturer" fields, one per country) - the
        -- "##<i>" suffix gives each Selectable its own ImGui ID (ImGui only
        -- displays the text before "##", so the visible label is
        -- unaffected) without it, ReaImGui throws "N visible items with
        -- conflicting ID" the moment two rows share a label.
        if reaper.ImGui_Selectable(ctx, dest.label .. "##" .. i, move_state.selected_idx == i) then
          move_state.selected_idx = i
          -- Manually picking a destination always means "append" - a
          -- pre-seeded ref_field only ever comes from a drag onto a
          -- specific sibling, and shouldn't survive picking a different
          -- destination by hand.
          move_state.ref_field = nil
          move_state.id_checks = {}
        end
      end
      reaper.ImGui_EndCombo(ctx)
    end

    local dest = destinations[move_state.selected_idx]
    local new_id_value = nil
    if dest and dest.target_field then
      reaper.ImGui_Spacing(ctx)
      DrawIdConditionPicker(ctx, dest.target_field, move_state.id_checks)
      new_id_value = BuildIdValueFrom(dest.target_field, move_state.id_checks)
    end

    local err = nil
    if not dest then
      err = "No valid destination available."
    elseif dest.target_field and new_id_value == nil then
      err = "Select at least one value that shows this field."
    end

    if err then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, err)
    elseif move_state.error then
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, move_state.error)
    end

    reaper.ImGui_Spacing(ctx)
    local can_submit = not err
    if not can_submit then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Move") then
      -- ref_field (only ever set via a drag onto a specific non-container
      -- sibling - see OpenMoveToPopupForSiblingDrop) anchors right after
      -- that field instead of appending at the end of the destination's
      -- children; CommitReparentField already supports this via its
      -- "_after" target kinds, just never exercised from the GUI until now.
      local target
      if dest.target_field then
        target = { kind = move_state.ref_field and "child_after" or "child_append",
          parent_field = dest.target_field, ref_field = move_state.ref_field }
      else
        target = { kind = move_state.ref_field and "top_level_after" or "top_level_append",
          ref_field = move_state.ref_field }
      end
      local ok, save_err, reqs = Editor.CommitReparentField(source_path, top_level_fields, move_state.field, target, new_id_value)
      if ok then
        move_state.error = nil
        reload_requests = reqs
        reaper.ImGui_CloseCurrentPopup(ctx)
      else
        move_state.error = save_err
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

-- Refreshes wildcards_state.rows fresh from disk - called both when the
-- popup first opens and after every successful commit inside it, so the
-- popup never shows stale data alongside its own edits.
local function RefreshWildcardRows(source_path)
  local defs = Editor.ListWildcardDefinitions(source_path)
  local rows = {}
  for i, def in ipairs(defs) do
    local items = nil
    if def.is_list then
      items = {}
      for j, v in ipairs(def.items) do items[j] = tostring(v) end
    end
    rows[i] = {
      name = def.name,
      is_list = def.is_list,
      items = items,
      scalar_value = def.raw_value,
      rename_buf = def.name,
      error = nil,
    }
  end
  wildcards_state.rows = rows
end

-- Called from the Visual Editor's toolbar "Manage Wildcards..." button -
-- `wildcards_state` is module-local, so this is the caller's only way to
-- trigger the deferred-open (same reasoning as ResetForm/ResetFormForEdit
-- being the entry points for the create/edit form).
function SchemeStructureEditorGui.OpenWildcardsPopup()
  wildcards_state.pending_open = true
end

-- Opened via the "Manage Wildcards..." button in the Visual Editor's
-- toolbar. Lists every $name definition in the file with inline edit
-- (list-type: add/remove rows, reusing the same shape as DrawDropdownFields
-- minus short codes; scalar-type: a single text field), rename, and delete
-- controls. Returns a reload_requests array (non-nil) once ANY row's commit
-- succeeds this frame, else nil - the popup stays open across a successful
-- edit (rows are simply refreshed), only "Close" dismisses it.
function SchemeStructureEditorGui.DrawWildcardsPopup(ctx, source_path)
  if wildcards_state.pending_open then
    wildcards_state.pending_open = false
    RefreshWildcardRows(source_path)
    reaper.ImGui_OpenPopup(ctx, "ManageWildcardsPopup")
  end

  local reload_requests = nil
  if reaper.ImGui_BeginPopup(ctx, "ManageWildcardsPopup") then
    reaper.ImGui_Text(ctx, "Manage Wildcards")
    reaper.ImGui_Separator(ctx)

    local rows = wildcards_state.rows or {}
    if #rows == 0 then
      reaper.ImGui_TextDisabled(ctx, "This scheme has no $wildcards defined yet.")
    end

    for _, row in ipairs(rows) do
      reaper.ImGui_PushID(ctx, row.name)
      reaper.ImGui_Text(ctx, "$" .. row.name ..
        (row.is_list and ("  (list, " .. #row.items .. " item" .. (#row.items == 1 and "" or "s") .. ")") or "  (text)"))

      local rv
      if row.is_list then
        local remove_idx = nil
        for i, item in ipairs(row.items) do
          reaper.ImGui_PushID(ctx, i)
          rv, row.items[i] = reaper.ImGui_InputText(ctx, "##Item", item)
          reaper.ImGui_SameLine(ctx)
          if reaper.ImGui_SmallButton(ctx, "x") then remove_idx = i end
          reaper.ImGui_PopID(ctx)
        end
        if remove_idx then table.remove(row.items, remove_idx) end
        if reaper.ImGui_Button(ctx, "+ Add Item") then
          row.items[#row.items + 1] = ""
        end
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Save List") then
          local final_items = {}
          for _, v in ipairs(row.items) do
            local trimmed = (v or ""):match("^%s*(.-)%s*$")
            if trimmed ~= "" then final_items[#final_items + 1] = trimmed end
          end
          local ok, err = Editor.CommitEditWildcardList(source_path, row.name, final_items)
          if ok then
            RefreshWildcardRows(source_path)
            reload_requests = {}
          else
            row.error = err
          end
        end
      else
        rv, row.scalar_value = reaper.ImGui_InputText(ctx, "##ScalarValue", row.scalar_value)
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Save") then
          local ok, err = Editor.CommitEditWildcardScalar(source_path, row.name, row.scalar_value)
          if ok then
            RefreshWildcardRows(source_path)
            reload_requests = {}
          else
            row.error = err
          end
        end
      end

      rv, row.rename_buf = reaper.ImGui_InputText(ctx, "##RenameBuf", row.rename_buf)
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Rename") then
        local ok, err = Editor.CommitRenameWildcard(source_path, row.name, row.rename_buf)
        if ok then
          RefreshWildcardRows(source_path)
          reload_requests = {}
        else
          row.error = err
        end
      end

      reaper.ImGui_SameLine(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0xB33A3AFF)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0xCC4747FF)
      if reaper.ImGui_Button(ctx, "Delete") then
        local ok, err = Editor.CommitDeleteWildcard(source_path, row.name)
        if ok then
          RefreshWildcardRows(source_path)
          reload_requests = {}
        else
          row.error = err
        end
      end
      reaper.ImGui_PopStyleColor(ctx, 2)

      if row.error then
        reaper.ImGui_TextColored(ctx, 0xFF0000FF, row.error)
      end

      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_PopID(ctx)
    end

    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx, "Close") then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
  return reload_requests
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~ ROOT SETTINGS ~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Refreshes root_settings_state fresh from disk - called both when the
-- popup first opens and after every successful commit inside it, same
-- reasoning as RefreshWildcardRows.
local function RefreshRootSettings(source_path)
  local s = Editor.ListRootSettings(source_path)
  root_settings_state.separator = { present = s.separator.present, buf = s.separator.value or "" }
  root_settings_state.illegal   = { present = s.illegal.present, items = s.illegal.items or {} }
  root_settings_state.find      = { present = s.find.present, items = s.find.items or {} }
  root_settings_state.replace   = { present = s.replace.present, buf = s.replace.value or "" }
  root_settings_state.maxchars  = { present = s.maxchars.present, buf = s.maxchars.value or "" }
  root_settings_state.dupes     = { present = s.dupes.present, value = (s.dupes.value == "true") }
  root_settings_state.error = nil
end

-- Renders an editable list of plain string rows (add/remove - no reorder,
-- unlike a field's dropdown options, since illegal/find item order has no
-- effect on behavior) into `items` (a flat array of strings, mutated in
-- place). `id` scopes the ImGui IDs so illegal's and find's rows don't collide.
local function DrawStringListRows(ctx, id, items)
  reaper.ImGui_PushID(ctx, id)
  local remove_idx = nil
  for i, item in ipairs(items) do
    reaper.ImGui_PushID(ctx, i)
    local rv
    rv, items[i] = reaper.ImGui_InputText(ctx, "##Item", item)
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, "x") then remove_idx = i end
    reaper.ImGui_PopID(ctx)
  end
  if remove_idx then table.remove(items, remove_idx) end
  if reaper.ImGui_Button(ctx, "+ Add Item") then
    items[#items + 1] = ""
  end
  reaper.ImGui_PopID(ctx)
end

-- Called from the Visual Editor's toolbar "Root Settings..." button - same
-- deferred-open reasoning as OpenWildcardsPopup.
function SchemeStructureEditorGui.OpenRootSettingsPopup()
  root_settings_state.pending_open = true
end

-- Opened via the "Root Settings..." button in the Visual Editor's toolbar.
-- Lists the six root-level scheme settings (separator/replace/illegal/find/
-- maxchars/dupes - see the wiki's "Root" section; title and notesmode are
-- deliberately out of scope: title is the ExtState key for every saved
-- preset/history entry, so renaming it here would orphan them, and
-- notesmode has no reader anywhere in this codebase). Each row has its own
-- Save (and, except dupes, Clear) button - edits stay in local buffers
-- until Save is clicked, same as the wildcards popup. Returns a
-- reload_requests array (non-nil) once ANY row's commit succeeds this
-- frame, else nil - the popup stays open across a successful edit, only
-- "Close" dismisses it.
function SchemeStructureEditorGui.DrawRootSettingsPopup(ctx, source_path)
  if root_settings_state.pending_open then
    root_settings_state.pending_open = false
    RefreshRootSettings(source_path)
    reaper.ImGui_OpenPopup(ctx, "RootSettingsPopup")
  end

  local reload_requests = nil
  if reaper.ImGui_BeginPopup(ctx, "RootSettingsPopup") then
    reaper.ImGui_Text(ctx, "Root Settings")
    reaper.ImGui_Separator(ctx)

    local rv

    -- separator
    reaper.ImGui_PushID(ctx, "separator")
    reaper.ImGui_Text(ctx, "separator" ..
      (root_settings_state.separator.present and "" or "  (not set - fields won't be joined by anything)"))
    rv, root_settings_state.separator.buf = reaper.ImGui_InputText(ctx, "##Buf", root_settings_state.separator.buf)
    if reaper.ImGui_Button(ctx, "Save") then
      local ok, err = Editor.CommitEditRootScalar(source_path, "separator", root_settings_state.separator.buf)
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    reaper.ImGui_SameLine(ctx)
    if not root_settings_state.separator.present then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Clear") then
      local ok, err = Editor.CommitRemoveRootKey(source_path, "separator")
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    if not root_settings_state.separator.present then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_PopID(ctx)
    reaper.ImGui_Separator(ctx)

    reaper.ImGui_TextDisabled(ctx, "illegal and find use Lua patterns, not literal characters " ..
      "(e.g. %. matches a literal period, %% matches a literal percent sign).")

    -- illegal
    reaper.ImGui_PushID(ctx, "illegal")
    reaper.ImGui_Text(ctx, "illegal" ..
      (root_settings_state.illegal.present and "" or "  (not set - falls back to a built-in default list)"))
    DrawStringListRows(ctx, "IllegalRows", root_settings_state.illegal.items)
    if reaper.ImGui_Button(ctx, "Save") then
      local final = {}
      for _, v in ipairs(root_settings_state.illegal.items) do
        local trimmed = (v or ""):match("^%s*(.-)%s*$")
        if trimmed ~= "" then final[#final + 1] = trimmed end
      end
      local ok, err = Editor.CommitEditRootList(source_path, "illegal", final)
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    reaper.ImGui_SameLine(ctx)
    if not root_settings_state.illegal.present then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Clear") then
      local ok, err = Editor.CommitRemoveRootKey(source_path, "illegal")
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    if not root_settings_state.illegal.present then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_PopID(ctx)
    reaper.ImGui_Separator(ctx)

    -- find (kept next to replace - the two are a paired find/replace pass)
    reaper.ImGui_PushID(ctx, "find")
    reaper.ImGui_Text(ctx, "find" ..
      (root_settings_state.find.present and "" or "  (not set - paired with replace below)"))
    DrawStringListRows(ctx, "FindRows", root_settings_state.find.items)
    if reaper.ImGui_Button(ctx, "Save") then
      local final = {}
      for _, v in ipairs(root_settings_state.find.items) do
        local trimmed = (v or ""):match("^%s*(.-)%s*$")
        if trimmed ~= "" then final[#final + 1] = trimmed end
      end
      local ok, err = Editor.CommitEditRootList(source_path, "find", final)
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    reaper.ImGui_SameLine(ctx)
    if not root_settings_state.find.present then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Clear") then
      local ok, err = Editor.CommitRemoveRootKey(source_path, "find")
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    if not root_settings_state.find.present then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_PopID(ctx)
    reaper.ImGui_Separator(ctx)

    -- replace
    reaper.ImGui_PushID(ctx, "replace")
    reaper.ImGui_Text(ctx, "replace" ..
      (root_settings_state.replace.present and "" or "  (not set - paired with find above)"))
    rv, root_settings_state.replace.buf = reaper.ImGui_InputText(ctx, "##Buf", root_settings_state.replace.buf)
    if reaper.ImGui_Button(ctx, "Save") then
      local ok, err = Editor.CommitEditRootScalar(source_path, "replace", root_settings_state.replace.buf)
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    reaper.ImGui_SameLine(ctx)
    if not root_settings_state.replace.present then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Clear") then
      local ok, err = Editor.CommitRemoveRootKey(source_path, "replace")
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    if not root_settings_state.replace.present then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_PopID(ctx)
    reaper.ImGui_Separator(ctx)

    -- maxchars
    reaper.ImGui_PushID(ctx, "maxchars")
    reaper.ImGui_Text(ctx, "maxchars" ..
      (root_settings_state.maxchars.present and "" or "  (not set - no length limit)"))
    rv, root_settings_state.maxchars.buf = reaper.ImGui_InputText(ctx, "##Buf", root_settings_state.maxchars.buf)
    local maxchars_trimmed = (root_settings_state.maxchars.buf or ""):match("^%s*(.-)%s*$")
    local maxchars_num, maxchars_err = nil, nil
    if maxchars_trimmed ~= "" then
      maxchars_num = tonumber(maxchars_trimmed)
      if not maxchars_num or maxchars_num ~= math.floor(maxchars_num) or maxchars_num <= 0 then
        maxchars_err = "Must be blank or a positive whole number."
      end
    end
    if maxchars_err then reaper.ImGui_TextColored(ctx, 0xFF0000FF, maxchars_err) end
    local can_save_maxchars = not maxchars_err
    if not can_save_maxchars then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Save") then
      local ok, err
      if maxchars_trimmed == "" then
        ok, err = Editor.CommitRemoveRootKey(source_path, "maxchars")
      else
        ok, err = Editor.CommitEditRootScalar(source_path, "maxchars", string.format("%d", maxchars_num))
      end
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    if not can_save_maxchars then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_SameLine(ctx)
    if not root_settings_state.maxchars.present then reaper.ImGui_BeginDisabled(ctx) end
    if reaper.ImGui_Button(ctx, "Clear") then
      local ok, err = Editor.CommitRemoveRootKey(source_path, "maxchars")
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    if not root_settings_state.maxchars.present then reaper.ImGui_EndDisabled(ctx) end
    reaper.ImGui_PopID(ctx)
    reaper.ImGui_Separator(ctx)

    -- dupes (no Clear - absent and `dupes: false` are behaviorally
    -- identical per the main script's `not wgt.data.dupes` check)
    reaper.ImGui_PushID(ctx, "dupes")
    rv, root_settings_state.dupes.value = reaper.ImGui_Checkbox(ctx,
      "dupes (allow duplicate values across fields)", root_settings_state.dupes.value)
    if reaper.ImGui_Button(ctx, "Save") then
      local ok, err = Editor.CommitEditRootScalar(source_path, "dupes", tostring(root_settings_state.dupes.value))
      if ok then RefreshRootSettings(source_path); reload_requests = {} else root_settings_state.error = err end
    end
    reaper.ImGui_PopID(ctx)

    if root_settings_state.error then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_TextColored(ctx, 0xFF0000FF, root_settings_state.error)
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Button(ctx, "Close") then
      reaper.ImGui_CloseCurrentPopup(ctx)
    end

    reaper.ImGui_EndPopup(ctx)
  end
  return reload_requests
end

-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~ UNDO ~~~~~~~~~~~~~~~~
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

-- Returns { restored_path = path } if a structural edit was just undone
-- this frame, else nil. The caller (SchemeVisualizer) compares
-- restored_path against the currently-loaded scheme's own path to decide
-- whether a reload is actually needed (the undo stack can span more than
-- one scheme file across a session).
function SchemeStructureEditorGui.DrawUndoButton(ctx)
  local has_undo = Editor.HasUndo()
  if not has_undo then reaper.ImGui_BeginDisabled(ctx) end
  local clicked = reaper.ImGui_Button(ctx, "Undo Last Change")
  if not has_undo then reaper.ImGui_EndDisabled(ctx) end
  Helpers.ImGui_Tooltip("Reverts the most recent field creation (or other structural edit) in this session.")

  if not clicked then return nil end
  local ok, err, path = Editor.PopUndoSnapshot()
  if not ok then
    Helpers.msg(err, "The Last Renamer")
    return nil
  end
  return { restored_path = path }
end

return SchemeStructureEditorGui
