-- @noindex
-- SchemeVisualizer: read-only node-graph visualization of a scheme's field
-- tree, in its own ReaImGui window (same ctx as the main script - see
-- SchemeVisualizer.DrawWindow's caller in the main script's Main()).
--
-- Each YAML field becomes one node; an edge connects a parent field to each
-- child in field.fields, labeled with that child's `id` condition - this
-- mirrors PassesIDCheck's branching logic (when does this child appear),
-- but walks the WHOLE tree unconditionally, not just the currently-reachable
-- path, since the point is to see the scheme's full shape at a glance.
--
-- Phase 1 (this file): visualization. Structural editing (creating new
-- fields) is layered in via SchemeStructureEditorGui, injected alongside
-- `acendan` since dofile'd chunks don't share the main script's `local`
-- variables.

local SchemeVisualizer = {}

local Helpers, StructureGui

function SchemeVisualizer.init(helpers, structure_gui)
  Helpers = helpers
  StructureGui = structure_gui
end

local COLUMN_WIDTH = 220
local ROW_HEIGHT   = 60
local NODE_WIDTH    = 180
local NODE_HEIGHT   = 40

local function FormatIdLabel(id)
  if id == nil then return "always" end
  if type(id) == "table" then
    local parts = {}
    for _, v in ipairs(id) do parts[#parts + 1] = tostring(v) end
    return table.concat(parts, ", ")
  end
  return tostring(id)
end

local function TypeSummary(field)
  if type(field.value) == "table" then
    return "dropdown (" .. #field.value .. " option" .. (#field.value == 1 and "" or "s") .. ")"
  elseif type(field.value) == "boolean" then
    return "checkbox"
  elseif type(field.value) == "number" then
    return "number"
  else
    return "text"
  end
end

-- Depth-first layout: column = nesting depth, row = document order. This is
-- a naive pre-order stack, not a balanced tree layout (a field with many
-- children pushes every later sibling further down) - adequate for reading
-- the scheme's shape in v1; worth revisiting once seen against a scheme as
-- wide as UCS.yaml's 80-branch Category field.
local function ComputeLayout(fields)
  local nodes, edges = {}, {}
  local next_id = 1
  local y_cursor = { 0 }

  local function walk(list, depth, parent_node)
    for _, field in ipairs(list) do
      local node = {
        id           = next_id,
        field        = field,
        parent_field = parent_node and parent_node.field or nil,
        x            = depth * COLUMN_WIDTH,
        y            = y_cursor[1],
      }
      next_id = next_id + 1
      y_cursor[1] = y_cursor[1] + ROW_HEIGHT
      nodes[#nodes + 1] = node
      if parent_node then
        edges[#edges + 1] = { from = parent_node, to = node, label = FormatIdLabel(field.id) }
      end
      if field.fields then
        walk(field.fields, depth + 1, node)
      end
    end
  end

  walk(fields, 0, nil)
  return nodes, edges
end

-- Module-local UI state: there is only ever one Visual Editor window open
-- per script session, so this doesn't need to be duplicated per-instance.
local state = {
  pan_x = 40, pan_y = 20,
  selected_node = nil,
  layout_key = nil, -- identifies which loaded scheme's layout is cached below
  nodes = nil, edges = nil,
}

-- Recomputes the layout only when the loaded scheme document actually
-- changes (e.g. after switching schemes or a forced reload) - `data` is the
-- same wgt.data/wgt.meta table reused every frame otherwise, so this is a
-- cheap identity check, not a deep comparison.
local function EnsureLayout(data)
  if state.layout_key ~= data then
    state.nodes, state.edges = ComputeLayout(data.fields)
    state.layout_key = data
    state.selected_node = nil
  end
end

local function DrawCanvas(ctx, w, h, data, source_path)
  reaper.ImGui_BeginChild(ctx, "canvas", w, h, reaper.ImGui_ChildFlags_Borders())

  local origin_x, origin_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)

  -- Whole-scheme context menu (right-click empty canvas background) can be
  -- called here - BeginPopupContextWindow's NoOpenOverItems flag means it
  -- only fires for empty-space clicks regardless of call order relative to
  -- the nodes drawn below. DrawCreatePopup itself, though, is deferred
  -- until after the node loop, so that a "Add Child Field..." click from a
  -- node's OWN context menu (which can only be drawn after we know the
  -- node's screen position) still gets its ImGui_OpenPopup call processed
  -- this same frame, not one frame late.
  StructureGui.DrawCanvasContextMenu(ctx)

  local function to_screen(x, y)
    return origin_x + state.pan_x + x, origin_y + state.pan_y + y
  end

  -- Two passes: ALL curves first, then ALL labels (with an opaque backdrop
  -- rect sized to the actual text). Drawing curve+label per-edge in a single
  -- pass left each label sitting under *later* edges' curves, since ReaImGui
  -- paints strictly in call order - splitting into passes guarantees every
  -- label is on top of every line, not just the one it belongs to.
  local edge_screen_points = {}
  for i, edge in ipairs(state.edges) do
    local x1, y1 = to_screen(edge.from.x + NODE_WIDTH, edge.from.y + NODE_HEIGHT / 2)
    local x2, y2 = to_screen(edge.to.x, edge.to.y + NODE_HEIGHT / 2)
    edge_screen_points[i] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    local mid = (x2 - x1) * 0.5
    reaper.ImGui_DrawList_AddBezierCubic(draw_list, x1, y1, x1 + mid, y1, x2 - mid, y2, x2, y2,
      0xAAAAAAFF, 1.5, 0)
  end
  for i, edge in ipairs(state.edges) do
    local pts = edge_screen_points[i]
    local label_w, label_h = reaper.ImGui_CalcTextSize(ctx, edge.label)
    local label_x = (pts.x1 + pts.x2) / 2 - label_w / 2
    local label_y = (pts.y1 + pts.y2) / 2 - label_h / 2
    reaper.ImGui_DrawList_AddRectFilled(draw_list, label_x - 4, label_y - 2,
      label_x + label_w + 4, label_y + label_h + 2, 0x1E1E1EFF, 3)
    reaper.ImGui_DrawList_AddText(draw_list, label_x, label_y, 0xE0E0E0FF, edge.label)
  end

  local reload_requests_from_nodes = nil
  for _, node in ipairs(state.nodes) do
    local x1, y1 = to_screen(node.x, node.y)
    local x2, y2 = x1 + NODE_WIDTH, y1 + NODE_HEIGHT
    local is_selected = state.selected_node == node
    local is_wildcard = node.field.__wildcard_key ~= nil
    local fill = is_selected and 0x3D6EBFFF or 0x3A3A3EFF
    reaper.ImGui_DrawList_AddRectFilled(draw_list, x1, y1, x2, y2, fill, 4)
    -- Wildcard-backed fields (a shared $name list, edited from more than one
    -- place - see SchemeEditorGui's "Shared list" warning) get a distinct
    -- amber outline instead of the plain gray border, so their wider blast
    -- radius is visible at a glance in the graph, not just in the edit popup.
    if is_wildcard then
      reaper.ImGui_DrawList_AddRect(draw_list, x1, y1, x2, y2, 0xFFAA00FF, 4, 0, 2)
    else
      reaper.ImGui_DrawList_AddRect(draw_list, x1, y1, x2, y2, 0x808080FF, 4, 0, 1)
    end
    reaper.ImGui_DrawList_AddText(draw_list, x1 + 8, y1 + 6, 0xFFFFFFFF, tostring(node.field.field))
    reaper.ImGui_DrawList_AddText(draw_list, x1 + 8, y1 + 22, 0xAAAAAAFF, TypeSummary(node.field))
    if is_wildcard then
      reaper.ImGui_DrawList_AddText(draw_list, x2 - 20, y1 + 6, 0xFFAA00FF, "$")
    end

    reaper.ImGui_SetCursorScreenPos(ctx, x1, y1)
    if reaper.ImGui_InvisibleButton(ctx, "node_" .. node.id, NODE_WIDTH, NODE_HEIGHT) then
      state.selected_node = node
    end

    -- Drag-to-reparent: BeginDragDropSource only returns true once an
    -- actual drag is underway (a plain click never triggers it), so this
    -- coexists cleanly with the InvisibleButton's click-to-select above and
    -- the canvas's own pan-on-drag below (already guarded by
    -- IsAnyItemActive, which is true while this button is held for a drag).
    -- The payload is just the dragged node's id (a string) - source and
    -- target both run in this same script/session, so the target side can
    -- look the real field up directly via state.nodes instead of needing to
    -- serialize anything through the payload itself.
    if reaper.ImGui_BeginDragDropSource(ctx) then
      reaper.ImGui_SetDragDropPayload(ctx, "STRUCT_FIELD_NODE", tostring(node.id))
      reaper.ImGui_Text(ctx, "Move \"" .. node.field.field .. "\"")
      reaper.ImGui_EndDragDropSource(ctx)
    end
    if reaper.ImGui_BeginDragDropTarget(ctx) then
      local rv, payload = reaper.ImGui_AcceptDragDropPayload(ctx, "STRUCT_FIELD_NODE")
      if rv then
        local dragged = state.nodes[tonumber(payload)]
        if dragged then
          -- A node can't simultaneously be "a current sibling" and "a
          -- different parent" of the dragged field, so this fully
          -- disambiguates every drop: dropping onto a SIBLING (same
          -- parent - both nil for top-level) reorders it to sit right
          -- after the dropped-on node, immediately. Otherwise, whether the
          -- dropped-on node can even ACCEPT children decides which
          -- reparent flavor applies: a valid container -> become its
          -- child (existing popup); anything else (text/number) -> become
          -- ITS sibling instead, positioned right after it, rather than
          -- refusing outright.
          if dragged.parent_field == node.parent_field then
            local siblings = dragged.parent_field and dragged.parent_field.fields or data.fields
            local ok, err, reqs = StructureGui.CommitReorderForDrop(source_path, siblings, dragged.field, node.field)
            if ok then reload_requests_from_nodes = reqs else Helpers.msg(err, "The Last Renamer") end
          else
            local is_container = type(node.field.value) == "table" or type(node.field.value) == "boolean"
            local drop_err
            if is_container then
              drop_err = StructureGui.OpenMoveToPopupForDrop(dragged.field, dragged.parent_field, data.fields, node.field)
            else
              drop_err = StructureGui.OpenMoveToPopupForSiblingDrop(dragged.field, dragged.parent_field, data.fields, node.field, node.parent_field)
            end
            if drop_err then Helpers.msg(drop_err, "The Last Renamer") end
          end
        end
      end
      reaper.ImGui_EndDragDropTarget(ctx)
    end

    local move_reload_requests = StructureGui.DrawNodeContextMenu(ctx, node.field, node.id, node.parent_field, data.fields, source_path)
    if move_reload_requests then reload_requests_from_nodes = move_reload_requests end
  end

  -- Drop on EMPTY canvas background -> move to top-level. Deliberately not
  -- a BeginDragDropTarget/AcceptDragDropPayload pair on the child window
  -- itself: registering that right after BeginChild (needed for it to bind
  -- to the whole window's rect rather than "whatever was last submitted")
  -- would run BEFORE the node loop even draws anything, so it can't know
  -- whether the cursor will end up over a node's smaller rect later in the
  -- same frame - both could then independently report "hovered" and
  -- "accept" the same drop. Instead, GetDragDropPayload just PEEKS at
  -- whatever payload is currently active (no rect of its own), so checking
  -- it AFTER the node loop - gated on "this window is hovered AND no item
  -- (i.e. no node) is" - correctly only fires when the drop truly lands on
  -- empty space, since by this point every node's own hover state for this
  -- frame has already been resolved.
  if reaper.ImGui_IsWindowHovered(ctx) and not reaper.ImGui_IsAnyItemHovered(ctx) then
    local has_payload, payload_type, payload, is_preview, is_delivery = reaper.ImGui_GetDragDropPayload(ctx)
    if has_payload and payload_type == "STRUCT_FIELD_NODE" and is_delivery then
      local dragged = state.nodes[tonumber(payload)]
      if dragged then
        local drop_err = StructureGui.OpenMoveToPopupForDrop(dragged.field, dragged.parent_field, data.fields, nil)
        if drop_err then Helpers.msg(drop_err, "The Last Renamer") end
      end
    end
  end

  local reload_requests = StructureGui.DrawCreatePopup(ctx, source_path, data.fields)
  if reload_requests_from_nodes then reload_requests = reload_requests_from_nodes end
  local delete_reload_requests = StructureGui.DrawDeleteConfirmPopup(ctx, source_path)
  if delete_reload_requests then reload_requests = delete_reload_requests end
  local extract_reload_requests = StructureGui.DrawExtractToWildcardPopup(ctx, source_path)
  if extract_reload_requests then reload_requests = extract_reload_requests end
  local link_reload_requests = StructureGui.DrawLinkToWildcardPopup(ctx, source_path)
  if link_reload_requests then reload_requests = link_reload_requests end
  local move_to_reload_requests = StructureGui.DrawMoveToPopup(ctx, source_path, data.fields)
  if move_to_reload_requests then reload_requests = move_to_reload_requests end

  -- Pan: drag anywhere on the canvas that isn't currently holding a node's
  -- InvisibleButton (mouse button 0 = left).
  if reaper.ImGui_IsWindowHovered(ctx) and not reaper.ImGui_IsAnyItemActive(ctx) and
      reaper.ImGui_IsMouseDragging(ctx, 0) then
    local dx, dy = reaper.ImGui_GetMouseDragDelta(ctx, 0)
    state.pan_x = state.pan_x + dx
    state.pan_y = state.pan_y + dy
    reaper.ImGui_ResetMouseDragDelta(ctx, 0)
  end

  reaper.ImGui_EndChild(ctx)
  return reload_requests
end

local function DrawInspector(ctx, w, h)
  reaper.ImGui_BeginChild(ctx, "inspector", w, h, reaper.ImGui_ChildFlags_Borders())
  local node = state.selected_node
  if not node then
    reaper.ImGui_TextDisabled(ctx, "Click a node to inspect it.")
  else
    local field = node.field
    reaper.ImGui_Text(ctx, field.field)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Type: " .. TypeSummary(field))
    if field.__wildcard_key then
      reaper.ImGui_TextColored(ctx, 0xFFAA00FF, "Shared list ($" .. field.__wildcard_key .. ")")
      reaper.ImGui_TextWrapped(ctx, "Editing this list affects every field using $" .. field.__wildcard_key .. ".")
    end
    if field.help then
      reaper.ImGui_TextWrapped(ctx, "Help: " .. field.help)
    end
    if field.required then
      reaper.ImGui_TextColored(ctx, 0xFF8080FF, "Required")
    end
    if type(field.value) == "table" then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Text(ctx, "Values:")
      for i, v in ipairs(field.value) do
        local short = field.short and field.short[i]
        reaper.ImGui_BulletText(ctx, tostring(v) .. (short and ("  (" .. short .. ")") or ""))
      end
    end
    if field.id ~= nil then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Text(ctx, "Visible when parent = " .. FormatIdLabel(field.id))
    end
  end
  reaper.ImGui_EndChild(ctx)
end

-- Renders the "Scheme Visual Editor" window for the currently loaded scheme
-- document `data` (always wgt.data - the Visual Editor only ever shows the
-- Naming scheme, never Metadata). Returns open, reload: `open` is false
-- once the user closes the window (the caller should clear its own
-- show-flag and stop calling DrawWindow until it's reopened); `reload`,
-- when non-nil, is a { is_meta, requests } table ready to be assigned
-- directly to wgt.__pending_reload - is_meta is always false here, since
-- this window never touches wgt.meta.
function SchemeVisualizer.DrawWindow(ctx, data)
  if not data or not data.fields then return true, nil end
  EnsureLayout(data)

  -- Same theme (purple title bar, rounded corners, etc.) as the main
  -- window, via the shared style table injected as Helpers.
  Helpers.ImGui_PushStyles()

  reaper.ImGui_SetNextWindowSize(ctx, 900, 600, reaper.ImGui_Cond_FirstUseEver())
  local rv, open = reaper.ImGui_Begin(ctx, "Scheme Visual Editor - " .. (data.title or ""), true)
  local reload = nil
  if rv then
    local source_path = data.__scheme_path

    -- The undo stack can span more than one scheme file across a session -
    -- only actually trigger a reload if the entry just restored belongs to
    -- the scheme currently open in this window.
    local undo_result = StructureGui.DrawUndoButton(ctx)
    if undo_result and undo_result.restored_path == source_path then
      reload = { is_meta = false, requests = {} }
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Manage Wildcards...") then
      StructureGui.OpenWildcardsPopup()
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Root Settings...") then
      StructureGui.OpenRootSettingsPopup()
    end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextDisabled(ctx, "Right-click the canvas or a node to add fields.")

    local wildcards_reload_requests = StructureGui.DrawWildcardsPopup(ctx, source_path)
    if wildcards_reload_requests then
      reload = { is_meta = false, requests = wildcards_reload_requests }
    end

    local root_settings_reload_requests = StructureGui.DrawRootSettingsPopup(ctx, source_path)
    if root_settings_reload_requests then
      reload = { is_meta = false, requests = root_settings_reload_requests }
    end

    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local inspector_w = 260
    local reload_requests = DrawCanvas(ctx, avail_w - inspector_w - 8, 0, data, source_path)
    if reload_requests then
      reload = { is_meta = false, requests = reload_requests }
    end
    reaper.ImGui_SameLine(ctx)
    DrawInspector(ctx, inspector_w, 0)
    reaper.ImGui_End(ctx)
  end

  Helpers.ImGui_PopStyles()
  return open, reload
end

return SchemeVisualizer
