-- @noindex
-- Shared video RENDER_FORMAT blob encoder for Video/Export Time Selection as
-- Video (GUI).lua.
--
-- REAPER stores the render dialog's per-format settings as an opaque binary
-- blob (base64-encoded when read/written via GetSetProjectInfo_String's
-- RENDER_FORMAT key, and stored the same way in reaper-render.ini). There is
-- no documented ReaScript API for setting "H.264 2048kbps" directly -- this
-- module hand-encodes that blob.
--
-- Byte layout is per Ultraschall's RENDER_How_RenderCFG-Base64-strings_are_
-- encoded.txt (misc_docs in ultraschall-lua-api-for-reaper). The AVF, PMFF,
-- GIF and LCF layouts were checked byte-for-byte against blobs saved by
-- REAPER 7.80's own Render to File dialog. Ultraschall's codec id lists
-- predate REAPER 7 and were wrong, so the ids in the tables below come from
-- REAPER itself (see that section's header).

local VideoRenderFormat = {}

-- ============================================================
-- Byte-packing helpers
-- ============================================================
local function u32_le(n)
  return string.pack("<I4", math.floor(n + 0.5))
end

local function f32_le(n)
  return string.pack("<f", n)
end

-- ============================================================
-- Base64 encode (REAPER's Lua has no built-in -- existing scripts in this
-- repo only ever used *precomputed* base64 constants for audio formats,
-- since bit-depth is a small fixed set; video's user-editable width/
-- height/bitrate/etc. requires real runtime encoding).
-- ============================================================
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function VideoRenderFormat.base64_encode(data)
  local out = {}
  local len = #data
  local i = 1
  while i <= len do
    local b1, b2, b3 = data:byte(i, i + 2)
    b2 = b2 or 0
    b3 = b3 or 0
    local n = (b1 << 16) | (b2 << 8) | b3

    local c1 = (n >> 18) & 0x3F
    local c2 = (n >> 12) & 0x3F
    local c3 = (n >> 6) & 0x3F
    local c4 = n & 0x3F

    local chunk_len = math.min(3, len - i + 1)
    out[#out + 1] = B64_CHARS:sub(c1 + 1, c1 + 1)
    out[#out + 1] = B64_CHARS:sub(c2 + 1, c2 + 1)
    out[#out + 1] = (chunk_len >= 2) and B64_CHARS:sub(c3 + 1, c3 + 1) or "="
    out[#out + 1] = (chunk_len >= 3) and B64_CHARS:sub(c4 + 1, c4 + 1) or "="

    i = i + 3
  end
  return table.concat(out)
end

-- ============================================================
-- Format/codec option tables.
--
-- Container entries: {id, label, ext}. Video codec entries: {id, label,
-- rate_mode}, where rate_mode is "bitrate" (kbps field), "quality" (% field)
-- or nil (no rate control). Audio codec entries: {id, label, bitrate}, where
-- bitrate = true means the codec has a kbps field.
--
-- Every id below is the value REAPER itself writes into the blob. They were
-- checked against REAPER 7.80: the FFmpeg tables were read from
-- reaper_video.dylib's own container/codec arrays, and the AVF, FFmpeg, GIF
-- and LCF ids were confirmed by choosing each option in the Render to File
-- dialog and decoding the RENDER_FORMAT it saved. Ids are stable per codec,
-- not list positions (e.g. MJPEG is 3 in AVI but 4 in MKV), and REAPER hides
-- codecs whose encoder the loaded FFmpeg build lacks.
-- ============================================================

local IS_WIN = reaper.GetOS():find("Win") ~= nil
VideoRenderFormat.IS_WIN = IS_WIN
VideoRenderFormat.IS_MAC = reaper.GetOS():find("OSX") ~= nil or reaper.GetOS():find("macOS") ~= nil

-- ---------- AVFoundation (macOS only) ----------
VideoRenderFormat.AVF_CONTAINERS = {
  { id = 0, label = "MPEG-4 Video (streaming optimized)", ext = ".mp4" },
  { id = 1, label = "MPEG-4 Video",                       ext = ".mp4" },
  { id = 2, label = "Quicktime MOV",                      ext = ".mov" },
  { id = 3, label = "MPEG-4 Audio (no video)",            ext = ".m4a", audio_only = true },
}

VideoRenderFormat.AVF_VIDEO_CODECS = {
  [2] = {
    { id = 0, label = "H.264",            rate_mode = "bitrate" },
    { id = 1, label = "Apple ProRes 4444" },
    { id = 2, label = "Apple ProRes 422" },
    { id = 3, label = "MJPEG",            rate_mode = "quality" },
  },
  DEFAULT = {
    { id = 0, label = "H.264", rate_mode = "bitrate" },
  },
}

VideoRenderFormat.AVF_AUDIO_CODECS = {
  [2] = {
    { id = 0, label = "AAC", bitrate = true },
    { id = 1, label = "16-bit PCM" },
    { id = 2, label = "24-bit PCM" },
    { id = 3, label = "32-bit FP PCM" },
    { id = 4, label = "None", is_none = true },
  },
  [3] = {
    { id = 0, label = "AAC", bitrate = true },
  },
  DEFAULT = {
    { id = 0, label = "AAC", bitrate = true },
    { id = 1, label = "None", is_none = true },
  },
}

-- ---------- FFmpeg/libav ----------
-- Container 3 ("QT/MOV/MP4 (deprecated)") is left out: REAPER 7 replaced it
-- with MPEG-4 (7) and MOV (8) and only shows it for old settings.
-- migrate_template maps old templates onto container 7.
-- mac_bundled marks the containers REAPER's own macOS FFmpeg build can write
-- (it lacks the MP4, MPEG-TS, FLV and WebM muxers).
VideoRenderFormat.FFMPEG_CONTAINERS = {
  { id = 7, label = "MPEG-4", ext = ".mp4" },
  { id = 8, label = "MOV",    ext = ".mov", mac_bundled = true },
  { id = 4, label = "MKV",    ext = ".mkv", mac_bundled = true },
  { id = 0, label = "AVI",    ext = ".avi", mac_bundled = true },
  { id = 6, label = "WEBM",   ext = ".webm" },
  { id = 5, label = "FLV",    ext = ".flv" },
  { id = 1, label = "MPEG-1", ext = ".mpg", mac_bundled = true },
  { id = 2, label = "MPEG-2", ext = ".mpg" },
}

local V_H264  = { label = "H.264",             rate_mode = "bitrate" }
local V_H265  = { label = "H.265",             rate_mode = "bitrate" }
local V_AV1   = { label = "AV1",               rate_mode = "bitrate" }
local V_MPEG1 = { label = "MPEG-1",            rate_mode = "bitrate", mac_bundled = true }
local V_MPEG2 = { label = "MPEG-2",            rate_mode = "bitrate" }
local V_XVID  = { label = "XviD",              rate_mode = "bitrate" }
local V_FLV1  = { label = "FLV1",              rate_mode = "bitrate" }
local V_VP8   = { label = "VP8",               rate_mode = "bitrate" }
local V_VP9   = { label = "VP9",               rate_mode = "bitrate" }
local V_MJPEG = { label = "MJPEG",             rate_mode = "quality", mac_bundled = true }
local V_DV    = { label = "DV",                mac_bundled = true }
local V_FFV1  = { label = "FFV1 (lossless)",   mac_bundled = true }
local V_HUFF  = { label = "Huffyuv (lossless)", mac_bundled = true }
local V_NONE  = { label = "None",              mac_bundled = true, is_none = true }

local A_AAC   = { label = "AAC",        bitrate = true }
local A_MP3   = { label = "MP3",        bitrate = true }
local A_MP2   = { label = "MP2",        bitrate = true }
local A_AC3   = { label = "AC3",        bitrate = true }
local A_VORB  = { label = "Vorbis",     bitrate = true }
local A_OPUS  = { label = "Opus",       bitrate = true }
local A_DV    = { label = "DV Audio" }
local A_PCM16 = { label = "16-bit PCM", mac_bundled = true }
local A_PCM24 = { label = "24-bit PCM", mac_bundled = true }
local A_FP32  = { label = "32-bit FP",  mac_bundled = true }
local A_NONE  = { label = "None",       mac_bundled = true, is_none = true }

-- Builds an id-tagged list from positional codec templates: the position
-- (0-based) is REAPER's id for that codec within this container.
local function ids(list)
  local out = {}
  for i, c in ipairs(list) do
    local e = { id = i - 1 }
    for k, v in pairs(c) do e[k] = v end
    out[#out + 1] = e
  end
  return out
end

VideoRenderFormat.FFMPEG_VIDEO_CODECS = {
  [0] = ids{ V_XVID, V_H264, V_DV, V_MJPEG, V_FFV1, V_HUFF, V_MPEG2, V_NONE },   -- AVI
  [1] = ids{ V_MPEG1, V_NONE },                                                 -- MPEG-1
  [2] = ids{ V_MPEG2, V_NONE },                                                 -- MPEG-2
  [3] = ids{ V_H264, V_MPEG2, V_MJPEG, V_NONE },                                -- QT/MOV/MP4 (deprecated)
  [4] = ids{ V_H264, V_XVID, V_FFV1, V_HUFF, V_MJPEG, V_MPEG2, V_NONE, V_H265, V_AV1 }, -- MKV
  [5] = ids{ V_H264, V_FLV1, V_NONE },                                          -- FLV
  [6] = ids{ V_VP8, V_VP9, V_AV1, V_NONE },                                     -- WEBM
  [7] = ids{ V_H264, V_H265, V_AV1, V_MPEG2, V_MJPEG, V_NONE },                 -- MPEG-4
  [8] = ids{ V_H264, V_H265, V_AV1, V_MPEG2, V_MJPEG, V_NONE },                 -- MOV
}

VideoRenderFormat.FFMPEG_AUDIO_CODECS = {
  [0] = ids{ A_MP3, A_AAC, A_AC3, A_PCM16, A_PCM24, A_FP32, A_DV, A_NONE },     -- AVI
  [1] = ids{ A_MP3, A_MP2, A_NONE },                                            -- MPEG-1
  [2] = ids{ A_AAC, A_MP3, A_MP2, A_NONE },                                     -- MPEG-2
  [3] = ids{ A_AAC, A_MP3, A_PCM16, A_PCM24, A_FP32, A_NONE },                  -- QT/MOV/MP4 (deprecated)
  [4] = ids{ A_MP3, A_AAC, A_PCM16, A_PCM24, A_FP32, A_NONE },                  -- MKV
  [5] = ids{ A_MP3, A_AAC, A_NONE },                                            -- FLV
  [6] = ids{ A_VORB, A_OPUS, A_NONE },                                          -- WEBM
  [7] = ids{ A_AAC, A_MP3, A_PCM16, A_PCM24, A_FP32, A_NONE },                  -- MPEG-4
  [8] = ids{ A_AAC, A_MP3, A_PCM16, A_PCM24, A_FP32, A_NONE },                  -- MOV
}

-- On macOS REAPER ships its own minimal FFmpeg build (Plugins/FFmpeg.dylib).
-- It has no H.264/H.265/AV1/VP8/VP9/XviD/MPEG-2 encoders and no AAC/MP3/
-- MP2/AC3/Vorbis/Opus (nor MP4/MPEG-TS/FLV/WebM muxers), so REAPER's
-- dialog hides those, and a blob asking
-- for one fails with "Error initializing video encoder". H.264 MP4/MOV on
-- macOS comes from AVFoundation instead. On Windows REAPER has no bundled
-- FFmpeg; it uses whatever full FFmpeg build the user installed, so the
-- full lists apply.
local function available(entry)
  return IS_WIN or entry.mac_bundled
end

local function filter(list)
  if not list then return nil end
  local out = {}
  for _, e in ipairs(list) do
    if available(e) then out[#out + 1] = e end
  end
  return out
end

function VideoRenderFormat.ffmpeg_containers()
  return filter(VideoRenderFormat.FFMPEG_CONTAINERS)
end

function VideoRenderFormat.ffmpeg_video_codecs(container)
  return filter(VideoRenderFormat.FFMPEG_VIDEO_CODECS[container])
end

function VideoRenderFormat.ffmpeg_audio_codecs(container)
  return filter(VideoRenderFormat.FFMPEG_AUDIO_CODECS[container])
end

-- ---------- Windows Media Foundation (Windows only) ----------
-- WMF renders through Windows' own built-in Media Foundation H.264 encoder,
-- so it gives real H.264 on a stock Windows install with no FFmpeg DLLs.
-- Containers 1 and 3 are audio-only.
VideoRenderFormat.WMF_CONTAINERS = {
  { id = 0, label = "MPEG-4 Video",            ext = ".mp4" },
  { id = 1, label = "MPEG-4 Audio (no video)", ext = ".m4a", audio_only = true },
  { id = 2, label = "WMV Video",               ext = ".wmv" },
  { id = 3, label = "WMA Audio (no video)",    ext = ".wma", audio_only = true },
}

VideoRenderFormat.WMF_VIDEO_CODECS = {
  DEFAULT = {
    { id = 0, label = "H.264", rate_mode = "bitrate" },
  },
}

VideoRenderFormat.WMF_AUDIO_CODECS = {
  DEFAULT = {
    { id = 0, label = "AAC", bitrate = true },
    { id = 2, label = "None", is_none = true },
  },
}

-- ---------- Top-level formats, per platform ----------
local ALL_FORMATS = {
  { id = "avf",    label = "AVFoundation (MPEG-4, MOV)",            mac_only = true },
  { id = "wmf",    label = "Windows Media Encoder (MPEG-4, WMV)",   win_only = true },
  { id = "ffmpeg", label = "FFmpeg/libav (video, compressed audio)" },
  { id = "gif",    label = "GIF (video only)" },
  { id = "lcf",    label = "LCF (video only)" },
}

VideoRenderFormat.FORMATS = {}
for _, f in ipairs(ALL_FORMATS) do
  if not (f.mac_only and IS_WIN) and not (f.win_only and not IS_WIN) then
    VideoRenderFormat.FORMATS[#VideoRenderFormat.FORMATS + 1] = f
  end
end

-- Platform default: H.264 MP4 with AAC audio, using the encoder that works
-- out of the box (AVFoundation on macOS, Media Foundation on Windows).
if IS_WIN then
  VideoRenderFormat.DEFAULT_FORMAT = { format_id = "wmf", container = 0, video_codec = 0, audio_codec = 0 }
else
  VideoRenderFormat.DEFAULT_FORMAT = { format_id = "avf", container = 1, video_codec = 0, audio_codec = 0 }
end

-- ---------- Lookups used by the GUI ----------
function VideoRenderFormat.containers_for(format_id)
  if format_id == "avf"    then return VideoRenderFormat.AVF_CONTAINERS end
  if format_id == "ffmpeg" then return VideoRenderFormat.ffmpeg_containers() end
  if format_id == "wmf"    then return VideoRenderFormat.WMF_CONTAINERS end
  return nil
end

local function raw_video_codecs(format_id, container)
  local VF = VideoRenderFormat
  if format_id == "avf"    then return VF.AVF_VIDEO_CODECS[container] or VF.AVF_VIDEO_CODECS.DEFAULT end
  if format_id == "ffmpeg" then return VF.ffmpeg_video_codecs(container) end
  if format_id == "wmf"    then return VF.WMF_VIDEO_CODECS.DEFAULT end
  return nil
end

local function raw_audio_codecs(format_id, container)
  local VF = VideoRenderFormat
  if format_id == "avf"    then return VF.AVF_AUDIO_CODECS[container] or VF.AVF_AUDIO_CODECS.DEFAULT end
  if format_id == "ffmpeg" then return VF.ffmpeg_audio_codecs(container) end
  if format_id == "wmf"    then return VF.WMF_AUDIO_CODECS.DEFAULT end
  return nil
end

local function without_none(list)
  if not list then return nil end
  local out = {}
  for _, e in ipairs(list) do
    if not e.is_none then out[#out + 1] = e end
  end
  return out
end

-- REAPER refuses to render with both video and audio set to None ("Audio
-- and video are both disabled"), so these lists never allow that pair:
-- video None is dropped when the container has no real audio codec (e.g.
-- FFmpeg MPEG-1 on macOS), and audio None is dropped while video is None.
function VideoRenderFormat.video_codecs_for(format_id, container)
  local list = raw_video_codecs(format_id, container)
  local audio = raw_audio_codecs(format_id, container)
  if list and #(without_none(audio) or {}) == 0 then return without_none(list) end
  return list
end

function VideoRenderFormat.audio_codecs_for(format_id, container, video_codec)
  local list = raw_audio_codecs(format_id, container)
  local video = raw_video_codecs(format_id, container)
  local v
  for _, e in ipairs(video or {}) do
    if e.id == video_codec then v = e break end
  end
  local c
  for _, e in ipairs(VideoRenderFormat.containers_for(format_id) or {}) do
    if e.id == container then c = e break end
  end
  if list and ((v and v.is_none) or (c and c.audio_only)) then return without_none(list) end
  return list
end

local function find_by_id(list, id)
  for _, opt in ipairs(list or {}) do
    if opt.id == id then return opt end
  end
  return nil
end
VideoRenderFormat.find_by_id = find_by_id

local function find_by_label(list, label)
  for _, opt in ipairs(list or {}) do
    if opt.label == label then return opt end
  end
  return nil
end

-- Snaps format_id/container/video_codec/audio_codec onto options that exist
-- on this platform. When the container changes, codecs are matched by name
-- (so H.264 stays H.264 even though its id differs per container), falling
-- back to the first entry in the list.
function VideoRenderFormat.clamp(t, prev_container)
  local VF = VideoRenderFormat
  local format_ok = false
  for _, f in ipairs(VF.FORMATS) do
    if f.id == t.format_id then format_ok = true break end
  end
  if not format_ok then
    for k, v in pairs(VF.DEFAULT_FORMAT) do t[k] = v end
  end

  -- Look the old codecs up in the unfiltered tables, so a codec this
  -- platform hides still maps across by name.
  local old_v, old_a
  if prev_container then
    local is_ff = t.format_id == "ffmpeg"
    old_v = find_by_id(is_ff and VF.FFMPEG_VIDEO_CODECS[prev_container]
      or VF.video_codecs_for(t.format_id, prev_container), t.video_codec)
    old_a = find_by_id(is_ff and VF.FFMPEG_AUDIO_CODECS[prev_container]
      or VF.audio_codecs_for(t.format_id, prev_container), t.audio_codec)
  end

  local containers = VF.containers_for(t.format_id)
  if containers and not find_by_id(containers, t.container) then
    t.container = containers[1].id
  end

  local function snap(list, field, old)
    if not list or #list == 0 then return end
    if old then
      local same = find_by_label(list, old.label)
      if same then t[field] = same.id return end
    end
    if not find_by_id(list, t[field]) then t[field] = list[1].id end
  end
  snap(VF.video_codecs_for(t.format_id, t.container), "video_codec", old_v)
  snap(VF.audio_codecs_for(t.format_id, t.container, t.video_codec), "audio_codec", old_a)
end

-- Upgrades a template saved by v1.4 or earlier: those used FFmpeg's
-- deprecated container 3 (now replaced by MPEG-4, id 7), and on macOS
-- defaulted to FFmpeg H.264, which REAPER's bundled FFmpeg can't encode.
function VideoRenderFormat.migrate_template(t)
  local VF = VideoRenderFormat
  if t.format_id == "ffmpeg" and t.container == 3 then
    local old_v = find_by_id(VF.FFMPEG_VIDEO_CODECS[3], t.video_codec)
    if not IS_WIN and old_v and not old_v.mac_bundled then
      -- The template asked for H.264/MPEG-2 in an MP4, which only
      -- AVFoundation can produce on this Mac.
      for k, v in pairs(VF.DEFAULT_FORMAT) do t[k] = v end
    else
      VF.clamp(t, 3)
      return
    end
  end
  VF.clamp(t)
end

function VideoRenderFormat.file_ext(t)
  if t.format_id == "gif" then return ".gif" end
  if t.format_id == "lcf" then return ".lcf" end
  local c = find_by_id(VideoRenderFormat.containers_for(t.format_id), t.container)
  return c and c.ext or ""
end

function VideoRenderFormat.is_audio_only(t)
  local c = find_by_id(VideoRenderFormat.containers_for(t.format_id), t.container)
  return c and c.audio_only or false
end


-- ============================================================
-- Encoders. `t` is a template-like table; see Video/Export Time Selection
-- as Video (GUI).lua's DEFAULTS for the exact field set.
-- ============================================================

-- Shared 44-byte body for AVF/PMFF (only the 4-byte header differs, and AVF
-- appends its own 2 trailing bytes -- see encode_avf). Both the kbps and
-- quality fields are always present in the blob regardless of which one the
-- selected codec actually uses -- confirmed against ground truth, where an
-- h264 (bitrate-mode) preset still carried a nonzero, unrelated value (95)
-- in the quality field. REAPER apparently just persists whatever each
-- field's own UI control last held rather than zeroing the unused one, so
-- both are passed through here unconditionally; only the caller's
-- rate_mode-driven UI decides which one is user-facing.
local function encode_avf_or_ffmpeg_body(t)
  local video_kbps    = t.video_bitrate_kbps or 0
  local video_quality = t.video_quality or 0
  local audio_kbps    = t.audio_bitrate_kbps or 0

  return table.concat({
    string.char(t.container or 0), string.char(0), string.char(0), string.char(0),
    string.char(t.video_codec or 0), string.char(0), string.char(0), string.char(0),
    u32_le(video_kbps),
    string.char(t.audio_codec or 0), string.char(0), string.char(0), string.char(0),
    u32_le(audio_kbps),
    u32_le(t.width or 0),
    u32_le(t.height or 0),
    f32_le(t.framerate or 0),
    string.char(t.preserve_aspect and 1 or 0), string.char(0), string.char(0), string.char(0),
    u32_le(video_quality),
  })
end

function VideoRenderFormat.encode_avf(t)
  -- The real captured FVAX ground-truth blob (see module header comment)
  -- was 46 bytes -- 2 bytes longer than the documented 44-byte field table
  -- -- so AVF keeps its trailing zero pair, almost certainly the two
  -- empty-string terminators PMFF's (but not FVAX's) documented
  -- command-line-option fields use when empty.
  return VideoRenderFormat.base64_encode("FVAX" .. encode_avf_or_ffmpeg_body(t) .. "\0\0")
end

function VideoRenderFormat.encode_ffmpeg(t)
  -- REAPER 7.80's dialog saves PMFF as the 44-byte body plus two empty
  -- strings (the video/audio "options" fields), so this appends the same
  -- two terminators.
  return VideoRenderFormat.base64_encode("PMFF" .. encode_avf_or_ffmpeg_body(t) .. "\0\0")
end

-- WMF's video-codec field is an unusual 4-byte sentinel rather than a small
-- per-container enum byte: 0x00000000 = H.264, 0xFFFFFFFF = no video codec
-- (used for the audio-only containers, which have no video track at all --
-- see RENDER_How_RenderCFG-Base64-strings_are_encoded.txt's WMF section).
-- No quality field exists in this layout, unlike PMFF/H.264.
function VideoRenderFormat.encode_wmf(t)
  local is_audio_only = (t.container == 1 or t.container == 3)
  local video_codec_field = is_audio_only and "\255\255\255\255" or "\0\0\0\0"

  local body = table.concat({
    string.char(t.container or 0), string.char(0), string.char(0), string.char(0),
    video_codec_field,
    u32_le(t.video_bitrate_kbps or 0),
    string.char(t.audio_codec or 0), string.char(0), string.char(0), string.char(0),
    u32_le(t.audio_bitrate_kbps or 0),
    u32_le(t.width or 0),
    u32_le(t.height or 0),
    f32_le(t.framerate or 0),
    string.char(t.preserve_aspect and 1 or 0), string.char(0), string.char(0), string.char(0),
    string.char(0), string.char(0), string.char(0), string.char(0), -- unused bytes 41-44
  })
  return VideoRenderFormat.base64_encode(" FMW" .. body)
end

function VideoRenderFormat.encode_gif(t)
  local ignore_bits = t.gif_ignore_bits or 0
  local color_byte = (ignore_bits * 2) + (t.gif_encode_transparency and 1 or 0)
  local body = table.concat({
    "\x20FIG",
    u32_le(t.width or 0),
    u32_le(t.height or 0),
    f32_le(t.framerate or 0),
    string.char(t.preserve_aspect and 1 or 0),
    string.char(color_byte),
  })
  return VideoRenderFormat.base64_encode(body)
end

function VideoRenderFormat.encode_lcf(t)
  local tweak = (t.lcf_tweak or "t20 x128 y16")
  if #tweak > 63 then tweak = tweak:sub(1, 63) end
  tweak = tweak .. string.rep("\0", 63 - #tweak)
  local body = table.concat({
    "\x20FCL",
    u32_le(t.width or 0),
    u32_le(t.height or 0),
    f32_le(t.framerate or 0),
    string.char(t.preserve_aspect and 1 or 0),
    string.char(0),
    tweak,
  })
  return VideoRenderFormat.base64_encode(body)
end

return VideoRenderFormat
