-- @description Edit Cursor Follows Envelope Drawing
-- @author Stephen Schappler
-- @version 1.0
-- @about
--   A toggle that will force the edit cursor to follow when drawing envelopes. Good for having the video follow envelope drawing.
-- @link https://www.stephenschappler.com
-- @changelog 
--   07/15/26 v1.0 - Adding the script

-- When an envelope or a point aren't selected the edit cursor and the playhead (if SEEK is enabled) don't follow the mouse cursor

SEEK = " " -- insert any QWERTY alphanumeric character to have playhead follow mouse cursor when playback is ON

function RUN()
selected = nil
local env = reaper.GetSelectedEnvelope(0)
  if env then
    for i = 0, reaper.CountEnvelopePoints(env)-1 do
    retval, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, i) 
      if selected then sel = 1 break end
    end
    if selected then
    reaper.Main_OnCommand(40514,0) -- View: Move edit cursor to mouse cursor (no snapping)
      if SEEK then
      local play = reaper.GetPlayStateEx(0)&1 == 1 and reaper.CSurf_OnPlay() -- only seek if already playing and don't start playback otherwise      
      end
    end
  end
reaper.defer(RUN)
end


SEEK = #SEEK:gsub(' ','') > 0

RUN()
