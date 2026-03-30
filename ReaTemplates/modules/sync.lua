-- ============================================================
-- sync.lua  –  Background sync coroutine
-- Fetches community metadata from GitHub and writes to local cache.
-- Uses reaper.defer() to resume a coroutine each frame so the UI
-- stays responsive during potentially slow HTTP operations.
-- ============================================================

local M = {}

local github  = nil
local metadata = nil
local config  = nil
local toast   = nil

-- ============================================================
-- Sync state
-- ============================================================

local sync_co        = nil  -- active coroutine (or nil)
local sync_running   = false
local sync_progress  = ''   -- human-readable status for display
local sync_error     = nil  -- last error string (or nil)
local on_complete_cb = nil  -- callback(success, err) when sync finishes

-- Public read-only accessors
function M.is_running()  return sync_running end
function M.get_progress() return sync_progress end
function M.get_error()   return sync_error end

-- ============================================================
-- Coroutine body
-- ============================================================

local function sync_body()
  sync_error = nil

  -- Step 1: fetch tags from GitHub
  sync_progress = 'Fetching tags...'
  coroutine.yield()

  local tags, tags_err = github.fetch_tags()
  if tags_err then
    -- Non-fatal: use defaults
    tags = { predefined_tags = { 'Drums', 'Bass', 'Keys', 'Guitar', 'Vocals', 'Bus', 'FX', 'Synth', 'Strings', 'Brass' } }
  end

  -- Merge predefined tags into config
  local cfg = config.get()
  cfg.predefined_tags = tags.predefined_tags or cfg.predefined_tags or {}

  -- Step 1b: fetch and merge user's personal tag list
  sync_progress = 'Fetching your tag preferences...'
  coroutine.yield()

  local username = cfg.github_username or ''
  local user_data, _ = github.fetch_user_tags(username)
  local user_list = (user_data and type(user_data.ordered_tags) == 'table' and user_data.ordered_tags) or {}

  if #user_list == 0 then
    -- First time: seed from the full predefined list
    for _, t in ipairs(cfg.predefined_tags) do
      user_list[#user_list + 1] = t
    end
  else
    -- Append any predefined tags the admin added since last sync
    local existing = {}
    for _, t in ipairs(user_list) do existing[t] = true end
    for _, t in ipairs(cfg.predefined_tags) do
      if not existing[t] then user_list[#user_list + 1] = t end
    end
  end

  cfg.user_tags = user_list
  config.save(cfg)

  -- Step 2: list all creators
  sync_progress = 'Listing community templates...'
  coroutine.yield()

  local creators, creators_err = github.list_creators()
  if creators_err then
    sync_error = 'Failed to list creators: ' .. creators_err
    return
  end

  local my_username = cfg.github_username or ''

  -- Step 3: for each creator, fetch their templates
  for ci, creator in ipairs(creators or {}) do
    sync_progress = string.format('Fetching templates (%d/%d): %s', ci, #(creators or {}), creator)
    coroutine.yield()

    local templates, t_err = github.list_templates_for(creator)
    if not t_err and templates then
      for _, tname in ipairs(templates) do
        sync_progress = string.format('Fetching meta: %s / %s', creator, tname)
        coroutine.yield()

        local meta, m_err = github.fetch_meta(creator, tname)
        if not m_err and meta then
          -- Write to cache
          meta.creator = meta.creator or creator
          metadata.write_cache(meta)
        end
      end
    end
  end

  -- Step 4: update last_sync timestamp
  cfg = config.get()
  cfg.last_sync = os.date('!%Y-%m-%dT%H:%M:%SZ')
  config.save(cfg)

  sync_progress = 'Sync complete.'
  coroutine.yield()
end

-- ============================================================
-- Start sync
-- ============================================================

function M.start(on_complete)
  if sync_running then return end

  on_complete_cb = on_complete
  sync_running   = true
  sync_progress  = 'Starting sync...'
  sync_error     = nil

  sync_co = coroutine.create(sync_body)
end

-- ============================================================
-- Step — call this every frame from the defer loop
-- Returns true while still running, false when finished.
-- ============================================================

function M.step()
  if not sync_running or not sync_co then return false end

  local ok, err = coroutine.resume(sync_co)

  if not ok then
    sync_error   = 'Sync error: ' .. tostring(err)
    sync_running = false
    sync_co      = nil
    if on_complete_cb then pcall(on_complete_cb, false, sync_error) end
    return false
  end

  if coroutine.status(sync_co) == 'dead' then
    sync_running = false
    sync_co      = nil
    if on_complete_cb then pcall(on_complete_cb, sync_error == nil, sync_error) end
    return false
  end

  return true
end

-- ============================================================
-- Cancel a running sync
-- ============================================================

function M.cancel()
  sync_running = false
  sync_co      = nil
  sync_progress = 'Sync cancelled.'
end

-- ============================================================
-- Module initialiser
-- ============================================================

function M.init(github_mod, metadata_mod, config_mod, toast_mod)
  github   = github_mod
  metadata = metadata_mod
  config   = config_mod
  toast    = toast_mod
end

return M
