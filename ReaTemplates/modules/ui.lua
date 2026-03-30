-- ============================================================
-- ui.lua  –  Full ReaTemplates UI
-- Renders all views: main window, side panel, list view, detail view,
-- and all modals (save, setup, settings).
-- ============================================================

local M = {}

-- Injected dependencies
local ImGui        = nil
local ctx          = nil
local theme        = nil
local json         = nil
local config       = nil
local metadata     = nil
local github       = nil
local sync         = nil
local plugin_detect = nil
local toast        = nil

-- ============================================================
-- UI State
-- ============================================================

-- Window
local WIN_W    = 900
local WIN_H    = 600
local open     = true
local WIN_FLAGS

-- Navigation
local VIEW_LIST   = 'list'
local VIEW_DETAIL = 'detail'
local current_view = VIEW_LIST
local detail_item  = nil  -- the template being viewed in detail

-- Side panel
local tag_filters     = {}  -- { [tag] = bool }
local sort_mode       = 0   -- 0=Name, 1=Date, 2=Category
local show_my         = true
local show_community  = true

-- Toolbar
local search_buf = ''
local is_online  = false

-- Template lists (refreshed on open/sync)
local local_templates     = {}
local community_templates = {}
local all_templates       = {}  -- merged, filtered view

-- Modals
local modal_save_open     = false
local modal_setup_open    = false
local modal_settings_open = false
local modal_delete_open   = false
local delete_target       = nil

-- Save modal state
local save_name_buf   = ''
local save_desc_buf   = ''
local save_tags_sel   = {}   -- { [tag] = bool }
local save_custom_buf = ''
local save_preview_buf = ''
local save_error_msg  = ''

-- Settings modal state
local cfg_username_buf  = ''
local cfg_pat_buf       = ''
local cfg_repo_buf      = ''
local cfg_folder_buf    = ''
local cfg_validate_msg  = ''
local settings_tab      = 0   -- 0=General, 1=Admin
local admin_tags_buf    = ''  -- newline-separated list

-- Upload state
local upload_in_progress = false
local upload_target      = nil  -- template being uploaded

-- Tag edit state (side panel inline editor)
local edit_tags_mode  = false  -- side panel showing edit mode
local edit_tag_list   = {}     -- working copy while editing
local new_tag_buf     = ''     -- input buffer for the new-tag row

-- ============================================================
-- Helpers
-- ============================================================

local function pcolor(c)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, c)
end

local function pop_color(n)
  ImGui.PopStyleColor(ctx, n or 1)
end

local function tag_color(tag)
  -- Generate a stable colour from tag name
  local hash = 0
  for i = 1, #tag do hash = hash * 31 + tag:byte(i) end
  local hue = (hash % 360) / 360.0
  -- Convert HSL(hue, 0.55, 0.42) → approximate RGBA
  local function hsl2rgb(h, s, l)
    local function hue2rgb(p, q, t)
      if t < 0 then t = t + 1 end
      if t > 1 then t = t - 1 end
      if t < 1/6 then return p + (q - p) * 6 * t end
      if t < 1/2 then return q end
      if t < 2/3 then return p + (q - p) * (2/3 - t) * 6 end
      return p
    end
    if s == 0 then return l, l, l end
    local q2 = l < 0.5 and l * (1 + s) or l + s - l * s
    local p2 = 2 * l - q2
    return hue2rgb(p2, q2, h + 1/3),
           hue2rgb(p2, q2, h),
           hue2rgb(p2, q2, h - 1/3)
  end
  local r, g, b = hsl2rgb(hue, 0.55, 0.38)
  return math.floor(r*255+0.5) * 0x1000000 +
         math.floor(g*255+0.5) * 0x10000   +
         math.floor(b*255+0.5) * 0x100     + 0xFF
end

local function format_date(iso)
  if not iso or iso == '' then return '' end
  local y, mo, d = iso:match('^(%d%d%d%d)-(%d%d)-(%d%d)')
  if y then return string.format('%s/%s/%s', mo, d, y) end
  return iso
end

-- Refresh and filter the combined template list
local function refresh_templates()
  local cfg = config.get()
  local my_name = cfg.github_username or ''

  all_templates = {}
  local seen = {}

  -- My local templates
  if show_my then
    for _, t in ipairs(local_templates) do
      local key = 'local:' .. t.name
      if not seen[key] then
        seen[key] = true
        all_templates[#all_templates + 1] = {
          name        = t.name,
          path        = t.path,
          meta        = t.meta,
          is_mine     = true,
          is_local    = true,
        }
      end
    end
  end

  -- Community templates
  if show_community then
    for _, meta in ipairs(community_templates) do
      if meta.creator ~= my_name then
        local key = 'community:' .. (meta.creator or '') .. ':' .. meta.name
        if not seen[key] then
          seen[key] = true
          all_templates[#all_templates + 1] = {
            name        = meta.name,
            path        = nil,
            meta        = meta,
            is_mine     = false,
            is_local    = false,
          }
        end
      end
    end
  end

  -- Apply tag filters
  local active_tags = {}
  for tag, on in pairs(tag_filters) do
    if on then active_tags[#active_tags + 1] = tag end
  end

  if #active_tags > 0 then
    local filtered = {}
    for _, t in ipairs(all_templates) do
      local meta = t.meta or {}
      local all_tags = {}
      for _, tag in ipairs(meta.predefined_tags or {}) do all_tags[tag] = true end
      for _, tag in ipairs(meta.custom_tags or {}) do all_tags[tag] = true end
      local match = false
      for _, f in ipairs(active_tags) do
        if all_tags[f] then match = true; break end
      end
      if match then filtered[#filtered + 1] = t end
    end
    all_templates = filtered
  end

  -- Apply search
  if search_buf ~= '' then
    local lower = search_buf:lower()
    local filtered = {}
    for _, t in ipairs(all_templates) do
      local meta = t.meta or {}
      local haystack = ((meta.name or t.name) .. ' ' ..
                        (meta.creator or '') .. ' ' ..
                        (meta.description or '')):lower()
      if haystack:find(lower, 1, true) then
        filtered[#filtered + 1] = t
      end
    end
    all_templates = filtered
  end

  -- Sort
  if sort_mode == 0 then
    table.sort(all_templates, function(a, b)
      return (a.name or ''):lower() < (b.name or ''):lower()
    end)
  elseif sort_mode == 1 then
    table.sort(all_templates, function(a, b)
      local da = (a.meta and a.meta.date_created) or ''
      local db = (b.meta and b.meta.date_created) or ''
      return da > db  -- newest first
    end)
  elseif sort_mode == 2 then
    table.sort(all_templates, function(a, b)
      local ta = (a.meta and a.meta.predefined_tags and a.meta.predefined_tags[1]) or ''
      local tb = (b.meta and b.meta.predefined_tags and b.meta.predefined_tags[1]) or ''
      return ta:lower() < tb:lower()
    end)
  end
end

-- Reload local + community lists
local function reload_all()
  local ok, result = pcall(metadata.scan_local)
  if ok then local_templates = result else local_templates = {} end
  local ok2, result2 = pcall(metadata.scan_cache)
  if ok2 then community_templates = result2 else community_templates = {} end
  refresh_templates()
end

-- Get the user's ordered personal tag list, falling back to predefined or hardcoded defaults.
-- This is the single source of truth for every tag list in the UI.
local function get_display_tags()
  local cfg = config.get()
  if cfg.user_tags and #cfg.user_tags > 0 then
    return cfg.user_tags
  end
  if cfg.predefined_tags and #cfg.predefined_tags > 0 then
    return cfg.predefined_tags
  end
  return { 'Drums', 'Bass', 'Keys', 'Guitar', 'Vocals', 'Bus', 'FX', 'Synth', 'Strings', 'Brass' }
end

-- ============================================================
-- Template save / insert operations
-- ============================================================

-- Build an .RTrackTemplate XML from currently-selected tracks
local function build_rtracktemplate()
  local n = reaper.CountSelectedTracks(0)
  if n == 0 then return nil, 'No tracks selected' end

  local chunks = {}
  for i = 0, n - 1 do
    local track = reaper.GetSelectedTrack(0, i)
    if track then
      local ok, chunk = reaper.GetTrackStateChunk(track, '', false)
      if ok and chunk then
        chunks[#chunks + 1] = chunk
      end
    end
  end

  if #chunks == 0 then return nil, 'Could not read track state' end

  local xml = '<TRACKTEMPLATE\n' .. table.concat(chunks, '\n') .. '\n>'
  return xml, nil
end

-- Save a new track template
-- name:         template name
-- desc:         description
-- pred_tags:    list of predefined tag strings
-- custom_tags:  list of custom tag strings
-- preview_path: optional preview image path
local function do_save_template(name, desc, pred_tags, custom_tags, preview_path)
  -- Build XML
  local xml, err = build_rtracktemplate()
  if err then
    toast.error('Save failed: ' .. err)
    return false
  end

  -- Write .RTrackTemplate file
  local tmpl_path = metadata.template_file_path(name)
  local f = io.open(tmpl_path, 'w')
  if not f then
    toast.error('Cannot write template file: ' .. tmpl_path)
    return false
  end
  f:write(xml)
  f:close()

  -- Detect plugins
  local plugins = plugin_detect.parse_plugins(xml)
  -- Optionally enrich installed status (can be slow)
  -- We do a quick enrich here since this is user-initiated
  local ok_enrich = pcall(plugin_detect.enrich_installed_status, plugins)
  if not ok_enrich then
    -- Fall back to unknown installed status
    for _, p in ipairs(plugins) do p.installed = nil end
  end

  -- Build metadata
  local cfg  = config.get()
  local meta = metadata.default_meta(name, cfg.github_username or '')
  meta.description    = desc or ''
  meta.predefined_tags = pred_tags or {}
  meta.custom_tags    = custom_tags or {}
  meta.plugins        = plugins
  meta.preview_image  = preview_path or ''
  meta.uploaded       = false

  local ok_meta, meta_err = metadata.write_meta(meta)
  if not ok_meta then
    toast.error('Metadata write failed: ' .. tostring(meta_err))
    return false
  end

  toast.success('Saved: ' .. name)
  reload_all()
  return true
end

-- Insert a template into the current project by path
local function do_insert_template(item)
  local path = item.path
  if not path then
    -- Community template — need to download first
    local creator = item.meta and item.meta.creator or ''
    local name    = item.name
    local content, dl_err = github.download_template_file(creator, name)
    if dl_err then
      toast.error('Download failed: ' .. dl_err)
      return
    end
    -- Write to a temp location
    local cfg      = config.get()
    path = metadata.template_file_path(name)
    local f = io.open(path, 'wb')
    if not f then toast.error('Cannot write downloaded template') return end
    f:write(content)
    f:close()
    -- Update local listing
    reload_all()
  end

  -- Check for missing plugins
  local plugins = (item.meta and item.meta.plugins) or {}
  if plugin_detect.has_missing_plugins(plugins) then
    local missing = plugin_detect.get_missing_plugins(plugins)
    local names = {}
    for _, p in ipairs(missing) do names[#names + 1] = p.name end
    toast.warning('Missing plugins: ' .. table.concat(names, ', '))
    -- Continue insertion anyway
  end

  -- Read the template file
  local f = io.open(path, 'r')
  if not f then toast.error('Cannot read: ' .. path) return end
  local xml = f:read('*a')
  f:close()

  -- Extract individual track chunks from the XML
  -- Template format: <TRACKTEMPLATE\n<TRACK ...>\n</TRACK>...>
  -- Each top-level <TRACK block is a separate track
  local track_chunks = {}
  local pos = 1
  while true do
    local chunk_start = xml:find('<TRACK', pos, true)
    if not chunk_start then break end

    -- Find matching closing using REAPER chunk nesting (balanced < >)
    local depth = 0
    local i = chunk_start
    local len = #xml
    while i <= len do
      local c = xml:sub(i, i)
      if c == '<' then
        depth = depth + 1
      elseif c == '>' then
        depth = depth - 1
        if depth == 0 then
          track_chunks[#track_chunks + 1] = xml:sub(chunk_start, i)
          pos = i + 1
          break
        end
      end
      i = i + 1
    end
    if depth ~= 0 then break end
  end

  if #track_chunks == 0 then
    toast.error('No tracks found in template')
    return
  end

  -- Insert tracks
  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  local insert_pos = reaper.CountTracks(0)
  for idx, chunk in ipairs(track_chunks) do
    reaper.InsertTrackAtIndex(insert_pos + idx - 1, false)
    local new_track = reaper.GetTrack(0, insert_pos + idx - 1)
    if new_track then
      reaper.SetTrackStateChunk(new_track, chunk, false)
    end
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock('Insert track template: ' .. item.name, -1)

  toast.success('Inserted: ' .. item.name)
end

-- Upload a template to GitHub
local function do_upload_template(item)
  if not item.is_mine then
    toast.error('Can only upload your own templates')
    return
  end

  if not item.path then
    toast.error('Template file not found')
    return
  end

  local meta = item.meta
  if not meta then
    toast.error('No metadata for ' .. item.name)
    return
  end

  -- Upload template file
  local _, t_err = github.upload_template_file(item.name, item.path)
  if t_err then
    toast.error('Upload failed: ' .. t_err)
    return
  end

  -- Upload meta
  meta.uploaded = true
  local _, m_err = github.upload_meta(meta)
  if m_err then
    toast.error('Meta upload failed: ' .. m_err)
    return
  end

  -- Update local meta file
  metadata.write_meta(meta)
  reload_all()
  toast.success('Uploaded: ' .. item.name)
end

-- Delete a local template (and optionally from GitHub)
local function do_delete_local(item)
  if item.path then
    os.remove(item.path)
  end
  metadata.delete_meta(item.name)
  reload_all()
  toast.info('Deleted: ' .. item.name)
end

-- ============================================================
-- Draw: Tag pills
-- ============================================================

local function draw_tag_pills(tags, pred_tags)
  if not tags then return end

  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 10)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)

  for _, tag in ipairs(pred_tags or {}) do
    local col = tag_color(tag)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        col)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, col)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  col)
    ImGui.SmallButton(ctx, tag)
    ImGui.PopStyleColor(ctx, 3)
    ImGui.SameLine(ctx)
  end

  for _, tag in ipairs(tags or {}) do
    local col = tag_color(tag)
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        col)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, col)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  col)
    ImGui.SmallButton(ctx, tag)
    ImGui.PopStyleColor(ctx, 3)
    ImGui.SameLine(ctx)
  end

  ImGui.PopStyleVar(ctx, 2)
end

-- ============================================================
-- Draw: Side Panel
-- ============================================================

local function draw_side_panel()
  local cfg = config.get()

  -- Panel background
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x1B1D1FFF)
  if ImGui.BeginChild(ctx, '##side_panel', 200, 0, ImGui.ChildFlags_Borders) then

    -- Header
    ImGui.Spacing(ctx)
    pcolor(0x7AD9C4FF)
    ImGui.Text(ctx, 'ReaTemplates')
    pop_color()
    ImGui.SameLine(ctx)
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + ImGui.GetContentRegionAvail(ctx) - 22)
    if ImGui.SmallButton(ctx, '⚙##settings') then
      modal_settings_open = true
      cfg_username_buf = cfg.github_username or ''
      cfg_pat_buf      = ''  -- Never pre-fill PAT in UI
      cfg_repo_buf     = cfg.github_repo or ''
      cfg_folder_buf   = cfg.templates_folder or ''
      cfg_validate_msg = ''
      -- Populate admin tags buffer (admin manages the shared predefined list)
      local cfg2 = config.get()
      local admin_tags = (cfg2.predefined_tags and #cfg2.predefined_tags > 0)
                         and cfg2.predefined_tags
                         or get_display_tags()
      admin_tags_buf = table.concat(admin_tags, '\n')
    end

    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- My Templates node
    local _, new_show_my = ImGui.Checkbox(ctx, ' My Templates##my', show_my)
    show_my = new_show_my

    -- Community node
    local _, new_show_com = ImGui.Checkbox(ctx, ' Community##com', show_community)
    show_community = new_show_com

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Filter by tag
    pcolor(0xA0A0A0FF)
    ImGui.Text(ctx, 'FILTER BY TAG')
    pop_color()

    if not edit_tags_mode then
      -- ---- Normal mode: checkboxes + [Edit Tags] button ----
      local display_tags = get_display_tags()
      for _, tag in ipairs(display_tags) do
        if tag_filters[tag] == nil then tag_filters[tag] = false end
        local _, checked = ImGui.Checkbox(ctx, tag .. '##ftag', tag_filters[tag])
        if checked ~= tag_filters[tag] then
          tag_filters[tag] = checked
          refresh_templates()
        end
      end

      ImGui.Spacing(ctx)
      pcolor(0x707070FF)
      if ImGui.SmallButton(ctx, '+ Edit Tags') then
        edit_tag_list = {}
        for _, t in ipairs(get_display_tags()) do
          edit_tag_list[#edit_tag_list + 1] = t
        end
        new_tag_buf   = ''
        edit_tags_mode = true
      end
      pop_color()

    else
      -- ---- Edit mode: drag-and-drop reorderable list ----
      local i = 1
      while i <= #edit_tag_list do
        local tag = edit_tag_list[i]
        local sel_id = '##etag' .. i

        -- Selectable acts as both visual row and drag/drop anchor
        ImGui.Selectable(ctx, '  ' .. tag .. sel_id, false)

        -- Drag source
        if ImGui.BeginDragDropSource(ctx, 0) then
          ImGui.SetDragDropPayload(ctx, 'TAG_IDX', tostring(i))
          pcolor(0xFFFFFFFF)
          ImGui.Text(ctx, tag)
          pop_color()
          ImGui.EndDragDropSource(ctx)
        end

        -- Drop target
        if ImGui.BeginDragDropTarget(ctx) then
          local payload = ImGui.AcceptDragDropPayload(ctx, 'TAG_IDX')
          if payload then
            local src = tonumber(payload)
            if src and src ~= i then
              local item = table.remove(edit_tag_list, src)
              table.insert(edit_tag_list, i, item)
            end
          end
          ImGui.EndDragDropTarget(ctx)
        end

        -- [×] remove button (right-aligned)
        ImGui.SameLine(ctx)
        local avail = ImGui.GetContentRegionAvail(ctx)
        ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail - 18)
        if ImGui.SmallButton(ctx, '×' .. sel_id) then
          table.remove(edit_tag_list, i)
          i = i - 1  -- recheck same index after removal
        end

        i = i + 1
      end

      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)

      -- New tag input row
      ImGui.SetNextItemWidth(ctx, -28)
      local enter_pressed, new_val = ImGui.InputTextWithHint(ctx, '##newtag', 'New tag...', new_tag_buf,
        ImGui.InputTextFlags_EnterReturnsTrue)
      new_tag_buf = new_val

      local function add_new_tag()
        local trimmed = new_tag_buf:match('^%s*(.-)%s*$')
        if trimmed ~= '' then
          local dup = false
          for _, t in ipairs(edit_tag_list) do
            if t:lower() == trimmed:lower() then dup = true; break end
          end
          if not dup then
            edit_tag_list[#edit_tag_list + 1] = trimmed
          end
        end
        new_tag_buf = ''
      end

      if enter_pressed then add_new_tag() end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, '+##addtag') then add_new_tag() end

      ImGui.Spacing(ctx)

      -- Done / Cancel buttons
      ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)
      local done_w = (ImGui.GetContentRegionAvail(ctx) - 8) * 0.5
      if ImGui.Button(ctx, 'Done##editdone', done_w, 0) then
        -- Commit: save locally then push to GitHub
        local save_cfg = config.get()
        save_cfg.user_tags = edit_tag_list
        config.save(save_cfg)
        tag_filters = {}
        refresh_templates()
        edit_tags_mode = false

        if is_online then
          local _, gh_err = github.update_user_tags(save_cfg.github_username, edit_tag_list)
          if gh_err then
            toast.error('Saved locally but GitHub push failed: ' .. gh_err)
          else
            toast.success('Tags saved')
          end
        else
          toast.info('Tags saved locally (will sync when online)')
        end
      end
      ImGui.PopStyleColor(ctx, 3)

      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Cancel##editcancel', done_w, 0) then
        edit_tags_mode = false
        edit_tag_list  = {}
      end
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Sort by
    pcolor(0xA0A0A0FF)
    ImGui.Text(ctx, 'SORT BY')
    pop_color()

    local sort_labels = { 'Name (A-Z)', 'Date Added', 'Category' }
    for i, label in ipairs(sort_labels) do
      if ImGui.RadioButton(ctx, label .. '##sort' .. i, sort_mode == i - 1) then
        sort_mode = i - 1
        refresh_templates()
      end
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Last sync info
    pcolor(0x606060FF)
    if cfg.last_sync and cfg.last_sync ~= '' then
      ImGui.Text(ctx, 'Synced: ' .. format_date(cfg.last_sync))
    else
      ImGui.Text(ctx, 'Never synced')
    end
    pop_color()

    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleColor(ctx)
end

-- ============================================================
-- Draw: Toolbar
-- ============================================================

local function draw_toolbar()
  -- Search box (stretches)
  ImGui.SetNextItemWidth(ctx, -380)
  local changed, new_search = ImGui.InputTextWithHint(ctx, '##search', '  Search templates...', search_buf)
  if changed then
    search_buf = new_search
    refresh_templates()
  end

  ImGui.SameLine(ctx)

  -- Save button
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)
  if ImGui.Button(ctx, '+ Save Selected Tracks', 180, 0) then
    if reaper.CountSelectedTracks(0) == 0 then
      toast.error('No tracks selected')
    else
      modal_save_open = true
      save_name_buf   = ''
      save_desc_buf   = ''
      save_tags_sel   = {}
      save_custom_buf = ''
      save_preview_buf = ''
      save_error_msg  = ''
    end
  end
  ImGui.PopStyleColor(ctx, 3)

  ImGui.SameLine(ctx)

  -- Upload button
  if not is_online then ImGui.BeginDisabled(ctx, true) end
  if ImGui.Button(ctx, '↑ Upload', 70, 0) then
    -- Find the first selected/relevant template to upload
    -- (Upload is contextual; in list view we upload the selected template)
    -- For now, toast a hint
    toast.info('Select a template and click Upload in the list')
  end
  if not is_online then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)

  -- Sync button
  if not is_online then ImGui.BeginDisabled(ctx, true) end
  local sync_label = sync.is_running() and 'Syncing...' or '↓ Sync'
  if ImGui.Button(ctx, sync_label, 70, 0) then
    if not sync.is_running() then
      sync.start(function(success, err)
        if success then
          reload_all()
          toast.success('Sync complete')
        else
          toast.error('Sync failed: ' .. (err or 'unknown'))
        end
      end)
    end
  end
  if not is_online then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)

  -- Online indicator
  local dot_col = is_online and 0x4CAF70FF or 0xE05050FF
  pcolor(dot_col)
  ImGui.Text(ctx, is_online and '● Online' or '● Offline')
  pop_color()
end

-- ============================================================
-- Draw: Template List Row
-- ============================================================

local function draw_template_row(item, cfg)
  local meta    = item.meta or {}
  local name    = meta.name or item.name or 'Unknown'
  local creator = meta.creator or ''
  local date    = format_date(meta.date_created or '')
  local uploaded = meta.uploaded or false

  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, 0x23282DFF)
  local row_id = '##row_' .. name .. '_' .. creator
  if ImGui.BeginChild(ctx, row_id, 0, 70, ImGui.ChildFlags_Borders) then

    ImGui.Spacing(ctx)
    ImGui.SetCursorPosX(ctx, 10)

    -- Template name (bold-ish via colored text)
    pcolor(0xE6E6E6FF)
    ImGui.Text(ctx, name)
    pop_color()

    -- Subtitle line
    ImGui.SetCursorPosX(ctx, 10)
    pcolor(0x808080FF)
    local subtitle = 'by ' .. (creator ~= '' and creator or 'unknown')
    if date ~= '' then subtitle = subtitle .. ' · ' .. date end
    ImGui.Text(ctx, subtitle)
    pop_color()

    -- Tags row
    ImGui.SetCursorPosX(ctx, 10)
    draw_tag_pills(meta.custom_tags, meta.predefined_tags)

    -- Plugin count badge (right side of tags)
    local plugin_count = #(meta.plugins or {})
    if plugin_count > 0 then
      pcolor(0x808080FF)
      ImGui.Text(ctx, string.format(' [%d plugins]', plugin_count))
      pop_color()
    end

    -- Right-aligned buttons
    local btn_area_w = item.is_mine and 220 or 140
    local avail_w, _ = ImGui.GetContentRegionAvail(ctx)
    -- We can't easily right-align within BeginChild; we use a fixed offset
    -- from the right edge based on window width
    -- Position buttons at right side of the row
    local child_w = 680  -- approximate row width
    ImGui.SetCursorPos(ctx, child_w - btn_area_w, 8)

    if ImGui.SmallButton(ctx, 'Insert##ins_' .. name) then
      do_insert_template(item)
    end

    ImGui.SameLine(ctx)

    if ImGui.SmallButton(ctx, 'Details##det_' .. name) then
      detail_item  = item
      current_view = VIEW_DETAIL
    end

    if item.is_mine then
      ImGui.SameLine(ctx)
      if uploaded then
        pcolor(0x7AD9C4FF)
        ImGui.Text(ctx, 'Uploaded ✓')
        pop_color()
      else
        if not is_online then ImGui.BeginDisabled(ctx, true) end
        if ImGui.SmallButton(ctx, '↑ Upload##upl_' .. name) then
          do_upload_template(item)
        end
        if not is_online then ImGui.EndDisabled(ctx) end
      end

      ImGui.SameLine(ctx)

      ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x5C2C2CFF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x7A3535FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x4A2222FF)
      if ImGui.SmallButton(ctx, 'Del##del_' .. name) then
        delete_target    = item
        modal_delete_open = true
      end
      ImGui.PopStyleColor(ctx, 3)
    end

    ImGui.EndChild(ctx)
  end
  ImGui.PopStyleColor(ctx)
  ImGui.Spacing(ctx)
end

-- ============================================================
-- Draw: List View
-- ============================================================

local function draw_list_view()
  -- Sync progress bar
  if sync.is_running() then
    pcolor(0xA0A0A0FF)
    ImGui.Text(ctx, '⟳ ' .. sync.get_progress())
    pop_color()
    ImGui.Spacing(ctx)
  end

  if #all_templates == 0 then
    ImGui.Spacing(ctx)
    pcolor(0x606060FF)
    if search_buf ~= '' then
      ImGui.Text(ctx, 'No templates match your search.')
    else
      ImGui.Text(ctx, 'No templates found. Save your first template with the button above!')
    end
    pop_color()
    return
  end

  local cfg = config.get()
  if ImGui.BeginChild(ctx, '##template_list', 0, 0) then
    for _, item in ipairs(all_templates) do
      draw_template_row(item, cfg)
    end
    ImGui.EndChild(ctx)
  end
end

-- ============================================================
-- Draw: Detail View
-- ============================================================

local function draw_detail_view()
  if not detail_item then current_view = VIEW_LIST return end

  local meta = detail_item.meta or {}
  local cfg  = config.get()

  -- Back button
  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2A2D31FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x343A40FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x3C434AFF)
  if ImGui.Button(ctx, '← Back', 80, 0) then
    current_view = VIEW_LIST
    detail_item  = nil
  end
  ImGui.PopStyleColor(ctx, 3)

  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  if ImGui.BeginChild(ctx, '##detail_scroll', 0, 0) then
    -- Title (display name prominently)
    pcolor(0xE6E6E6FF)
    ImGui.Text(ctx, (meta.name or detail_item.name or ''))
    pop_color()

    ImGui.Spacing(ctx)

    -- Creator / dates
    pcolor(0x909090FF)
    ImGui.Text(ctx, 'by ' .. (meta.creator or 'unknown'))
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, '  Created: ' .. format_date(meta.date_created or ''))
    ImGui.SameLine(ctx)
    ImGui.Text(ctx, '  Modified: ' .. format_date(meta.date_modified or ''))
    pop_color()

    ImGui.Spacing(ctx)

    -- Description
    if meta.description and meta.description ~= '' then
      ImGui.TextWrapped(ctx, meta.description)
      ImGui.Spacing(ctx)
    end

    -- Tags section
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)
    pcolor(0xA0A0A0FF)
    ImGui.Text(ctx, 'TAGS')
    pop_color()
    ImGui.Spacing(ctx)
    draw_tag_pills(meta.custom_tags, meta.predefined_tags)
    ImGui.NewLine(ctx)

    -- Plugin list
    local plugins = meta.plugins or {}
    if #plugins > 0 then
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      pcolor(0xA0A0A0FF)
      ImGui.Text(ctx, 'PLUGINS  (' .. #plugins .. ')')
      pop_color()
      ImGui.Spacing(ctx)

      for _, p in ipairs(plugins) do
        local status_col = 0x909090FF
        local status_txt = ''
        if p.installed == true then
          status_col = 0x7AD9A0FF
          status_txt = ' ✓'
        elseif p.installed == false then
          status_col = 0xFF8080FF
          status_txt = ' ⚠ MISSING'
        end

        pcolor(0xE6E6E6FF)
        ImGui.Text(ctx, '  [' .. (p.type or '?') .. ']  ' .. (p.name or ''))
        pop_color()
        if status_txt ~= '' then
          ImGui.SameLine(ctx)
          pcolor(status_col)
          ImGui.Text(ctx, status_txt)
          pop_color()
        end
      end
    end

    ImGui.Spacing(ctx)
    ImGui.Separator(ctx)
    ImGui.Spacing(ctx)

    -- Action buttons
    ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
    ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)
    if ImGui.Button(ctx, 'Insert into Project', 160, 0) then
      do_insert_template(detail_item)
    end
    ImGui.PopStyleColor(ctx, 3)

    -- Edit metadata (own only)
    local is_mine = detail_item.is_mine
    if is_mine then
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Edit Metadata', 120, 0) then
        -- Open save modal pre-filled
        modal_save_open  = true
        save_name_buf    = meta.name or ''
        save_desc_buf    = meta.description or ''
        save_tags_sel    = {}
        for _, t in ipairs(meta.predefined_tags or {}) do save_tags_sel[t] = true end
        save_custom_buf  = table.concat(meta.custom_tags or {}, ', ')
        save_preview_buf = meta.preview_image or ''
        save_error_msg   = ''
      end
    end

    -- Delete
    if is_mine or (cfg.github_username == cfg.admin_username and cfg.admin_username ~= '') then
      ImGui.SameLine(ctx)
      ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x5C2C2CFF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x7A3535FF)
      ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x4A2222FF)
      if ImGui.Button(ctx, 'Delete', 80, 0) then
        delete_target    = detail_item
        modal_delete_open = true
      end
      ImGui.PopStyleColor(ctx, 3)
    end

    ImGui.EndChild(ctx)
  end
end

-- ============================================================
-- Draw: Save Template Modal
-- ============================================================

local function draw_save_modal()
  if not modal_save_open then return end

  ImGui.OpenPopup(ctx, 'Save Template##modal')
  ImGui.SetNextWindowSize(ctx, 500, 520, ImGui.Cond_Always)
  local visible, still_open = ImGui.BeginPopupModal(ctx, 'Save Template##modal', true,
    ImGui.WindowFlags_NoResize)
  if not still_open then
    modal_save_open = false
  end
  if not visible then return end

  ImGui.Spacing(ctx)

  -- Name
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'Template Name *')
  pop_color()
  ImGui.SetNextItemWidth(ctx, -1)
  local _, new_name = ImGui.InputTextWithHint(ctx, '##save_name', 'Required', save_name_buf)
  save_name_buf = new_name

  ImGui.Spacing(ctx)

  -- Description
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'Description')
  pop_color()
  ImGui.SetNextItemWidth(ctx, -1)
  local _, new_desc = ImGui.InputTextMultiline(ctx, '##save_desc', save_desc_buf, 0, 80)
  save_desc_buf = new_desc

  ImGui.Spacing(ctx)

  -- Predefined tags
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'Tags')
  pop_color()

  local pred_tags = get_display_tags()
  local col_count = 3
  if ImGui.BeginTable(ctx, '##tag_table', col_count) then
    for _, tag in ipairs(pred_tags) do
      ImGui.TableNextColumn(ctx)
      if save_tags_sel[tag] == nil then save_tags_sel[tag] = false end
      local _, checked = ImGui.Checkbox(ctx, tag .. '##stag', save_tags_sel[tag])
      save_tags_sel[tag] = checked
    end
    ImGui.EndTable(ctx)
  end

  ImGui.Spacing(ctx)

  -- Custom tags
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'Custom Tags (comma-separated)')
  pop_color()
  ImGui.SetNextItemWidth(ctx, -1)
  local _, new_custom = ImGui.InputTextWithHint(ctx, '##save_custom', 'punchy, dark, layered',
    save_custom_buf)
  save_custom_buf = new_custom

  ImGui.Spacing(ctx)

  -- Preview image
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'Preview Image Path (optional)')
  pop_color()
  ImGui.SetNextItemWidth(ctx, -1)
  local _, new_preview = ImGui.InputTextWithHint(ctx, '##save_preview', '/path/to/image.png',
    save_preview_buf)
  save_preview_buf = new_preview

  ImGui.Spacing(ctx)

  -- Error message
  if save_error_msg ~= '' then
    pcolor(0xFF8080FF)
    ImGui.Text(ctx, save_error_msg)
    pop_color()
    ImGui.Spacing(ctx)
  end

  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  -- Buttons
  local btn_w = 90
  local sp_x, _ = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local avail_w, _ = ImGui.GetContentRegionAvail(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail_w - (btn_w * 2) - sp_x)

  if ImGui.Button(ctx, 'Cancel##sav', btn_w, 0) then
    modal_save_open = false
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.SameLine(ctx)

  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)

  local can_save = save_name_buf ~= ''
  if not can_save then ImGui.BeginDisabled(ctx, true) end

  if ImGui.Button(ctx, 'Save##sav', btn_w, 0) then
    local name = save_name_buf:match('^%s*(.-)%s*$')
    if name == '' then
      save_error_msg = 'Name is required'
    else
      -- Validate unique name
      local exists = false
      for _, t in ipairs(local_templates) do
        if t.name:lower() == name:lower() and
           not (detail_item and detail_item.name:lower() == name:lower()) then
          exists = true
          break
        end
      end
      if exists then
        save_error_msg = 'A template with that name already exists'
      else
        -- Build tag lists
        local pred_list = {}
        for tag, on in pairs(save_tags_sel) do
          if on then pred_list[#pred_list + 1] = tag end
        end
        local custom_list = {}
        for part in (save_custom_buf .. ','):gmatch('([^,]+),') do
          local t2 = part:match('^%s*(.-)%s*$')
          if t2 ~= '' then custom_list[#custom_list + 1] = t2 end
        end

        local saved = do_save_template(name, save_desc_buf, pred_list, custom_list, save_preview_buf)
        if saved then
          modal_save_open = false
          ImGui.CloseCurrentPopup(ctx)
        end
      end
    end
  end

  if not can_save then ImGui.EndDisabled(ctx) end
  ImGui.PopStyleColor(ctx, 3)

  ImGui.EndPopup(ctx)
end

-- ============================================================
-- Draw: Setup Modal (first launch)
-- ============================================================

local function draw_setup_modal()
  if not modal_setup_open then return end

  ImGui.OpenPopup(ctx, 'Welcome to ReaTemplates##setup')
  ImGui.SetNextWindowSize(ctx, 480, 380, ImGui.Cond_Always)
  local visible, still_open = ImGui.BeginPopupModal(ctx, 'Welcome to ReaTemplates##setup',
    true, ImGui.WindowFlags_NoResize)
  if not still_open then modal_setup_open = false end
  if not visible then return end

  ImGui.Spacing(ctx)
  pcolor(0x7AD9C4FF)
  ImGui.Text(ctx, 'Welcome! Let\'s connect to your GitHub template repo.')
  pop_color()
  ImGui.Spacing(ctx)
  ImGui.TextWrapped(ctx, 'Enter your GitHub username, a personal access token (PAT) with repo scope, and the repository that stores your templates.')
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  -- GitHub Username
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'GitHub Username')
  pop_color()
  ImGui.SetNextItemWidth(ctx, -1)
  local _, new_user = ImGui.InputText(ctx, '##setup_user', cfg_username_buf)
  cfg_username_buf = new_user

  ImGui.Spacing(ctx)

  -- PAT (password field)
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'Personal Access Token (PAT)')
  pop_color()
  ImGui.SetNextItemWidth(ctx, -1)
  local _, new_pat = ImGui.InputText(ctx, '##setup_pat', cfg_pat_buf,
    ImGui.InputTextFlags_Password)
  cfg_pat_buf = new_pat

  ImGui.Spacing(ctx)

  -- Repo
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'Repository (org/repo-name)')
  pop_color()
  ImGui.SetNextItemWidth(ctx, -1)
  local _, new_repo = ImGui.InputTextWithHint(ctx, '##setup_repo', 'my-org/reaper-templates',
    cfg_repo_buf)
  cfg_repo_buf = new_repo

  ImGui.Spacing(ctx)

  -- Templates folder
  pcolor(0xA0A0A0FF)
  ImGui.Text(ctx, 'Local Templates Folder')
  pop_color()
  ImGui.SetNextItemWidth(ctx, -1)
  local _, new_folder = ImGui.InputText(ctx, '##setup_folder', cfg_folder_buf)
  cfg_folder_buf = new_folder

  ImGui.Spacing(ctx)

  -- Validation message
  if cfg_validate_msg ~= '' then
    local col = cfg_validate_msg:find('^✓') and 0x7AD9A0FF or 0xFF8080FF
    pcolor(col)
    ImGui.Text(ctx, cfg_validate_msg)
    pop_color()
    ImGui.Spacing(ctx)
  end

  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  local can_validate = cfg_username_buf ~= '' and cfg_pat_buf ~= '' and cfg_repo_buf ~= ''
  if not can_validate then ImGui.BeginDisabled(ctx, true) end

  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)

  if ImGui.Button(ctx, 'Save & Validate', 160, 0) then
    -- Save config first with new PAT so github module can use it
    local cfg = config.get()
    cfg.github_username  = cfg_username_buf
    cfg.github_pat       = config.obfuscate_pat(cfg_pat_buf)
    cfg.github_repo      = cfg_repo_buf
    cfg.templates_folder = cfg_folder_buf
    config.save(cfg)

    -- Validate PAT
    local ok, user_or_err = github.validate_pat()
    if ok then
      cfg_validate_msg  = '✓ Connected as ' .. tostring(user_or_err)
      modal_setup_open  = false
      ImGui.CloseCurrentPopup(ctx)
      toast.success('Setup complete! Welcome, ' .. tostring(user_or_err))
      reload_all()
    else
      cfg_validate_msg = '✗ ' .. tostring(user_or_err)
    end
  end

  ImGui.PopStyleColor(ctx, 3)
  if not can_validate then ImGui.EndDisabled(ctx) end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, 'Skip for now', 110, 0) then
    modal_setup_open = false
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.EndPopup(ctx)
end

-- ============================================================
-- Draw: Settings Modal
-- ============================================================

local function draw_settings_modal()
  if not modal_settings_open then return end

  ImGui.OpenPopup(ctx, 'Settings##modal')
  ImGui.SetNextWindowSize(ctx, 520, 480, ImGui.Cond_Always)
  local visible, still_open = ImGui.BeginPopupModal(ctx, 'Settings##modal', true,
    ImGui.WindowFlags_NoResize)
  if not still_open then modal_settings_open = false end
  if not visible then
    return
  end

  local cfg = config.get()
  local is_admin = cfg.admin_username ~= '' and cfg.github_username == cfg.admin_username

  -- Tab bar
  if ImGui.BeginTabBar(ctx, '##settings_tabs') then

    -- General tab
    if ImGui.BeginTabItem(ctx, 'General##tab') then
      ImGui.Spacing(ctx)

      pcolor(0xA0A0A0FF)
      ImGui.Text(ctx, 'GitHub Username')
      pop_color()
      ImGui.SetNextItemWidth(ctx, -1)
      local _, v = ImGui.InputText(ctx, '##s_user', cfg_username_buf)
      cfg_username_buf = v

      ImGui.Spacing(ctx)
      pcolor(0xA0A0A0FF)
      ImGui.Text(ctx, 'Personal Access Token (leave blank to keep current)')
      pop_color()
      ImGui.SetNextItemWidth(ctx, -1)
      local _, v2 = ImGui.InputText(ctx, '##s_pat', cfg_pat_buf, ImGui.InputTextFlags_Password)
      cfg_pat_buf = v2

      ImGui.Spacing(ctx)
      pcolor(0xA0A0A0FF)
      ImGui.Text(ctx, 'Repository (org/repo-name)')
      pop_color()
      ImGui.SetNextItemWidth(ctx, -1)
      local _, v3 = ImGui.InputText(ctx, '##s_repo', cfg_repo_buf)
      cfg_repo_buf = v3

      ImGui.Spacing(ctx)
      pcolor(0xA0A0A0FF)
      ImGui.Text(ctx, 'Local Templates Folder')
      pop_color()
      ImGui.SetNextItemWidth(ctx, -1)
      local _, v4 = ImGui.InputText(ctx, '##s_folder', cfg_folder_buf)
      cfg_folder_buf = v4

      ImGui.Spacing(ctx)

      if cfg_validate_msg ~= '' then
        local col = cfg_validate_msg:find('^✓') and 0x7AD9A0FF or 0xFF8080FF
        pcolor(col)
        ImGui.Text(ctx, cfg_validate_msg)
        pop_color()
        ImGui.Spacing(ctx)
      end

      if ImGui.Button(ctx, 'Validate PAT', 120, 0) then
        -- Temporarily save
        cfg.github_username  = cfg_username_buf
        cfg.github_repo      = cfg_repo_buf
        cfg.templates_folder = cfg_folder_buf
        if cfg_pat_buf ~= '' then
          cfg.github_pat = config.obfuscate_pat(cfg_pat_buf)
        end
        config.save(cfg)

        local ok, user_or_err = github.validate_pat()
        cfg_validate_msg = ok and ('✓ Connected as ' .. tostring(user_or_err))
                                or ('✗ ' .. tostring(user_or_err))
      end

      ImGui.EndTabItem(ctx)
    end

    -- Admin tab (only visible for admin user)
    if is_admin and ImGui.BeginTabItem(ctx, 'Admin##tab') then
      ImGui.Spacing(ctx)
      pcolor(0xE0A030FF)
      ImGui.Text(ctx, 'Admin Controls')
      pop_color()
      ImGui.Spacing(ctx)

      pcolor(0xA0A0A0FF)
      ImGui.Text(ctx, 'Predefined Tags (one per line)')
      pop_color()
      ImGui.SetNextItemWidth(ctx, -1)
      local _, v5 = ImGui.InputTextMultiline(ctx, '##admin_tags', admin_tags_buf, 0, 120)
      admin_tags_buf = v5

      ImGui.Spacing(ctx)

      if is_online then
        if ImGui.Button(ctx, 'Push Tags to GitHub', 160, 0) then
          local tags_list = {}
          for line in (admin_tags_buf .. '\n'):gmatch('([^\n]+)\n') do
            local t2 = line:match('^%s*(.-)%s*$')
            if t2 ~= '' then tags_list[#tags_list + 1] = t2 end
          end
          local _, err = github.update_tags({ predefined_tags = tags_list })
          if err then
            toast.error('Tags update failed: ' .. err)
          else
            cfg.predefined_tags = tags_list
            config.save(cfg)
            toast.success('Tags updated')
            tag_filters = {}  -- Reset filters
          end
        end
      else
        ImGui.BeginDisabled(ctx, true)
        ImGui.Button(ctx, 'Push Tags to GitHub (offline)', 200, 0)
        ImGui.EndDisabled(ctx)
      end

      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)

      pcolor(0xA0A0A0FF)
      ImGui.Text(ctx, 'Community Templates')
      pop_color()
      ImGui.Spacing(ctx)

      -- List all community templates with delete buttons
      for _, meta in ipairs(community_templates) do
        ImGui.Text(ctx, (meta.creator or '?') .. ' / ' .. (meta.name or '?'))
        ImGui.SameLine(ctx)
        ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x5C2C2CFF)
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x7A3535FF)
        ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x4A2222FF)
        if ImGui.SmallButton(ctx, 'Delete##admdel_' .. (meta.creator or '') .. meta.name) then
          if is_online then
            local _, err = github.admin_delete_template(meta.creator or '', meta.name)
            if err then
              toast.error('Delete failed: ' .. err)
            else
              metadata.clear_cache()
              reload_all()
              toast.success('Deleted from GitHub')
            end
          else
            toast.error('Cannot delete while offline')
          end
        end
        ImGui.PopStyleColor(ctx, 3)
      end

      ImGui.EndTabItem(ctx)
    end

    ImGui.EndTabBar(ctx)
  end

  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  -- Save / Close buttons
  local btn_w = 90
  local sp_x, _ = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
  local avail_w, _ = ImGui.GetContentRegionAvail(ctx)
  ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail_w - (btn_w * 2) - sp_x)

  if ImGui.Button(ctx, 'Close##set', btn_w, 0) then
    modal_settings_open = false
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.SameLine(ctx)

  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x2C6B64FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x338077FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x2A5C56FF)

  if ImGui.Button(ctx, 'Save##set', btn_w, 0) then
    local cfg2 = config.get()
    cfg2.github_username  = cfg_username_buf
    cfg2.github_repo      = cfg_repo_buf
    cfg2.templates_folder = cfg_folder_buf
    if cfg_pat_buf ~= '' then
      cfg2.github_pat = config.obfuscate_pat(cfg_pat_buf)
    end
    config.save(cfg2)
    modal_settings_open = false
    ImGui.CloseCurrentPopup(ctx)
    toast.success('Settings saved')
    reload_all()
  end

  ImGui.PopStyleColor(ctx, 3)

  ImGui.EndPopup(ctx)
end

-- ============================================================
-- Draw: Delete Confirmation Modal
-- ============================================================

local function draw_delete_modal()
  if not modal_delete_open or not delete_target then return end

  ImGui.OpenPopup(ctx, 'Confirm Delete##del')
  ImGui.SetNextWindowSize(ctx, 360, 160, ImGui.Cond_Always)
  local visible, still_open = ImGui.BeginPopupModal(ctx, 'Confirm Delete##del', true,
    ImGui.WindowFlags_NoResize)
  if not still_open then modal_delete_open = false end
  if not visible then return end

  ImGui.Spacing(ctx)
  ImGui.TextWrapped(ctx, 'Are you sure you want to delete "' .. (delete_target.name or '') .. '"?\nThis cannot be undone.')
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Spacing(ctx)

  if ImGui.Button(ctx, 'Cancel', 80, 0) then
    modal_delete_open = false
    delete_target     = nil
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.SameLine(ctx)

  ImGui.PushStyleColor(ctx, ImGui.Col_Button,        0x6B2C2CFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, 0x8A3535FF)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive,  0x5A2222FF)
  if ImGui.Button(ctx, 'Delete', 80, 0) then
    do_delete_local(delete_target)
    if current_view == VIEW_DETAIL then
      current_view = VIEW_LIST
      detail_item  = nil
    end
    modal_delete_open = false
    delete_target     = nil
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.PopStyleColor(ctx, 3)

  ImGui.EndPopup(ctx)
end

-- ============================================================
-- Main render loop
-- ============================================================

function M.render()
  -- Tick sync coroutine
  if sync.is_running() then
    sync.step()
  end

  -- Expire old toasts
  toast.tick()

  -- Apply theme
  local color_count, var_count = theme.Push(ctx)

  -- Main window
  ImGui.SetNextWindowSize(ctx, WIN_W, WIN_H, ImGui.Cond_FirstUseEver)
  local visible, still_open = ImGui.Begin(ctx, 'ReaTemplates', true, WIN_FLAGS)

  if visible then
    -- Get window position and size for toasts
    local wx, wy  = ImGui.GetWindowPos(ctx)
    local ww, wh  = ImGui.GetWindowSize(ctx)

    -- 2-column layout
    draw_side_panel()
    ImGui.SameLine(ctx)

    -- Main content area
    if ImGui.BeginChild(ctx, '##main_area', 0, 0) then
      draw_toolbar()
      ImGui.Spacing(ctx)
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)

      if current_view == VIEW_DETAIL then
        draw_detail_view()
      else
        draw_list_view()
      end

      ImGui.EndChild(ctx)
    end

    -- Modals
    draw_save_modal()
    draw_setup_modal()
    draw_settings_modal()
    draw_delete_modal()

    -- Toasts (drawn last, on top)
    toast.draw(ImGui, ctx, wx, wy, ww, wh)
  end
  ImGui.End(ctx)

  theme.Pop(ctx, color_count, var_count)

  if still_open and open then
    return true
  else
    open = false
    return false
  end
end

-- ============================================================
-- Module initialiser
-- ============================================================

function M.init(imgui, context, theme_mod, json_mod, config_mod, metadata_mod,
                github_mod, sync_mod, plugin_detect_mod, toast_mod)
  ImGui        = imgui
  ctx          = context
  theme        = theme_mod
  json         = json_mod
  config       = config_mod
  metadata     = metadata_mod
  github       = github_mod
  sync         = sync_mod
  plugin_detect = plugin_detect_mod
  toast        = toast_mod

  WIN_FLAGS = ImGui.WindowFlags_NoScrollbar
            | ImGui.WindowFlags_NoCollapse
            | ImGui.WindowFlags_NoScrollWithMouse

  -- Load templates
  reload_all()

  -- Show setup modal on first launch
  if config.is_first_launch() then
    modal_setup_open = true
    local cfg = config.get()
    cfg_username_buf = cfg.github_username or ''
    cfg_pat_buf      = ''
    cfg_repo_buf     = cfg.github_repo or ''
    cfg_folder_buf   = cfg.templates_folder or ''
    cfg_validate_msg = ''
  end
end

-- Allow main to set online status after the initial check
function M.set_online(flag)
  is_online = flag
end

return M
