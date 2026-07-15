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
-- Phase 1 (this file): visualization only - no dragging, no persisted
-- layout, no writing back to the scheme file. Depends only on `acendan`
-- (for ImGui_Tooltip, etc.), injected via init() like every other Lib module
-- here, since dofile'd chunks don't share the main script's `local` variables.

local SchemeVisualizer = {}

local Helpers

function SchemeVisualizer.init(helpers)
  Helpers = helpers
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
        id    = next_id,
        field = field,
        x     = depth * COLUMN_WIDTH,
        y     = y_cursor[1],
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

local function DrawCanvas(ctx, w, h)
  reaper.ImGui_BeginChild(ctx, "canvas", w, h, reaper.ImGui_ChildFlags_Borders())

  local origin_x, origin_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local draw_list = reaper.ImGui_GetWindowDrawList(ctx)

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
  end

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
-- document `data` (wgt.data or wgt.meta). Returns false once the user
-- closes it - the caller should clear its own show-flag when this returns
-- false, and stop calling DrawWindow until it's reopened.
function SchemeVisualizer.DrawWindow(ctx, data)
  if not data or not data.fields then return true end
  EnsureLayout(data)

  -- Same theme (purple title bar, rounded corners, etc.) as the main
  -- window, via the shared style table injected as Helpers.
  Helpers.ImGui_PushStyles()

  reaper.ImGui_SetNextWindowSize(ctx, 900, 600, reaper.ImGui_Cond_FirstUseEver())
  local rv, open = reaper.ImGui_Begin(ctx, "Scheme Visual Editor - " .. (data.title or ""), true)
  if rv then
    local avail_w, avail_h = reaper.ImGui_GetContentRegionAvail(ctx)
    local inspector_w = 260
    DrawCanvas(ctx, avail_w - inspector_w - 8, 0)
    reaper.ImGui_SameLine(ctx)
    DrawInspector(ctx, inspector_w, 0)
    reaper.ImGui_End(ctx)
  end

  Helpers.ImGui_PopStyles()
  return open
end

return SchemeVisualizer
