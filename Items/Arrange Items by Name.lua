-- @description Arrange Items by Name
-- @version 0.3
-- @author Stephen Schappler
-- @link https://www.stephenschappler.com
-- @about
--   ReaImGUI dialog that groups the selected media items by similarities in
--   their take names, previews the proposed track groups, and (on Apply)
--   creates one new track per group and moves that group's items onto it.
--   Useful for organizing large batches of imported recordings (e.g. Foley
--   surface/action variants) onto their own tracks by naming convention.
-- @changelog
--   2026-09-24 v0.3 - More features

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
  -- Migrated from the older SortAlpha boolean, so an existing install keeps
  -- whatever it was set to.
  track_order      = (function()
    local v = reaper.GetExtState(NS, "TrackOrder")
    if v ~= "" then return v end
    return get_bool("SortAlpha", false) and "alpha" or "grouped"
  end)(),                                                  -- "grouped" | "alpha" | "priority"
  track_priority   = get_str("TrackPriority", ""),
  cascade_on       = get_bool("CascadeOn", false),
  cascade_gap      = get_num("CascadeGap", 1.0),
  sort_items_on    = get_bool("SortItemsOn", false),
  sort_order       = get_str("SortOrder", ""),
  sort_layout      = get_str("SortLayout", "slots"),       -- "slots" | "repack"
  repack_gap       = get_num("RepackGap", 0.5),
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
  reaper.SetExtState(NS, "TrackOrder", S.track_order, true)
  reaper.SetExtState(NS, "TrackPriority", S.track_priority, true)
  reaper.SetExtState(NS, "CascadeOn", tostring(S.cascade_on), true)
  reaper.SetExtState(NS, "CascadeGap", tostring(S.cascade_gap), true)
  reaper.SetExtState(NS, "SortItemsOn", tostring(S.sort_items_on), true)
  reaper.SetExtState(NS, "SortOrder", S.sort_order, true)
  reaper.SetExtState(NS, "SortLayout", S.sort_layout, true)
  reaper.SetExtState(NS, "RepackGap", tostring(S.repack_gap), true)
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
-- Per-track item sorting
--
-- Two-level key: the rank of the first priority word the name matches,
-- then a natural (digit-aware) comparison of the whole name, so Light_02
-- lands before Light_10 rather than after it.
-- ============================================================

-- "light, normal, heavy" -> {"light", "normal", "heavy"}. Blank entries are
-- dropped so a trailing comma doesn't create a rank that matches everything.
local function parse_sort_order(spec)
  local words = {}
  for w in (spec or ""):gmatch("[^,]+") do
    w = w:match("^%s*(.-)%s*$"):lower()
    if w ~= "" then words[#words + 1] = w end
  end
  return words
end

-- Levels are separated by ";" (or "|"), words within a level by ",". So
-- "light, normal, heavy; slow, fast" is two ordered sets applied as
-- successive sort keys: intensity first, speed to break its ties. Empty
-- levels are dropped, so a trailing ";" is harmless.
local function parse_priority_levels(spec)
  local levels = {}
  for chunk in (spec or ""):gmatch("[^;|]+") do
    local words = parse_sort_order(chunk)
    if #words > 0 then levels[#levels + 1] = words end
  end
  return levels
end

-- Returns two things about a name: its rank -- the index of the earliest
-- listed word it contains, or one past the end when it matches none -- and
-- its "family", the lowercased name with that word removed. Track ordering
-- sorts on the family first so Roll/Settle/Bounce stay contiguous; item
-- ordering ignores it and uses the rank alone.
--
-- The %f frontiers pin the match to word boundaries, so "light" doesn't hit
-- "lightning". A frontier only acts as a boundary next to an alphanumeric,
-- so a word like "+3dB" gets one on its trailing side only.
local function rank_and_family(name, words)
  local lower = name:lower()
  for i, w in ipairs(words) do
    local body = w:gsub("%W", "%%%0")
    local head = w:match("^%w") and "%f[%w]" or ""
    local tail = w:match("%w$") and "%f[%W]" or ""
    local from, to = lower:find(head .. body .. tail)
    if from then
      -- Whitespace is collapsed so "roll  light" minus "light" compares
      -- equal to a plain "roll".
      local family = (lower:sub(1, from - 1) .. lower:sub(to + 1))
        :gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
      return i, family
    end
  end
  return #words + 1, lower
end

-- One rank per level, plus the family left after every matched word has
-- been stripped. Stripping is progressive: level 2 matches against what
-- level 1 left behind, so "Roll Heavy Slow" yields ranks {heavy, slow} and
-- the family "bendmetalsolid roll".
local function ranks_and_family(name, levels)
  local ranks, family = {}, name:lower()
  for i, words in ipairs(levels) do
    ranks[i], family = rank_and_family(family, words)
  end
  return ranks, family
end

-- Lexicographic over the rank vectors. A missing level counts as 0 so a
-- shorter vector sorts first, though in practice both sides come from the
-- same level list and are the same length.
local function compare_ranks(a, b)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i] or 0, b[i] or 0
    if x ~= y then return x < y and -1 or 1 end
  end
  return 0
end

-- Compares digit runs numerically and everything else as text, so the
-- ordering matches how the names read rather than raw byte order.
local function natural_less(a, b)
  local ai, bi = 1, 1
  while true do
    local a_chunk, a_num = a:match("^(%d+)", ai), true
    if not a_chunk then a_chunk, a_num = a:match("^(%D+)", ai), false end
    local b_chunk, b_num = b:match("^(%d+)", bi), true
    if not b_chunk then b_chunk, b_num = b:match("^(%D+)", bi), false end

    if not a_chunk or not b_chunk then return (a_chunk and 1 or 0) < (b_chunk and 1 or 0) end

    if a_num and b_num then
      local an, bn = tonumber(a_chunk), tonumber(b_chunk)
      -- Equal values with different widths ("01" vs "1") fall through to the
      -- literal comparison below, keeping the order deterministic.
      if an ~= bn then return an < bn end
      if a_chunk ~= b_chunk then return a_chunk < b_chunk end
    else
      local al, bl = a_chunk:lower(), b_chunk:lower()
      if al ~= bl then return al < bl end
      if a_chunk ~= b_chunk then return a_chunk < b_chunk end
    end

    ai = ai + #a_chunk
    bi = bi + #b_chunk
  end
end

-- Shared by both sort paths. Entries must already carry a .ranks vector;
-- computing it here would redo the pattern matching O(n log n) times.
local function entry_less(a, b)
  local c = compare_ranks(a.ranks, b.ranks)
  if c ~= 0 then return c < 0 end
  if a.name ~= b.name then return natural_less(a.name, b.name) end
  return a.ord < b.ord  -- selection order: keeps identically-named items stable
end

-- Deals an already-sorted list into the timeline slots those same items
-- occupy right now: collect the positions, sort them ascending, hand them
-- back out in list order. Footprint and gaps survive; only which item sits
-- in which slot changes. Returns how many items actually moved.
local function reseat_items(list)
  if #list < 2 then return 0 end
  local slots = {}
  for _, e in ipairs(list) do
    slots[#slots + 1] = reaper.GetMediaItemInfo_Value(e.item, "D_POSITION")
  end
  table.sort(slots)
  local moved = 0
  for i, e in ipairs(list) do
    if reaper.GetMediaItemInfo_Value(e.item, "D_POSITION") ~= slots[i] then
      moved = moved + 1
    end
    reaper.SetMediaItemInfo_Value(e.item, "D_POSITION", slots[i])
  end
  return moved
end

-- Lays an already-sorted list out end to end, starting at the earliest
-- position the list currently occupies, each item following the previous by
-- its own length plus `gap`. Unlike slot reuse this can never overlap --
-- spacing comes from the items' real lengths rather than from whatever the
-- old layout happened to leave -- but it does rewrite the group's internal
-- timing. Returns how many items actually moved.
local function repack_items(list, gap)
  if #list == 0 then return 0 end

  local start = math.huge
  for _, e in ipairs(list) do
    local p = reaper.GetMediaItemInfo_Value(e.item, "D_POSITION")
    if p < start then start = p end
  end

  local cursor, moved = start, 0
  for _, e in ipairs(list) do
    if reaper.GetMediaItemInfo_Value(e.item, "D_POSITION") ~= cursor then
      moved = moved + 1
    end
    reaper.SetMediaItemInfo_Value(e.item, "D_POSITION", cursor)
    cursor = cursor + reaper.GetMediaItemInfo_Value(e.item, "D_LENGTH") + gap
  end
  return moved
end

-- Sequences whole blocks along the timeline in track order, so the first
-- track's material plays first and the arrangement staircases down and to
-- the right. Each group is shifted by a single delta, so whatever spacing
-- the items have inside their own track survives untouched -- this runs
-- after the per-track layout and only decides where each block starts.
-- Anchored at the earliest position anything currently occupies, so the
-- material stays where it already lives on the timeline.
local function cascade_groups(ordered, gap)
  local start = math.huge
  for _, g in ipairs(ordered) do
    for _, e in ipairs(g.items) do
      local p = reaper.GetMediaItemInfo_Value(e.item, "D_POSITION")
      if p < start then start = p end
    end
  end
  if start == math.huge then return 0 end

  local cursor, moved = start, 0
  for _, g in ipairs(ordered) do
    if #g.items > 0 then
      local b_start, b_end = math.huge, -math.huge
      for _, e in ipairs(g.items) do
        local p = reaper.GetMediaItemInfo_Value(e.item, "D_POSITION")
        local l = reaper.GetMediaItemInfo_Value(e.item, "D_LENGTH")
        if p < b_start then b_start = p end
        if p + l > b_end then b_end = p + l end
      end

      local delta = cursor - b_start
      if delta ~= 0 then
        for _, e in ipairs(g.items) do
          local p = reaper.GetMediaItemInfo_Value(e.item, "D_POSITION")
          reaper.SetMediaItemInfo_Value(e.item, "D_POSITION", p + delta)
          moved = moved + 1
        end
      end
      cursor = cursor + (b_end - b_start) + gap
    end
  end
  return moved
end

-- Picks the layout the settings ask for. Both take an already-sorted list.
local function layout_items(list, settings)
  if settings.sort_layout == "repack" then
    return repack_items(list, settings.repack_gap)
  end
  return reseat_items(list)
end

-- Sorts each group's items in place.
local function sort_group_items(groups, settings)
  local levels = parse_priority_levels(settings.sort_order)
  for _, g in ipairs(groups) do
    for _, e in ipairs(g.items) do e.ranks = ranks_and_family(e.name, levels) end
    table.sort(g.items, entry_less)
  end
end

-- Buckets entries by the track they already live on. Used when Placement is
-- "keep": there is no grouping to do, each track just sorts its own items.
local function group_by_track(entries)
  local groups, by_track = {}, {}
  for _, e in ipairs(entries) do
    local track = reaper.GetMediaItem_Track(e.item)
    local guid  = reaper.GetTrackGUID(track)
    local g = by_track[guid]
    if not g then
      local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
      if name == "" then
        name = ("Track %d"):format(math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")))
      end
      g = {key = "track_" .. guid, label = name, items = {}, track = track}
      by_track[guid] = g
      groups[#groups + 1] = g
    end
    g.items[#g.items + 1] = e
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
    entries[#entries + 1] = {
      item = item, take = take, name = name,
      tokens = tokenize(name, settings),
      ord = i + 1,  -- selection order, used as the final sort tiebreak
    }
  end
  return entries
end

local function build_signature(settings, entries)
  local parts = {}
  local function add(v) parts[#parts + 1] = tostring(v) end
  add(settings.grouping_mode) add(settings.depth) add(settings.threshold_pct)
  add(settings.delim_space) add(settings.delim_underscore)
  add(settings.delim_hyphen) add(settings.delim_period)
  add(settings.ignore_numbers) add(settings.ignore_case) add(settings.ignore_words)
  add(settings.sort_items_on) add(settings.sort_order) add(settings.placement)
  for _, e in ipairs(entries) do add(e.item) end
  return table.concat(parts, "|")
end

local cached_sig    = nil
local cached_groups = {}
local track_name_overrides = {}  -- keyed by group.key, persists edits across recomputes

local function compute_groups(settings)
  local entries = get_selected_entries(settings)
  local sig = build_signature(settings, entries)
  if sig == cached_sig then return cached_groups end

  local groups
  if settings.placement == "keep" then
    groups = group_by_track(entries)
  elseif settings.grouping_mode == "fuzzy" then
    groups = group_by_fuzzy(entries, settings.threshold_pct / 100)
  else
    groups = group_by_prefix(entries, settings.depth)
  end

  -- Sorted here rather than at draw time so the preview lists items in the
  -- exact order Apply will lay them out. Sorting is the whole point of the
  -- keep mode, so it is implied there.
  if settings.sort_items_on or settings.placement == "keep" then
    sort_group_items(groups, settings)
  end

  for _, g in ipairs(groups) do
    if track_name_overrides[g.key] == nil then
      track_name_overrides[g.key] = g.label
    end
  end

  cached_sig, cached_groups = sig, groups
  return groups
end

-- Orders the groups, which becomes the order their tracks are created in.
-- Reuses the item comparator: ranks all equal collapses it to natural
-- order, which is what "Alphabetical" wants anyway (_02 before _10).
local function order_groups(groups, settings)
  if settings.track_order ~= "alpha" and settings.track_order ~= "priority" then
    return groups
  end

  local levels = settings.track_order == "priority"
    and parse_priority_levels(settings.track_priority) or {}

  local by_priority = settings.track_order == "priority"

  local list = {}
  for i, g in ipairs(groups) do
    -- The effective name, so a track renamed in the preview sorts where its
    -- new name puts it rather than where the computed label did.
    local name = track_name_overrides[g.key] or g.label
    local ranks, family = {}, name:lower()
    if by_priority then ranks, family = ranks_and_family(name, levels) end
    list[i] = {group = g, name = name, ord = i, ranks = ranks, family = family}
  end

  -- Family before ranks: this is what keeps a family together and orders
  -- light/normal/heavy inside it, rather than pulling every Light track to
  -- the top. In "alpha" mode the rank vectors are empty and the family is
  -- the whole name, so this collapses to a natural alphabetical sort.
  table.sort(list, function(a, b)
    if a.family ~= b.family then return natural_less(a.family, b.family) end
    return entry_less(a, b)
  end)

  local ordered = {}
  for i, r in ipairs(list) do ordered[i] = r.group end
  return ordered
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

  -- Keep mode: no tracks created, no items moved between tracks. Each
  -- track's items are dealt back into the slots they already occupy, in
  -- sort order.
  if S.placement == "keep" then
    local moved, track_count = 0, 0
    for _, g in ipairs(groups) do
      local n_moved = layout_items(g.items, S)
      if n_moved > 0 then
        moved = moved + n_moved
        track_count = track_count + 1
      end
    end

    -- Block sequencing runs last, over the groups in track order.
    local cascaded = S.cascade_on and cascade_groups(groups, S.cascade_gap) or 0

    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("Sort items by name", -1)

    if moved == 0 and cascaded == 0 then
      status_msg = "Already in order."
    else
      status_msg = ("Reordered %d item%s on %d track%s"):format(
        moved, moved == 1 and "" or "s", track_count, track_count == 1 and "" or "s")
      if cascaded > 0 then status_msg = status_msg .. ", cascaded" end
    end
    cached_sig = nil
    return
  end

  -- Already ordered by the caller, so the preview's track order and the
  -- order they get created in cannot drift apart.
  local ordered = groups

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

    -- g.items is already in sort order (compute_groups did it), so the
    -- group's items land on the new track in that order.
    if S.sort_items_on then layout_items(g.items, S) end

    insert_idx = insert_idx + 1
    track_count = track_count + 1
  end

  -- After every track exists and its items are laid out, so the blocks
  -- being sequenced are final.
  local cascaded = S.cascade_on and cascade_groups(ordered, S.cascade_gap) or 0

  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock("Arrange items by name", -1)

  status_msg = ("Arranged %d item%s onto %d track%s"):format(
    total_items, total_items == 1 and "" or "s", track_count, track_count == 1 and "" or "s")
  if cascaded > 0 then status_msg = status_msg .. ", cascaded" end

  cached_sig = nil  -- force a fresh preview (track numbers/order just changed)
end

-- ============================================================
-- ImGui context
-- ============================================================
local script_title = "ARRANGE ITEMS BY NAME"
local ctx = ImGui.CreateContext(script_title)

local WIN_FLAGS    = ImGui.WindowFlags_NoCollapse
local CHILD_BORDER = rawget(ImGui, "ChildFlags_Border") or 1

local DIM_TEXT    = 0xA0A0A0FF
local ACCENT_TEXT = 0x7FB8AEFF
local RULE_COLOR  = 0x3A3F45FF
local CHIP_BG     = 0x3A3F45FF

-- Left settings rail / right preview split, following the geometry in
-- Tracks/Rename Selected Tracks.lua. Inside a bare BeginGroup, anything
-- sized -1 (tables, separators, buttons) fills the *window*, not the rail --
-- so every such item below gets an explicit width, and the indented ones get
-- the rail width minus their own indent.
local LEFT_COL_W     = 336
local LEFT_PAD       = 10   -- breathing room between the rail's edges and its content
local TOP_PAD        = 8    -- matching breathing room above the first row
local RAIL_GUTTER    = 12   -- gap between the rail's content and its scrollbar
local COL_GUTTER     = 20   -- gap between the rail and the preview column
local INDENT         = 16
local LEFT_CONTENT_W = LEFT_COL_W - LEFT_PAD * 2
-- Recomputed each frame in loop(): the settings scroll inside a child
-- window, whose scrollbar plus RAIL_GUTTER eat into the width its content
-- can use. INNER_W is that usable width -- the rules span it, and the field
-- tables get it minus their own indent.
local INNER_W        = LEFT_CONTENT_W
local SECTION_W      = LEFT_CONTENT_W - INDENT
local LABEL_W        = 150
local RAIL_BG        = 0x222222FF  -- matches the theme's Col_ChildBg, so the
                                   -- settings' scroll child blends into the rail

-- Height of the pinned footer (rule + Apply + status), measured at the end
-- of each frame and used to size the scroll area above it on the next one.
-- Seeded with a close guess so the first frame lands near-right; the
-- measurement corrects it before anyone can see the difference.
local left_footer_h = 64

-- ============================================================
-- UI helpers
-- ============================================================
local function section_title(text)
  theme.PushBoldFont(ctx)
  ImGui.Text(ctx, text)
  theme.PopBoldFont(ctx)
end

-- ImGui.Separator() spans the window's content width inside a bare
-- BeginGroup, which would draw a line straight across the preview column --
-- so the rail's rules are drawn by hand at the rail's own width.
local function rail_rule(width)
  ImGui.Spacing(ctx)
  local sx, sy = ImGui.GetCursorScreenPos(ctx)
  ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx),
    sx, sy, sx + (width or INNER_W), sy + 1, RULE_COLOR)
  ImGui.Dummy(ctx, 0, 1)
  ImGui.Spacing(ctx)
end

-- width pins the table to the rail instead of the window: without it a
-- WidthStretch column stretches across the whole window, shoving the
-- preview column off the right edge.
local function begin_field_table(id, width)
  local ok = ImGui.BeginTable(ctx, id, 2, 0, width or SECTION_W, 0)
  if ok then
    ImGui.TableSetupColumn(ctx, "##label", ImGui.TableColumnFlags_WidthFixed, LABEL_W)
    ImGui.TableSetupColumn(ctx, "##ctl",   ImGui.TableColumnFlags_WidthStretch)
  end
  return ok
end

local function field_label(text)
  ImGui.TableNextRow(ctx)
  ImGui.TableSetColumnIndex(ctx, 0)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
  ImGui.Text(ctx, text)
  ImGui.PopStyleColor(ctx)
  ImGui.TableSetColumnIndex(ctx, 1)
end

local function check_field(label, key)
  local changed, v = ImGui.Checkbox(ctx, label .. "##" .. key, S[key])
  if changed then S[key] = v; save_settings() end
end

-- A combo whose options are {value, label} pairs, rendered as a labelled row.
local function combo_field(label, id, key, options)
  field_label(label)
  local current = ""
  for _, opt in ipairs(options) do
    if opt[1] == S[key] then current = opt[2] end
  end
  ImGui.SetNextItemWidth(ctx, -1)
  if ImGui.BeginCombo(ctx, "##" .. id, current, 0) then
    for _, opt in ipairs(options) do
      if ImGui.Selectable(ctx, opt[2], S[key] == opt[1], 0) then
        S[key] = opt[1]; save_settings()
      end
    end
    ImGui.EndCombo(ctx)
  end
end

-- Shows what a priority field actually parsed to. An empty list still
-- sorts (natural order), so without this the difference between "nothing
-- set" and "priority applied" is invisible until Apply -- which is exactly
-- the trap the greyed placeholder text set earlier.
local function priority_readout(spec)
  local levels = parse_priority_levels(spec)
  if #levels == 0 then
    ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
    ImGui.TextWrapped(ctx, "No priority words \u{2014} natural order only")
    ImGui.PopStyleColor(ctx)
    return
  end
  -- One line per level, numbered once there is more than one, so the
  -- precedence between sets is visible rather than inferred from the text.
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, ACCENT_TEXT)
  for i, words in ipairs(levels) do
    local body = table.concat(words, "  \u{2192}  ")
    ImGui.TextWrapped(ctx, #levels > 1 and ("%d.  %s"):format(i, body) or body)
  end
  ImGui.PopStyleColor(ctx)
end

-- ============================================================
-- Rail sections
-- ============================================================
local function draw_grouping()
  section_title("GROUPING")
  ImGui.Indent(ctx, INDENT)

  if begin_field_table("##grouping_fields") then
    combo_field("Mode:", "mode", "grouping_mode", {
      {"prefix", "Common Prefix"},
      {"fuzzy",  "Fuzzy Similarity"},
    })

    if S.grouping_mode == "fuzzy" then
      field_label("Similarity:")
      ImGui.SetNextItemWidth(ctx, -1)
      local changed, v = ImGui.SliderInt(ctx, "##threshold", S.threshold_pct, 0, 100, "%d%%")
      if changed then S.threshold_pct = v; save_settings() end
    else
      field_label("Depth:")
      ImGui.SetNextItemWidth(ctx, -1)
      local changed, v = ImGui.SliderInt(ctx, "##depth", S.depth, 1, 6)
      if changed then S.depth = v; save_settings() end
    end

    ImGui.EndTable(ctx)
  end

  ImGui.Unindent(ctx, INDENT)
end

local function draw_tokens()
  section_title("NAME MATCHING")
  ImGui.Indent(ctx, INDENT)

  ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
  ImGui.Text(ctx, "Split On")
  ImGui.PopStyleColor(ctx)

  -- All four fit on one row at the rail's width; the gutters keep the
  -- single-character labels from reading as one run of punctuation.
  check_field("Space", "delim_space")
  ImGui.SameLine(ctx, 0, 12)
  check_field("_", "delim_underscore")
  ImGui.SameLine(ctx, 0, 12)
  check_field("-", "delim_hyphen")
  ImGui.SameLine(ctx, 0, 12)
  check_field(".", "delim_period")

  ImGui.Spacing(ctx)
  check_field("Ignore Numeric Tokens", "ignore_numbers")
  check_field("Ignore Case", "ignore_case")
  ImGui.Spacing(ctx)

  if begin_field_table("##token_fields") then
    field_label("Ignore Words:")
    ImGui.SetNextItemWidth(ctx, -1)
    local changed, v = ImGui.InputTextWithHint(ctx, "##ignore_words", "L, R, M, S, take", S.ignore_words)
    if changed then S.ignore_words = v; save_settings() end
    ImGui.EndTable(ctx)
  end

  ImGui.Unindent(ctx, INDENT)
end

local function draw_output()
  section_title("OUTPUT")
  ImGui.Indent(ctx, INDENT)

  if begin_field_table("##output_fields") then
    combo_field("Placement:", "placement", "placement", {
      {"below", "Below Selection"},
      {"end",   "End of Track List"},
      {"keep",  "Keep Current Tracks"},
    })
    ImGui.EndTable(ctx)
  end

  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx,
      "Where the new tracks go. Keep Current Tracks creates\n" ..
      "nothing and only reorders items where they already are.")
  end

  -- Left live even in keep mode: no tracks are created there, but this
  -- order still drives the preview and the cascade sequence.
  if begin_field_table("##track_order_fields") then
    combo_field("Track Order:", "track_order", "track_order", {
      {"grouped",  "As Grouped"},
      {"alpha",    "Alphabetical"},
      {"priority", "Priority Words"},
    })
    if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
      ImGui.SetTooltip(ctx,
        "The order the new tracks are created in -- and, with\n" ..
        "Cascade on, the order their material is sequenced in.\n" ..
        "In Keep Current Tracks nothing is reordered in the\n" ..
        "track list; this still sets the preview and cascade order.\n\n" ..
        "As Grouped keeps the order the groups were found in;\n" ..
        "Priority Words ranks track names the same way the\n" ..
        "item priority list ranks item names, including\n" ..
        "several \";\"-separated sets.")
    end

    if S.track_order == "priority" then
      field_label("Track Priority:")
      ImGui.SetNextItemWidth(ctx, -1)
      local changed, v = ImGui.InputTextWithHint(ctx, "##track_priority",
        "e.g. light, normal, heavy; slow, fast", S.track_priority)
      if changed then S.track_priority = v; save_settings() end
    end

    ImGui.EndTable(ctx)
  end

  if S.track_order == "priority" then priority_readout(S.track_priority) end

  ImGui.Spacing(ctx)
  check_field("Cascade Tracks Across Timeline", "cascade_on")
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx,
      "Sequence each track's block of items along the timeline in\n" ..
      "track order, so the first track plays first and the\n" ..
      "arrangement staircases down and to the right.\n\n" ..
      "Spacing inside a track is untouched -- each block moves as\n" ..
      "a unit. The cascade starts where the earliest item already\n" ..
      "sits, so the material stays put on the timeline.")
  end

  if S.cascade_on then
    if begin_field_table("##cascade_fields") then
      field_label("Cascade Gap (s):")
      ImGui.SetNextItemWidth(ctx, -1)
      local changed, v = ImGui.InputDouble(ctx, "##cascade_gap", S.cascade_gap, 0.1, 1.0, "%.3f")
      if changed then
        S.cascade_gap = math.max(0, v)
        save_settings()
      end
      if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
        ImGui.SetTooltip(ctx, "Silence between one track's block and the next, in seconds.")
      end
      ImGui.EndTable(ctx)
    end
  end

  ImGui.Unindent(ctx, INDENT)
end

local function draw_item_sort()
  section_title("ITEM ORDER")
  ImGui.Indent(ctx, INDENT)

  -- Sorting is the only thing the keep mode does, so the checkbox is
  -- shown forced on there rather than letting Apply become a no-op.
  local keep = S.placement == "keep"
  if keep then ImGui.BeginDisabled(ctx, true) end
  if keep then
    ImGui.Checkbox(ctx, "Sort Items on Track##sort_forced", true)
  else
    check_field("Sort Items on Track", "sort_items_on")
  end
  if keep then ImGui.EndDisabled(ctx) end
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx, keep
      and "Always on when Placement is Keep Current Tracks."
      or  "Reorder each group's items into the timeline slots they\n" ..
          "already occupy, as part of Apply.")
  end

  local sorting_active = S.sort_items_on or keep
  if not sorting_active then ImGui.BeginDisabled(ctx, true) end

  ImGui.Spacing(ctx)

  if begin_field_table("##sort_fields") then
    field_label("Priority:")
    ImGui.SetNextItemWidth(ctx, -1)
    -- The hint is prefixed "e.g." on purpose: ReaImGui greys a hint into an
    -- empty field, and a bare "light, normal, heavy" there is
    -- indistinguishable from the same text actually entered.
    local changed, v = ImGui.InputTextWithHint(ctx, "##sort_order", "e.g. light, normal, heavy; slow, fast", S.sort_order)
    if changed then S.sort_order = v; save_settings() end
    ImGui.EndTable(ctx)
  end

  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
    ImGui.SetTooltip(ctx,
      "Comma-separated words, in the order you want them.\n" ..
      "An item sorts by the first word its name contains;\n" ..
      "names matching none go last.\n\n" ..
      "Separate several sets with \";\" to sort on more than one:\n" ..
      "  light, normal, heavy; slow, fast\n" ..
      "ranks by intensity first, then uses speed to break ties.\n\n" ..
      "Ties break naturally, so _02 precedes _10.\n" ..
      "Leave blank for plain natural order.")
  end

  priority_readout(S.sort_order)

  ImGui.Spacing(ctx)

  if begin_field_table("##layout_fields") then
    combo_field("Layout:", "layout", "sort_layout", {
      {"slots",  "Keep Positions"},
      {"repack", "Repack End-to-End"},
    })
    if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
      ImGui.SetTooltip(ctx,
        "Keep Positions reuses the timeline slots the items\n" ..
        "already occupy, so spacing and total length survive --\n" ..
        "but a long item landing in a short slot can overlap.\n\n" ..
        "Repack lays them end to end from the first item's\n" ..
        "start, spaced by their real lengths plus the gap, so\n" ..
        "nothing can overlap and no dead air is left behind.")
    end

    if S.sort_layout == "repack" then
      field_label("Gap (s):")
      ImGui.SetNextItemWidth(ctx, -1)
      local changed, v = ImGui.InputDouble(ctx, "##repack_gap", S.repack_gap, 0.1, 0.5, "%.3f")
      if changed then
        S.repack_gap = math.max(0, v)  -- a negative gap would force overlaps
        save_settings()
      end
      if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
        ImGui.SetTooltip(ctx, "Silence between consecutive items, in seconds. 0 butts them together.")
      end
    end

    ImGui.EndTable(ctx)
  end

  if not sorting_active then ImGui.EndDisabled(ctx) end
  ImGui.Unindent(ctx, INDENT)
end

-- ============================================================
-- Render loop
-- ============================================================
local function loop()
  local color_count, var_count = theme.Push(ctx)

  ImGui.SetNextWindowSizeConstraints(ctx, LEFT_COL_W + 280, 420, 3000, 10000)
  ImGui.SetNextWindowSize(ctx, 960, 720, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, script_title, true, WIN_FLAGS)

  if visible then
    -- Built once up front, before any widget can mutate S this frame, so the
    -- Apply button and the preview beside it always act on the same list.
    local keep_mode = S.placement == "keep"
    -- order_groups is applied here, not inside apply_groups, so the preview
    -- lists the tracks in the exact order Apply will create them.
    local groups = order_groups(compute_groups(S), S)
    local total_items = 0
    for _, g in ipairs(groups) do total_items = total_items + #g.items end

    -- ---- Left column: settings rail ----
    -- avail_h is "from here to the bottom of the window at its current
    -- size", so the rail's tint stretches the full height rather than
    -- stopping at the last field.
    local avail_w, avail_h = ImGui.GetContentRegionAvail(ctx)
    local lx0, ly0 = ImGui.GetCursorScreenPos(ctx)
    ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx),
      lx0, ly0, lx0 + LEFT_COL_W, ly0 + avail_h, RAIL_BG, 4)

    -- The settings scroll inside a child sized to whatever the footer
    -- leaves, so its tables lose the scrollbar's width.
    local sb_w = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ScrollbarSize)
    INNER_W   = LEFT_CONTENT_W - sb_w - RAIL_GUTTER
    SECTION_W = INNER_W - INDENT

    ImGui.BeginGroup(ctx)
    -- Indent shifts every subsequent item's left edge by LEFT_PAD; paired
    -- with sizing content to LEFT_CONTENT_W so nothing touches the rail's
    -- edges. Must be un-indented before EndGroup below.
    ImGui.Indent(ctx, LEFT_PAD)
    ImGui.Dummy(ctx, 0, TOP_PAD)

    -- ---- Scrolling settings ----
    -- EndChild must be called unconditionally -- skipping it when BeginChild
    -- returns false is what unbalances ReaImGui's window stack. The child's
    -- background is the theme's Col_ChildBg, the same color as the rail, so
    -- the scroll region is invisible.
    local settings_h = math.max(avail_h - TOP_PAD * 2 - left_footer_h, 120)
    local settings_visible = ImGui.BeginChild(ctx, "##settings", LEFT_CONTENT_W, settings_h)
    if settings_visible then
      draw_grouping()
      rail_rule()
      draw_tokens()
      rail_rule()
      draw_output()
      rail_rule()
      draw_item_sort()
    end
    ImGui.EndChild(ctx)

    -- ---- Pinned footer ----
    local _, footer_top_y = ImGui.GetCursorScreenPos(ctx)

    -- Full rail width: the footer is outside the scroll area, so no
    -- scrollbar to clear.
    rail_rule(LEFT_CONTENT_W)

    -- Apply: explicit width rather than -1, which would fill to the
    -- window's edge instead of the rail's.
    local disabled = total_items == 0
    if disabled then ImGui.BeginDisabled(ctx, true) end
    local clicked = theme.PrimaryButton(ctx,
      keep_mode and "Sort Items" or "Apply", LEFT_CONTENT_W, 0, nil,
      keep_mode and theme.Icons.LEFT_RIGHT or theme.Icons.TRACKS)
    if disabled then ImGui.EndDisabled(ctx) end
    if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_AllowWhenDisabled) then
      ImGui.SetTooltip(ctx, keep_mode
        and "Reorder the selected items on the tracks they are already on."
        or  "Create one track per group and move each group's items onto it.")
    end


    if status_msg ~= "" then
      ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
      ImGui.TextWrapped(ctx, status_msg)
      ImGui.PopStyleColor(ctx)
    end

    local _, footer_bottom_y = ImGui.GetCursorScreenPos(ctx)
    left_footer_h = footer_bottom_y - footer_top_y

    ImGui.Dummy(ctx, 0, TOP_PAD)
    ImGui.Unindent(ctx, LEFT_PAD)
    ImGui.EndGroup(ctx)

    -- ---- Right column: live preview ----
    -- Gap is COL_GUTTER + LEFT_PAD: the left group's measured bounding box
    -- ends LEFT_PAD short of the tint rect's right edge (its content is
    -- inset), so the offset needs that back to read as an even gutter.
    ImGui.SameLine(ctx, 0, COL_GUTTER + LEFT_PAD)

    ImGui.BeginGroup(ctx)
    ImGui.Dummy(ctx, 0, TOP_PAD)  -- aligns with the rail's first row

    section_title("PREVIEW")

    ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
    ImGui.Text(ctx, ("%d item%s selected \u{2192} %d %s%s"):format(
      total_items, total_items == 1 and "" or "s",
      #groups, keep_mode and "track" or "group", #groups == 1 and "" or "s"))
    ImGui.PopStyleColor(ctx)

    ImGui.Spacing(ctx)

    local preview_w = math.max(avail_w - LEFT_COL_W - COL_GUTTER, 240)
    local _, region_h = ImGui.GetContentRegionAvail(ctx)
    local preview_h = math.max(region_h - TOP_PAD, 120)

    local preview_visible = ImGui.BeginChild(ctx, "##preview", preview_w, preview_h, CHILD_BORDER)
    if preview_visible then
      if #groups == 0 then
        ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
        ImGui.Text(ctx, "Select one or more items.")
        ImGui.PopStyleColor(ctx)
      end
      for _, g in ipairs(groups) do
        -- Keyed by group, not loop index: renaming a track can reorder the
        -- list mid-keystroke, and an index-based ID would hand the focused
        -- input's identity to whichever group slid into that slot.
        ImGui.PushID(ctx, g.key)

        local expanded = ImGui.CollapsingHeader(ctx, "##hdr", nil, ImGui.TreeNodeFlags_DefaultOpen)
        ImGui.SameLine(ctx)
        theme.Chip(ctx, tostring(#g.items), DIM_TEXT, CHIP_BG)
        ImGui.SameLine(ctx)
        if keep_mode then
          -- No track is created, so there is no name to edit -- this is the
          -- existing track the items are already on.
          ImGui.AlignTextToFramePadding(ctx)
          ImGui.Text(ctx, g.label)
        else
          ImGui.SetNextItemWidth(ctx, -1)
          local name_changed, new_name = ImGui.InputText(ctx, "##name", track_name_overrides[g.key] or g.label)
          if name_changed then track_name_overrides[g.key] = new_name end
        end

        if expanded then
          ImGui.Indent(ctx, 12)
          ImGui.PushStyleColor(ctx, ImGui.Col_Text, DIM_TEXT)
          for _, e in ipairs(g.items) do
            ImGui.Text(ctx, e.name)
          end
          ImGui.PopStyleColor(ctx)
          ImGui.Unindent(ctx, 12)
          ImGui.Spacing(ctx)
        end

        ImGui.PopID(ctx)
      end
    end
    ImGui.EndChild(ctx)

    ImGui.Dummy(ctx, 0, TOP_PAD)
    ImGui.EndGroup(ctx)

    -- Deferred until both columns are drawn, so the track creation and its
    -- undo block never run with widgets still queued behind it.
    if clicked then apply_groups(groups) end

    ImGui.End(ctx)
  end

  theme.Pop(ctx, color_count, var_count)

  if still_open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
