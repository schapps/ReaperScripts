-- @description Arrange Items by Name
-- @version 0.1
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @about
--   ReaImGUI dialog that groups the selected media items by similarities in
--   their take names, previews the proposed track groups, and (on Apply)
--   creates one new track per group and moves that group's items onto it.
--   Useful for organizing large batches of imported recordings (e.g. Foley
--   surface/action variants) onto their own tracks by naming convention.
-- @changelog
--   2026-09-24 v0.1 - Testing

-- ============================================================
-- ReaImGUI dependency check + bootstrap
-- ============================================================
if not reaper.ImGui_GetBuiltinPath then
  reaper.MB("ReaImGui is required for this script.", "Missing Dependency", 0)
  return
end

package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
local ImGui = require 'imgui' '0.10'

local script_path = ({reaper.get_action_context()})[2]
local script_dir  = script_path:match("^(.*[/\\])")
local theme_path  = script_dir .. "Common/ReaImGuiTheme.lua"
if not reaper.file_exists(theme_path) then
  theme_path = script_dir .. "../Common/ReaImGuiTheme.lua"
end
local theme = dofile(theme_path)

-- ============================================================
-- Settings (persisted via ExtState)
-- ============================================================
local NS = "ArrangeItemsByName"

local function get_str(field, default)
  local v = reaper.GetExtState(NS, field)
  return v ~= "" and v or default
end
local function get_bool(field, default)
  local v = reaper.GetExtState(NS, field)
  if v == "" then return default end
  return v == "true"
end
local function get_num(field, default)
  local v = tonumber(reaper.GetExtState(NS, field))
  return v or default
end

local S = {
  grouping_mode    = get_str("GroupingMode", "prefix"),      -- "prefix" | "fuzzy"
  depth            = get_num("Depth", 2),
  threshold_pct    = get_num("ThresholdPct", 50),
  delim_space      = get_bool("DelimSpace", true),
  delim_underscore = get_bool("DelimUnderscore", true),
  delim_hyphen     = get_bool("DelimHyphen", true),
  delim_period     = get_bool("DelimPeriod", true),
  ignore_numbers   = get_bool("IgnoreNumbers", true),
  ignore_case      = get_bool("IgnoreCase", true),
  ignore_words     = get_str("IgnoreWords", "L,R,M,S,LR,MS,ST,take,tk,v"),
  placement        = get_str("Placement", "below"),          -- "below" | "end"
  sort_alpha       = get_bool("SortAlpha", false),
}

local function save_settings()
  reaper.SetExtState(NS, "GroupingMode", S.grouping_mode, true)
  reaper.SetExtState(NS, "Depth", tostring(S.depth), true)
  reaper.SetExtState(NS, "ThresholdPct", tostring(S.threshold_pct), true)
  reaper.SetExtState(NS, "DelimSpace", tostring(S.delim_space), true)
  reaper.SetExtState(NS, "DelimUnderscore", tostring(S.delim_underscore), true)
  reaper.SetExtState(NS, "DelimHyphen", tostring(S.delim_hyphen), true)
  reaper.SetExtState(NS, "DelimPeriod", tostring(S.delim_period), true)
  reaper.SetExtState(NS, "IgnoreNumbers", tostring(S.ignore_numbers), true)
  reaper.SetExtState(NS, "IgnoreCase", tostring(S.ignore_case), true)
  reaper.SetExtState(NS, "IgnoreWords", S.ignore_words, true)
  reaper.SetExtState(NS, "Placement", S.placement, true)
  reaper.SetExtState(NS, "SortAlpha", tostring(S.sort_alpha), true)
end

-- ============================================================
-- Tokenizing
-- ============================================================
local KNOWN_EXTS = {wav=true, aif=true, aiff=true, flac=true, mp3=true, ogg=true, caf=true, wv=true}

local function strip_extension(name)
  local base, ext = name:match("^(.*)%.([%a%d]+)$")
  if base and ext and KNOWN_EXTS[ext:lower()] then
    return base
  end
  return name
end

-- name -> array of {raw = "Wood", norm = "wood"}, with numeric/ignored/empty
-- tokens filtered out per the current settings.
local function tokenize(name, settings)
  local stripped = strip_extension(name)

  local chars = {}
  if settings.delim_space      then chars[#chars + 1] = " "  end
  if settings.delim_underscore then chars[#chars + 1] = "_"  end
  if settings.delim_hyphen     then chars[#chars + 1] = "%-" end
  if settings.delim_period     then chars[#chars + 1] = "%." end

  local raw_tokens = {}
  if #chars == 0 then
    raw_tokens[1] = stripped
  else
    for tok in stripped:gmatch("[^" .. table.concat(chars) .. "]+") do
      raw_tokens[#raw_tokens + 1] = tok
    end
  end

  local ignore_set = {}
  for w in settings.ignore_words:gmatch("[^,]+") do
    local trimmed = w:match("^%s*(.-)%s*$")
    if trimmed ~= "" then ignore_set[trimmed:lower()] = true end
  end

  local tokens = {}
  for _, raw in ipairs(raw_tokens) do
    if raw ~= "" then
      local lower = raw:lower()
      local is_numeric = raw:match("^%d+$") ~= nil
      if not (settings.ignore_numbers and is_numeric) and not ignore_set[lower] then
        tokens[#tokens + 1] = {raw = raw, norm = settings.ignore_case and lower or raw}
      end
    end
  end
  return tokens
end

-- ============================================================
-- Grouping algorithms
-- ============================================================

-- Groups items sharing the same first `depth` significant tokens.
-- Returns an ordered array of {key, label, items = {entry, ...}}.
local function group_by_prefix(entries, depth)
  local order, by_key = {}, {}
  for _, e in ipairs(entries) do
    local n = math.min(depth, #e.tokens)
    local key_parts, label_parts = {}, {}
    for i = 1, n do
      key_parts[#key_parts + 1] = e.tokens[i].norm
      label_parts[#label_parts + 1] = e.tokens[i].raw
    end
    local key   = n > 0 and table.concat(key_parts, "\1") or "\0__unnamed__"
    local label = n > 0 and table.concat(label_parts, " ") or "(unnamed)"

    local grp = by_key[key]
    if not grp then
      grp = {key = key, label = label, items = {}}
      by_key[key] = grp
      order[#order + 1] = grp
    end
    grp.items[#grp.items + 1] = e
  end
  return order
end

local function token_set(tokens)
  local set = {}
  for _, t in ipairs(tokens) do set[t.norm] = true end
  return set
end

local function jaccard(a, b)
  local inter, union_count = 0, 0
  local seen = {}
  for k in pairs(a) do
    seen[k] = true
    if b[k] then inter = inter + 1 end
  end
  for k in pairs(b) do seen[k] = true end
  for _ in pairs(seen) do union_count = union_count + 1 end
  if union_count == 0 then return 0 end
  return inter / union_count
end

-- Greedy single-pass clustering: each item joins the best-matching existing
-- group (by Jaccard similarity of significant token sets) if that score
-- clears `threshold`, otherwise it seeds a new group. Order-independent, so
-- it tolerates reordered tokens the prefix mode can't.
local function group_by_fuzzy(entries, threshold)
  local groups = {}
  for _, e in ipairs(entries) do
    local set = token_set(e.tokens)
    local best_grp, best_score = nil, 0
    for _, g in ipairs(groups) do
      local score = jaccard(set, g.set)
      if score > best_score then best_score, best_grp = score, g end
    end
    if best_grp and best_score >= threshold then
      best_grp.items[#best_grp.items + 1] = e
      for k in pairs(set) do best_grp.set[k] = true end
    else
      local label_parts = {}
      for _, t in ipairs(e.tokens) do label_parts[#label_parts + 1] = t.raw end
      local label = #label_parts > 0 and table.concat(label_parts, " ") or "(unnamed)"
      groups[#groups + 1] = {
        key = "fuzzy_" .. (#groups + 1) .. "_" .. label,
        label = label,
        items = {e},
        set = set,
      }
    end
  end
  return groups
end

-- ============================================================
-- Selection -> entries, with a cheap recompute-only-on-change cache
-- (mirrors Smart Export's preview_mono_sig pattern)
-- ============================================================
local function get_selected_entries(settings)
  local entries = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    local name = take and reaper.GetTakeName(take) or ""
    if name == "" then name = "(untitled item)" end
    entries[#entries + 1] = {item = item, take = take, name = name, tokens = tokenize(name, settings)}
  end
  return entries
end

local function build_signature(settings, entries)
  local parts = {
    settings.grouping_mode, settings.depth, settings.threshold_pct,
    settings.delim_space, settings.delim_underscore, settings.delim_hyphen, settings.delim_period,
    settings.ignore_numbers, settings.ignore_case, settings.ignore_words,
  }
  for _, e in ipairs(entries) do parts[#parts + 1] = tostring(e.item) end
  return table.concat(parts, "|")
end

local cached_sig    = nil
local cached_groups = {}
local track_name_overrides = {}  -- keyed by group.key, persists edits across recomputes

local function compute_groups(settings)
  local entries = get_selected_entries(settings)
  local sig = build_signature(settings, entries)
  if sig == cached_sig then return cached_groups end

  local groups = (settings.grouping_mode == "fuzzy")
    and group_by_fuzzy(entries, settings.threshold_pct / 100)
    or  group_by_prefix(entries, settings.depth)

  for _, g in ipairs(groups) do
    if track_name_overrides[g.key] == nil then
      track_name_overrides[g.key] = g.label
    end
  end

  cached_sig, cached_groups = sig, groups
  return groups
end

-- ============================================================
-- Apply: one new track per group, items moved onto it (position unchanged)
-- ============================================================
local status_msg = ""

local function apply_groups(groups)
  local total_items = 0
  for _, g in ipairs(groups) do total_items = total_items + #g.items end
  if total_items == 0 then
    status_msg = "No items selected."
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local ordered = groups
  if S.sort_alpha then
    ordered = {}
    for i, g in ipairs(groups) do ordered[i] = g end
    table.sort(ordered, function(a, b)
      local an = (track_name_overrides[a.key] or a.label):lower()
      local bn = (track_name_overrides[b.key] or b.label):lower()
      return an < bn
    end)
  end

  local insert_idx
  if S.placement == "end" then
    insert_idx = reaper.CountTracks(0)
  else
    local max_track_num = 0
    for _, g in ipairs(ordered) do
      for _, e in ipairs(g.items) do
        local track = reaper.GetMediaItem_Track(e.item)
        local num = reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")
        if num > max_track_num then max_track_num = num end
      end
    end
    insert_idx = max_track_num > 0 and math.floor(max_track_num) or reaper.CountTracks(0)
  end

  local track_count = 0
  for _, g in ipairs(ordered) do
    reaper.InsertTrackAtIndex(insert_idx, false)
    local track = reaper.GetTrack(0, insert_idx)
    local name = track_name_overrides[g.key]
    if not name or name == "" then name = g.label end
    reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
    for _, e in ipairs(g.items) do
      reaper.MoveMediaItemToTrack(e.item, track)
    end
    insert_idx = insert_idx + 1
    track_count = track_count + 1
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Arrange items by name", -1)

  status_msg = ("Arranged %d item%s onto %d track%s"):format(
    total_items, total_items == 1 and "" or "s", track_count, track_count == 1 and "" or "s")

  cached_sig = nil  -- force a fresh preview (track numbers/order just changed)
end

-- ============================================================
-- ImGui context
-- ============================================================
local script_title = "ARRANGE ITEMS BY NAME"
local ctx = ImGui.CreateContext(script_title)

local WIN_FLAGS = ImGui.WindowFlags_NoCollapse
local CHILD_BORDER = rawget(ImGui, "ChildFlags_Border") or 1

local CTL_W = 170

local function begin_field_table(id, width)
  local ok = ImGui.BeginTable(ctx, id, 2, 0, width, 0)
  if ok then
    ImGui.TableSetupColumn(ctx, "##ctl",   ImGui.TableColumnFlags_WidthFixed, CTL_W)
    ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthStretch)
  end
  return ok
end

-- ============================================================
-- Render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSizeConstraints(ctx, 460, 480, 1000, 1400)
  ImGui.SetNextWindowSize(ctx, 560, 640, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    local avail_w = select(1, ImGui.GetContentRegionAvail(ctx))

    -- ── Settings ────────────────────────────────────────────
    if begin_field_table("##settings", avail_w) then
      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local mode_label = S.grouping_mode == "fuzzy" and "Fuzzy Similarity" or "Common Prefix"
      if ImGui.BeginCombo(ctx, "##mode", mode_label, 0) then
        if ImGui.Selectable(ctx, "Common Prefix", S.grouping_mode == "prefix", 0) then
          S.grouping_mode = "prefix"; save_settings()
        end
        if ImGui.Selectable(ctx, "Fuzzy Similarity", S.grouping_mode == "fuzzy", 0) then
          S.grouping_mode = "fuzzy"; save_settings()
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Grouping Mode")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      if S.grouping_mode == "fuzzy" then
        local changed, new_pct = ImGui.SliderInt(ctx, "##threshold", S.threshold_pct, 0, 100, "%d%%")
        if changed then S.threshold_pct = new_pct; save_settings() end
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Similarity Threshold")
      else
        local changed, new_depth = ImGui.SliderInt(ctx, "##depth", S.depth, 1, 6)
        if changed then S.depth = new_depth; save_settings() end
        ImGui.TableSetColumnIndex(ctx, 1)
        ImGui.Text(ctx, "Grouping Depth")
      end

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local c1, v1 = ImGui.Checkbox(ctx, "##ignore_numbers", S.ignore_numbers)
      if c1 then S.ignore_numbers = v1; save_settings() end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Ignore Numeric Tokens")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local c2, v2 = ImGui.Checkbox(ctx, "##ignore_case", S.ignore_case)
      if c2 then S.ignore_case = v2; save_settings() end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Ignore Case")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local c3, v3 = ImGui.InputTextWithHint(ctx, "##ignore_words", "L, R, M, S, take", S.ignore_words)
      if c3 then S.ignore_words = v3; save_settings() end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Custom Ignore Words")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      ImGui.SetNextItemWidth(ctx, -1)
      local place_label = S.placement == "end" and "End of Track List" or "Below Selection"
      if ImGui.BeginCombo(ctx, "##placement", place_label, 0) then
        if ImGui.Selectable(ctx, "Below Selection", S.placement == "below", 0) then
          S.placement = "below"; save_settings()
        end
        if ImGui.Selectable(ctx, "End of Track List", S.placement == "end", 0) then
          S.placement = "end"; save_settings()
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Track Placement")

      ImGui.TableNextRow(ctx)
      ImGui.TableSetColumnIndex(ctx, 0)
      local c4, v4 = ImGui.Checkbox(ctx, "##sort_alpha", S.sort_alpha)
      if c4 then S.sort_alpha = v4; save_settings() end
      ImGui.TableSetColumnIndex(ctx, 1)
      ImGui.Text(ctx, "Sort New Tracks Alphabetically")

      ImGui.EndTable(ctx)
    end

    ImGui.Spacing(ctx)

    -- ── Delimiters ──────────────────────────────────────────
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, "Split On")
    ImGui.PopStyleColor(ctx)
    ImGui.SameLine(ctx)
    local d1, dv1 = ImGui.Checkbox(ctx, "Space", S.delim_space)
    if d1 then S.delim_space = dv1; save_settings() end
    ImGui.SameLine(ctx)
    local d2, dv2 = ImGui.Checkbox(ctx, "_", S.delim_underscore)
    if d2 then S.delim_underscore = dv2; save_settings() end
    ImGui.SameLine(ctx)
    local d3, dv3 = ImGui.Checkbox(ctx, "-", S.delim_hyphen)
    if d3 then S.delim_hyphen = dv3; save_settings() end
    ImGui.SameLine(ctx)
    local d4, dv4 = ImGui.Checkbox(ctx, ".", S.delim_period)
    if d4 then S.delim_period = dv4; save_settings() end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- ── Preview ─────────────────────────────────────────────
    local groups = compute_groups(S)
    local total_items = 0
    for _, g in ipairs(groups) do total_items = total_items + #g.items end

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
    ImGui.Text(ctx, ("%d item%s selected \u{2192} %d group%s"):format(
      total_items, total_items == 1 and "" or "s", #groups, #groups == 1 and "" or "s"))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    local footer_h = theme.PrimaryButtonHeight(ctx) + 40
    local _, region_h = ImGui.GetContentRegionAvail(ctx)
    local child_h = math.max(80, region_h - footer_h)

    if ImGui.BeginChild(ctx, "##preview", avail_w, child_h, CHILD_BORDER) then
      for i, g in ipairs(groups) do
        ImGui.PushID(ctx, i)

        local expanded = ImGui.CollapsingHeader(ctx, "##hdr", nil, ImGui.TreeNodeFlags_DefaultOpen)
        ImGui.SameLine(ctx)
        theme.Chip(ctx, tostring(#g.items), 0xA0A0A0FF, 0x3A3F45FF)
        ImGui.SameLine(ctx)
        ImGui.SetNextItemWidth(ctx, -1)
        local name_changed, new_name = ImGui.InputText(ctx, "##name", track_name_overrides[g.key] or g.label)
        if name_changed then track_name_overrides[g.key] = new_name end

        if expanded then
          ImGui.Indent(ctx, 12)
          for _, e in ipairs(g.items) do
            ImGui.Text(ctx, e.name)
          end
          ImGui.Unindent(ctx, 12)
          ImGui.Spacing(ctx)
        end

        ImGui.PopID(ctx)
      end
      ImGui.EndChild(ctx)
    end

    ImGui.Spacing(ctx)

    -- ── Apply ───────────────────────────────────────────────
    local disabled = total_items == 0
    if disabled then ImGui.BeginDisabled(ctx, true) end
    local clicked = theme.PrimaryButton(ctx, "Apply", -1, 0, nil, theme.Icons.TRACKS)
    if disabled then ImGui.EndDisabled(ctx) end
    if clicked then
      apply_groups(groups)
    end

    if status_msg ~= "" then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, 0xA0A0A0FF)
      ImGui.Text(ctx, status_msg)
      ImGui.PopStyleColor(ctx)
    end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if still_open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
