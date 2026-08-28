-- Shared video RENDER_FORMAT blob encoder for Video/Export Time Selection as
-- Video (GUI).lua.
--
-- REAPER stores the render dialog's per-format settings as an opaque binary
-- blob (base64-encoded when read/written via GetSetProjectInfo_String's
-- RENDER_FORMAT key, and stored the same way in reaper-render.ini). There is
-- no documented ReaScript API for setting "H.264 2048kbps" directly -- this
-- module hand-encodes that blob.
--
-- Byte layout below is per Ultraschall's RENDER_How_RenderCFG-Base64-
-- strings_are_encoded.txt (misc_docs in ultraschall-lua-api-for-reaper),
-- cross-checked against a real saved preset in this machine's own
-- reaper-render.ini ("Video - H264": AVFoundation/h264, 1920x1080, 59.94fps,
-- 6000kbps video / 320kbps audio, aspect-locked) -- every field matched
-- byte-for-byte, so the AVF/PMFF layout here is high-confidence, not a
-- guess. GIF/LCF follow the same doc but have no local ground-truth sample.

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
-- Format/codec option tables. Each entry is {id, label, [rate_mode]}.
-- rate_mode (video codecs only): "bitrate" | "quality" | nil (neither --
-- e.g. lossless/ProRes codecs with no user-adjustable rate control).
-- ============================================================

VideoRenderFormat.AVF_CONTAINERS = {
  { id = 0, label = "MPEG-4 Video (streaming optimized)" },
  { id = 1, label = "MPEG-4 Video" },
  { id = 2, label = "Quicktime MOV" },
  { id = 3, label = "MPEG-4 Audio (no video)" },
}

-- Video codec options per AVF container id. Only container 2 (Quicktime
-- MOV) offers a choice -- all others are fixed to h264 (or no video at all
-- for MPEG-4 Audio, handled by the caller hiding video fields entirely).
VideoRenderFormat.AVF_VIDEO_CODECS = {
  [2] = {
    { id = 0, label = "H.264",               rate_mode = "bitrate" },
    { id = 1, label = "Apple ProRes 4444",    rate_mode = nil },
    { id = 2, label = "Apple ProRes 422",     rate_mode = nil },
    { id = 3, label = "MJPEG",                rate_mode = "quality" },
  },
  DEFAULT = {
    { id = 0, label = "H.264", rate_mode = "bitrate" },
  },
}

-- Audio codec options per AVF container id. Only Quicktime MOV offers PCM.
VideoRenderFormat.AVF_AUDIO_CODECS = {
  [2] = {
    { id = 0, label = "AAC" },
    { id = 1, label = "16-bit PCM" },
    { id = 2, label = "24-bit PCM" },
    { id = 3, label = "32-bit FP PCM" },
  },
  DEFAULT = {
    { id = 0, label = "AAC" },
  },
}

VideoRenderFormat.FFMPEG_CONTAINERS = {
  { id = 0, label = "AVI" },
  { id = 1, label = "MPEG1" },
  { id = 2, label = "MPEG2" },
  { id = 3, label = "QT/MOV/MP4" },
  { id = 4, label = "MKV" },
  { id = 5, label = "FLV" },
  { id = 6, label = "WEBM" },
}

VideoRenderFormat.FFMPEG_VIDEO_CODECS = {
  [0] = { -- AVI
    { id = 0, label = "XviD",              rate_mode = "bitrate" },
    { id = 1, label = "H.264",             rate_mode = "quality" },
    { id = 2, label = "DV",                rate_mode = nil },
    { id = 3, label = "MJPEG",              rate_mode = "quality" },
    { id = 4, label = "FFV1 (lossless)",    rate_mode = nil },
    { id = 5, label = "Hufyuv (lossless)",  rate_mode = nil },
    { id = 6, label = "None" },
  },
  [1] = { -- MPEG1
    { id = 0, label = "MPEG-1", rate_mode = "bitrate" },
    { id = 1, label = "None" },
  },
  [2] = { -- MPEG2
    { id = 0, label = "MPEG-2", rate_mode = "bitrate" },
    { id = 1, label = "None" },
  },
  [3] = { -- QT/MOV/MP4
    { id = 0, label = "H.264",  rate_mode = "quality" },
    { id = 1, label = "MPEG-2", rate_mode = "bitrate" },
    { id = 2, label = "MJPEG",  rate_mode = "quality" },
    { id = 3, label = "None" },
  },
  [4] = { -- MKV
    { id = 0, label = "H.264",             rate_mode = "quality" },
    { id = 1, label = "XviD",               rate_mode = "bitrate" },
    { id = 2, label = "FFV1 (lossless)",    rate_mode = nil },
    { id = 3, label = "Hufyuv (lossless)",  rate_mode = nil },
    { id = 4, label = "MJPEG",               rate_mode = "quality" },
    { id = 5, label = "MPEG-2",              rate_mode = "bitrate" },
    { id = 6, label = "None" },
  },
  [5] = { -- FLV
    { id = 0, label = "H.264", rate_mode = "quality" },
    { id = 1, label = "FLV1",  rate_mode = "bitrate" },
    { id = 2, label = "None" },
  },
  [6] = { -- WEBM
    { id = 0, label = "VP8", rate_mode = "bitrate" },
    { id = 1, label = "VP9", rate_mode = "bitrate" },
    { id = 2, label = "None" },
  },
}

VideoRenderFormat.FFMPEG_AUDIO_CODECS = {
  [0] = { -- AVI
    { id = 0, label = "MP3" },
    { id = 1, label = "AAC" },
    { id = 2, label = "AC3" },
    { id = 3, label = "16-bit PCM" },
    { id = 4, label = "24-bit PCM" },
    { id = 5, label = "32-bit FP" },
    { id = 7, label = "None" }, -- sic: source doc enumerates 0-5 then 7 (no 6)
  },
  [1] = { -- MPEG1
    { id = 0, label = "MP3" },
    { id = 1, label = "MP2" },
    { id = 2, label = "None" },
  },
  [2] = { -- MPEG2
    { id = 0, label = "AAC" },
    { id = 1, label = "MP3" },
    { id = 2, label = "MP2" },
    { id = 3, label = "None" },
  },
  [3] = { -- QT/MOV/MP4
    { id = 0, label = "AAC" },
    { id = 1, label = "MP3" },
    { id = 2, label = "16-bit PCM" },
    { id = 3, label = "24-bit PCM" },
    { id = 4, label = "32-bit FP" },
    { id = 5, label = "None" },
  },
  [4] = { -- MKV
    { id = 0, label = "MP3" },
    { id = 1, label = "AAC" },
    { id = 2, label = "16-bit PCM" },
    { id = 3, label = "24-bit PCM" },
    { id = 4, label = "32-bit FP" },
    { id = 5, label = "None" },
  },
  [5] = { -- FLV
    { id = 0, label = "MP3" },
    { id = 1, label = "AAC" },
    { id = 2, label = "None" },
  },
  [6] = { -- WEBM
    { id = 0, label = "VORBIS" },
    { id = 1, label = "OPUS" },
    { id = 2, label = "None" },
  },
}

-- WMF ("Windows Media encoder") renders through Windows' own built-in Media
-- Foundation H.264 encoder rather than REAPER's optional/separately-
-- installed FFmpeg libs, so it's the one FFmpeg-format alternative that
-- produces real H.264 out of the box on a stock Windows install with no
-- extra DLLs. Windows-only; container id doubles as the format's own
-- video/audio-track toggle (id 1 and 3 are audio-only, no video codec at
-- all -- same pattern as AVF's "MPEG-4 Audio" container).
VideoRenderFormat.WMF_CONTAINERS = {
  { id = 0, label = "MPEG-4 Video" },
  { id = 1, label = "MPEG-4 Audio (no video)" },
  { id = 2, label = "WMV Video" },
  { id = 3, label = "WMA Audio (no video)" },
}

-- H.264 is the only real encoder choice for either video-capable container
-- -- the audio-only containers hide video fields entirely (caller's
-- is_audio_only check), so there's nothing container-specific to key this
-- by. No quality field exists in WMF's byte layout (unlike PMFF/H.264),
-- only bitrate.
VideoRenderFormat.WMF_VIDEO_CODECS = {
  DEFAULT = {
    { id = 0, label = "H.264", rate_mode = "bitrate" },
  },
}

VideoRenderFormat.WMF_AUDIO_CODECS = {
  DEFAULT = {
    { id = 0, label = "AAC" },
    { id = 2, label = "None" },
  },
}

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
  -- Unlike AVF, a real PMFF preset saved from REAPER's own render dialog
  -- ("DCF2 Faceware Video Export" in this machine's reaper-render.ini --
  -- container 3/QT-MOV-MP4, H.264, quality 100) decodes to exactly the
  -- documented 44 bytes with no trailing padding. Per
  -- RENDER_How_RenderCFG-Base64-strings_are_encoded.txt, PMFF only grows
  -- past byte 44 for non-empty command-line-option strings, which this
  -- script never sets, so no trailing bytes are appended here.
  return VideoRenderFormat.base64_encode("PMFF" .. encode_avf_or_ffmpeg_body(t))
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
