-- ============================================================
-- toast.lua  –  Toast notification queue
-- Toasts appear in the bottom-right of the main window.
-- Auto-dismiss after 3 seconds.
-- Types: "info", "success", "error", "warning"
-- ============================================================

local M = {}

-- ============================================================
-- State
-- ============================================================

local queue = {}   -- list of {msg, type, expire_time}

local TOAST_DURATION = 3.0  -- seconds
local MAX_TOASTS     = 5

-- Colors per type (RGBA hex)
local TYPE_COLORS = {
  info    = { bg = 0x3A3F45F0, border = 0x5A6771FF, text = 0xE6E6E6FF },
  success = { bg = 0x1E3D2AF0, border = 0x4CAF70FF, text = 0x7AD9A0FF },
  error   = { bg = 0x3D1E1EF0, border = 0xE05050FF, text = 0xFF8080FF },
  warning = { bg = 0x3D3520F0, border = 0xE0C050FF, text = 0xFFE080FF },
}

-- ============================================================
-- Public API
-- ============================================================

-- Add a toast to the queue
-- msg:  string
-- kind: "info" | "success" | "error" | "warning"  (default "info")
function M.push(msg, kind)
  kind = kind or 'info'
  if TYPE_COLORS[kind] == nil then kind = 'info' end

  -- Cap the queue
  while #queue >= MAX_TOASTS do
    table.remove(queue, 1)
  end

  queue[#queue + 1] = {
    msg         = msg,
    kind        = kind,
    expire_time = reaper.time_precise() + TOAST_DURATION,
  }
end

-- Convenience wrappers
function M.info(msg)    M.push(msg, 'info')    end
function M.success(msg) M.push(msg, 'success') end
function M.error(msg)   M.push(msg, 'error')   end
function M.warning(msg) M.push(msg, 'warning') end

-- Expire old toasts (call each frame before drawing)
function M.tick()
  local now = reaper.time_precise()
  local i = 1
  while i <= #queue do
    if queue[i].expire_time <= now then
      table.remove(queue, i)
    else
      i = i + 1
    end
  end
end

-- Draw all active toasts
-- Must be called inside an ImGui Begin/End block.
-- win_x, win_y, win_w, win_h: the main window position/size
function M.draw(ImGui, ctx, win_x, win_y, win_w, win_h)
  if #queue == 0 then return end

  local TOAST_W    = 280
  local TOAST_H    = 44
  local TOAST_PAD  = 8
  local MARGIN     = 12

  local draw_list = ImGui.GetWindowDrawList(ctx)

  for i = #queue, 1, -1 do
    local t = queue[i]
    local cols = TYPE_COLORS[t.kind] or TYPE_COLORS.info

    local idx  = #queue - i   -- 0 = bottom-most visible
    local tx   = win_x + win_w - TOAST_W - MARGIN
    local ty   = win_y + win_h - MARGIN - (idx + 1) * (TOAST_H + TOAST_PAD)

    -- Background
    ImGui.DrawList_AddRectFilled(draw_list,
      tx, ty, tx + TOAST_W, ty + TOAST_H,
      cols.bg, 6)

    -- Border
    ImGui.DrawList_AddRect(draw_list,
      tx, ty, tx + TOAST_W, ty + TOAST_H,
      cols.border, 6)

    -- Text
    local text_x = tx + 10
    local text_y = ty + (TOAST_H - 13) / 2
    ImGui.DrawList_AddText(draw_list, text_x, text_y, cols.text, t.msg)

    -- Fade bar at bottom (time remaining)
    local now       = reaper.time_precise()
    local remaining = t.expire_time - now
    local frac      = math.max(0, math.min(1, remaining / TOAST_DURATION))
    local bar_w     = math.floor((TOAST_W - 4) * frac)
    if bar_w > 0 then
      ImGui.DrawList_AddRectFilled(draw_list,
        tx + 2, ty + TOAST_H - 4,
        tx + 2 + bar_w, ty + TOAST_H - 2,
        cols.border, 2)
    end
  end
end

-- Return the number of active toasts
function M.count() return #queue end

return M
