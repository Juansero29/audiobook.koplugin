--[[--
MediaEngine -- Audio file playback with seeking for pre-recorded audiobooks.
Supports mpv (JSON IPC), mplayer (slave mode), gst-play-1.0, aplay fallbacks,
and Kindle-specific backends (LIPC playermgr, bundled gst-play).

@module koplugin.audiobook.mediaengine
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

local ffi = require("ffi")
pcall(function() ffi.cdef[[ int kill(int pid, int sig); ]] end)
pcall(function() ffi.cdef[[ int mkfifo(const char *pathname, unsigned int mode); ]] end)

local MediaEngine = {}

MediaEngine.BACKENDS = {
    MPV = "mpv",
    MPLAYER = "mplayer",
    FFMPEG_PIPE = "ffmpeg-pipe",
    GST_PLAY = "gst-play",
    GST_PIPELINE = "gst-pipeline",
    APLAY = "aplay",
    WAV_PLAY = "wav-play",
    KINDLE_LIPC = "kindle-lipc",
    KINDLE_GST_PLAY = "kindle-gst-play",
}

function MediaEngine:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.backend = nil
    o.backend_cmd = nil
    o.audio_pid = nil
    o.play_generation = 0
    o.current_path = nil
    o.current_duration = nil
    o.is_playing = false
    o.is_paused = false
    o._socket_path = nil
    o._fifo_path = nil
    o._ipc_file = nil
    o._pending_callbacks = {}
    o._position_timer = nil
    o._on_complete = nil
    o._on_fail = nil
    o._seek_target = nil
    o._plugin_dir = o.plugin_dir or "."
    -- Elapsed-time tracking for backends without IPC (gst-play, aplay)
    o._play_start_time = nil
    o._pause_start_time = nil
    o._total_pause_ms = 0
    o._seek_offset = 0
    -- Kindle-specific state
    o._gst_play_cmd = nil
    o._lipc_fallback_tried = false
    -- Persistent GStreamer pipeline state (MTK Bluetooth path)
    o._use_persistent_pipeline = false
    o._persistent_pipeline_active = false
    o._pipeline_gst_pid = nil
    o._pipeline_wrapper_pid = nil
    o._media_ctrl_dir = "/tmp/audiobook_media_ctrl"
    o._media_fifo = "/tmp/audiobook_media_fifo"
    o._media_script = "/tmp/audiobook_media_pipeline.sh"
    o._current_pcm_file = nil
    -- Digital playback volume (0.0..1.0).  Applied as an ffmpeg `volume`
    -- filter in the decode pipeline, so it works without depending on
    -- Amazon's (model-specific) LIPC volume property.  1.0 = unchanged.
    o._volume = 1.0
    return o
end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

function MediaEngine:commandExists(cmd)
    local handle = io.popen("command -v " .. cmd .. " 2>/dev/null")
    if not handle then return false end
    local result = handle:read("*l")
    handle:close()
    return result ~= nil and result ~= ""
end

--- Take audiomgrd 'Music' focus once per KOReader session.
-- Every setFocus makes audiomgrd re-ramp gain to its stored level, which
-- resets the headset volume on each call -- so seeks and track switches
-- must not re-issue it.  New streams inherit focus from audiomgrd's cache.
function MediaEngine._takeMusicFocusOnce()
    if MediaEngine._focus_taken then return end
    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'Music' 2>/dev/null")
    MediaEngine._focus_taken = true
end

--[[--
Build an ffmpeg atempo filter string for the given playback speed.
atempo accepts 0.5..2.0; chain multiple filters for speeds outside that range.
@return string  Filter string suitable for -filter:a, or empty string for 1.0x.
--]]
function MediaEngine:_atempoFilterString(speed)
    speed = tonumber(speed) or 1.0
    if math.abs(speed - 1.0) < 0.01 then return "" end
    local filters = {}
    local remaining = speed
    while remaining > 2.0 + 0.001 do
        table.insert(filters, "atempo=2.0")
        remaining = remaining / 2.0
    end
    while remaining < 0.5 - 0.001 do
        table.insert(filters, "atempo=0.5")
        remaining = remaining / 0.5
    end
    table.insert(filters, string.format("atempo=%.3f", remaining))
    return " -filter:a \"" .. table.concat(filters, ",") .. "\""
end

--[[--
Probe for ffmpeg in the plugin's bin/ directory or PATH.
The release zip may ship ELF binaries with a .bin extension so they survive
Windows zip extractors; rename .bin back to the original name if needed.
@return string|nil  absolute path to ffmpeg binary, or nil
--]]
function MediaEngine:_findFfmpeg()
    if self._plugin_dir then
        local plugin_ffmpeg = self._plugin_dir .. "/bin/ffmpeg"
        local f = io.open(plugin_ffmpeg, "r")
        if f then
            f:close()
            return plugin_ffmpeg
        end
        -- Release zip ships ffmpeg as ffmpeg.bin; rename on first use.
        local bin_path = plugin_ffmpeg .. ".bin"
        local b = io.open(bin_path, "r")
        if b then
            b:close()
            os.remove(plugin_ffmpeg)
            local ok, err = os.rename(bin_path, plugin_ffmpeg)
            if ok then
                logger.warn("MediaEngine: renamed", bin_path, "to", plugin_ffmpeg)
                return plugin_ffmpeg
            else
                logger.warn("MediaEngine: failed to rename", bin_path, ":", err)
                -- Return the .bin path as a fallback so playback can still work.
                return bin_path
            end
        end
    end
    local h = io.popen("command -v ffmpeg 2>/dev/null")
    if h then
        local result = h:read("*l")
        h:close()
        if result and result ~= "" then return result end
    end
    return nil
end

function MediaEngine:_getTempDir()
    return os.getenv("TMPDIR") or "/tmp"
end

function MediaEngine:_nextGeneration()
    self.play_generation = self.play_generation + 1
    return self.play_generation
end

--[[--
Detect whether the MTK Bluetooth audio sink is available.
This sink holds an exclusive abstract socket, so we must use a persistent
pipeline instead of killing and restarting the player on seek/pause.
@return boolean true if mtkbtmwrpcaudiosink is available
--]]
function MediaEngine:_hasMtkSink()
    if not self:commandExists("gst-launch-1.0") then return false end
    local h = io.popen("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1 && echo yes || echo no")
    if not h then return false end
    local result = h:read("*l") == "yes"
    h:close()
    return result
end

-- ---------------------------------------------------------------------------
-- Backend detection
-- ---------------------------------------------------------------------------

function MediaEngine:detectBackend()
    if self.backend then
        return self.backend, self.backend_cmd
    end

    -- 1) mpv -- best seeking, JSON IPC, handles all formats
    if self:commandExists("mpv") then
        self.backend = self.BACKENDS.MPV
        self.backend_cmd = "mpv"
        logger.warn("MediaEngine: selected mpv backend")
        return self.backend, self.backend_cmd
    end

    -- 2) mplayer -- slave mode, reasonable seeking
    if self:commandExists("mplayer") then
        self.backend = self.BACKENDS.MPLAYER
        self.backend_cmd = "mplayer"
        logger.warn("MediaEngine: selected mplayer backend")
        return self.backend, self.backend_cmd
    end

    -- 3) Kindle backends FIRST on Kindle hardware: there is no ALSA and no
    -- aplay, so the ffmpeg-pipe backend (which pipes WAV to aplay) can
    -- never produce sound here; audio must go through Amazon's
    -- mixersink → audiomgrd → BT pipeline.  The kindle-gst-play backend
    -- decodes non-WAV formats by streaming bundled-ffmpeg output into the
    -- system GStreamer (see _playSystemGstLaunch).
    if self:_isKindle() then
        local gst_play_detected = self:_detectKindleGstPlay()
        if gst_play_detected then
            self.backend = self.BACKENDS.KINDLE_GST_PLAY
            self.backend_cmd = self._gst_play_cmd
            logger.warn("MediaEngine: selected kindle-gst-play backend")
            return self.backend, self.backend_cmd
        end

        local lipc_detected = self:_detectKindleLipc()
        if lipc_detected then
            self.backend = self.BACKENDS.KINDLE_LIPC
            self.backend_cmd = "lipc"
            logger.warn("MediaEngine: selected kindle-lipc backend")
            return self.backend, self.backend_cmd
        end
    end

    -- 4) ffmpeg pipe -- decodes any format ffmpeg supports (m4b, aac, ogg,
    -- flac, etc.) and pipes raw WAV to aplay.  Preferred over gst-play on
    -- devices where gstreamer lacks AAC decoders (common on Kobo).
    local ffmpeg_cmd = self:_findFfmpeg()
    if ffmpeg_cmd then
        self.backend = self.BACKENDS.FFMPEG_PIPE
        self.backend_cmd = ffmpeg_cmd
        if self:_hasMtkSink() then
            self._use_persistent_pipeline = true
            logger.warn("MediaEngine: selected ffmpeg-pipe backend with persistent pipeline (MTK)")
        else
            logger.warn("MediaEngine: selected ffmpeg-pipe backend")
        end
        return self.backend, self.backend_cmd
    end

    -- 4) gst-play-1.0 -- preferred over gst-launch because playbin handles
    -- URI fragments (#t=) for time-offset seeking, which uridecodebin does not.
    if self:commandExists("gst-play-1.0") then
        self.backend = self.BACKENDS.GST_PLAY
        self.backend_cmd = "gst-play-1.0"
        if self:_hasMtkSink() then
            self._use_persistent_pipeline = true
            logger.warn("MediaEngine: selected gst-play-1.0 backend with persistent pipeline (MTK)")
        else
            logger.warn("MediaEngine: selected gst-play-1.0 backend")
        end
        return self.backend, self.backend_cmd
    end

    -- 4) gst-launch-1.0 -- build custom pipeline (fallback)
    if self:commandExists("gst-launch-1.0") then
        self.backend = self.BACKENDS.GST_PIPELINE
        self.backend_cmd = "gst-launch-1.0"
        if self:_hasMtkSink() then
            self._use_persistent_pipeline = true
            logger.warn("MediaEngine: selected gst-launch-1.0 backend with persistent pipeline (MTK)")
        else
            logger.warn("MediaEngine: selected gst-launch-1.0 backend")
        end
        return self.backend, self.backend_cmd
    end

    -- 6) aplay -- WAV only, no seeking
    if self:commandExists("aplay") then
        self.backend = self.BACKENDS.APLAY
        self.backend_cmd = "aplay"
        logger.warn("MediaEngine: selected aplay backend (WAV only, no seek)")
        return self.backend, self.backend_cmd
    end

    -- 7) bundled wav-play -- WAV only, no seeking
    local wav_play_path = self._plugin_dir .. "/wav-play"
    local f = io.open(wav_play_path, "r")
    if f then
        f:close()
        self.backend = self.BACKENDS.WAV_PLAY
        self.backend_cmd = wav_play_path
        logger.warn("MediaEngine: selected bundled wav-play backend (WAV only, no seek)")
        return self.backend, self.backend_cmd
    end

    logger.err("MediaEngine: no audio backend found")
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Kindle-specific backend detection
-- Mirrors the logic in TTSEngine:findAudioPlayer() for LIPC playermgr
-- and bundled kindle/gst-play backends.
-- ---------------------------------------------------------------------------

--- Check if the device is a Kindle via KOReader's Device module or
--- fallback heuristics.
-- @treturn bool
function MediaEngine:_isKindle()
    return Device.isKindle and Device:isKindle()
end

--- Probe whether Kindle playermgr (LIPC) is available: lipc-set-prop,
--- lipc-get-prop exist, and com.lab126.playermgr InPlayback property
--- can be read (returns a digit).
-- @treturn string|nil "kindle-lipc" if available, nil otherwise
function MediaEngine:_detectKindleLipc()
    if not self:_isKindle() then return nil end

    local h = io.popen("command -v lipc-set-prop 2>/dev/null && command -v lipc-get-prop 2>/dev/null")
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    if out == "" then return nil end

    local ph = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>&1")
    if not ph then return nil end
    local val = ph:read("*a") or ""
    ph:close()
    val = val:match("^%s*(%d+)")
    if val then
        -- playermgr service exists and responds.
        -- Check for wavparse in GStreamer plugins: if present, playermgr
        -- can decode WAV files via GStreamer natively.  If absent, audio
        -- files need-- to be transcoded to WAV and played via kindle-gst-play.
        local has_wavparse = false
        local gst_dirs = {"/usr/lib/gstreamer-1.0", "/usr/lib/gstreamer-0.10"}
        for _, dir in ipairs(gst_dirs) do
            local lsh = io.popen("ls " .. dir .. "/libgstwav* 2>/dev/null")
            if lsh then
                local ls_out = lsh:read("*a") or ""
                lsh:close()
                if ls_out:match("libgstwav") then
                    has_wavparse = true
                    break
                end
            end
        end
        if not has_wavparse then
            -- No wavparse -- playermgr cannot decode WAV natively.
            -- Only use kindle-lipc if we can detect the bundled gst-play
            -- as a fallback, since the file is already transcoded to WAV
            -- by the plugin's transcoder before reaching MediaEngine.
            -- If gst-play exists, we prefer KINDLE_GST_PLAY; if not,
            -- try kindle-lipc anyway (the file may be MP3 which playermgr
            -- handles natively via decodebin).
            local plugin_dir = self._plugin_dir or "."
            local gst_play_bin = plugin_dir .. "/kindle/gst-play"
            local gf = io.open(gst_play_bin, "r")
            if not gf then
                -- No gst-play available; skip LIPC if wavparse is absent
                -- because playermgr will fail silently on WAV files.
                -- MP3 files may still work, but we can't be sure.
                logger.warn("MediaEngine: Kindle LIPC available but no wavparse and no gst-play -- will try LIPC for non-WAV files")
            else
                gf:close()
                logger.warn("MediaEngine: Kindle LIPC available but no wavparse -- gst-play present for WAV fallback")
            end
        end
        logger.warn("MediaEngine: Found Kindle LIPC playermgr service, InPlayback=", val,
            "wavparse=", has_wavparse)
        return "kindle-lipc"
    end
    logger.warn("MediaEngine: lipc-get-prop playermgr InPlayback returned:", val)
    return nil
end

--- Probe for the bundled kindle/gst-play binary and verify that
--- GStreamer mixersink is available.  gst-play feeds raw PCM to
--- mixersink → audiomgrd → BT headphones.
-- @treturn string|nil "kindle-gst-play" if available, nil otherwise
function MediaEngine:_detectKindleGstPlay()
    if not self:_isKindle() then return nil end

    local plugin_dir = self._plugin_dir or "."
    local gst_play_bin = plugin_dir .. "/kindle/gst-play"
    local gf = io.open(gst_play_bin, "r")
    if not gf then
        logger.dbg("MediaEngine: kindle/gst-play not bundled")
        -- System pipelines alone are enough (see comment below).
        if self:commandExists("gst-launch-0.10") then
            self._gst_play_cmd = nil
            return "kindle-gst-play"
        end
        return nil
    end
    gf:close()

    -- The bundled binary may need the bundled dynamic linker: builds from
    -- the Nix cross toolchain carry a /nix/store ELF interpreter that does
    -- not exist on the device, so bare execution fails with "not found".
    -- Probe bare first, then wrapped (mirroring ttsengine).
    local linker = plugin_dir .. "/espeak-ng/lib/ld-linux-armhf.so.3"
    local lf = io.open(linker, "r")
    local candidates = { gst_play_bin }
    if lf then
        lf:close()
        table.insert(candidates, string.format(
            "%s --library-path %s/espeak-ng/lib:/usr/lib/tts:/usr/lib:/lib %s",
            linker, plugin_dir, gst_play_bin))
    end

    local gst_play_cmd = nil
    for _, cand in ipairs(candidates) do
        local ph = io.popen(cand .. " --probe 2>&1")
        if ph then
            local probe = ph:read("*a") or ""
            ph:close()
            -- Accept the binary as long as mixersink is present and usable.
            -- GStreamer warnings about unrelated plugins (e.g. ttssrc failing
            -- to load because libIvonaEInkAPI.so is stripped on newer
            -- firmware) do not affect our WAV playback path.
            if probe:match("mixersink=found")
                and not probe:match("mixersink=broken")
                and not probe:match("gstreamer=not_found") then
                gst_play_cmd = cand
                break
            end
        end
    end

    if gst_play_cmd then
        logger.warn("MediaEngine: Found bundled kindle-gst-play with mixersink")
        self._gst_play_cmd = gst_play_cmd
        return "kindle-gst-play"
    end

    -- Bundled binary unusable, but the kindle-gst-play backend can still
    -- play everything through the system GStreamer: WAV via raw PCM
    -- filesrc, other formats via bundled-ffmpeg streaming (see
    -- _playSystemGstLaunch*).  Selecting kindle-lipc here instead used to
    -- strand PW5 on the dead playermgr ("none of 4 strategies got
    -- InPlayback=1").
    if self:commandExists("gst-launch-0.10") then
        logger.warn("MediaEngine: bundled gst-play unusable, using system gst-launch-0.10 pipelines")
        self._gst_play_cmd = nil
        return "kindle-gst-play"
    end

    logger.warn("MediaEngine: kindle-gst-play probe failed and no system gst-launch-0.10")
    return nil
end

-- ---------------------------------------------------------------------------
-- Duration probing
-- ---------------------------------------------------------------------------

function MediaEngine:_findFfprobe()
    -- Check PATH first, then plugin bin/ directory
    local h = io.popen("command -v ffprobe 2>/dev/null")
    if h then
        local result = h:read("*l")
        h:close()
        if result and result ~= "" then return result end
    end
    if self._plugin_dir then
        local plugin_ffprobe = self._plugin_dir .. "/bin/ffprobe"
        local f = io.open(plugin_ffprobe, "r")
        if f then f:close() return plugin_ffprobe end
    end
    return nil
end

function MediaEngine:_probeDurationFfprobe(path)
    local ffprobe = self:_findFfprobe()
    if not ffprobe then return nil end

    local cmd = string.format(
        '"%s" -v error -show_entries format=duration -of csv=p=0 "%s" 2>/dev/null',
        ffprobe:gsub('"', '\\"'),
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    local secs = tonumber(out:match("^%s*([%d%.]+)"))
    if secs and secs > 0 then
        logger.dbg("MediaEngine: ffprobe duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:_probeDurationGstDiscoverer(path)
    local cmd = string.format(
        'gst-discoverer-1.0 "%s" 2>/dev/null | grep -i "^  Duration:"',
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    -- Parse "  Duration: 0:11:36.163265306"
    local hh, mm, ss = out:match("Duration:%s*(%d+):(%d+):([%d%.]+)")
    if hh and mm and ss then
        local secs = tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
        if secs and secs > 0 then
            logger.dbg("MediaEngine: gst-discoverer duration =", secs)
            return secs
        end
    end
    return nil
end

function MediaEngine:_probeDurationMpv(path)
    -- Quick probe via mpv --no-video --frames=0
    local cmd = string.format(
        'mpv --no-video --frames=0 --really-quiet --term-playing-msg="${=duration}" "%s" 2>/dev/null',
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    local secs = tonumber(out:match("([%d%.]+)"))
    if secs and secs > 0 then
        logger.dbg("MediaEngine: mpv probe duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:_probeDurationWav(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    -- WAV header: byte 22-23 = channels, 24-27 = sample rate, 28-31 = byte rate,
    -- 40-43 = data chunk size
    f:seek("set", 22)
    local channels_data = f:read(2)
    local rate_data = f:read(4)
    f:seek("set", 40)
    local data_size_data = f:read(4)
    f:close()
    if not channels_data or not rate_data or not data_size_data then return nil end
    local channels = channels_data:byte(1) + channels_data:byte(2) * 256
    local rate = rate_data:byte(1) + rate_data:byte(2) * 256 +
                 rate_data:byte(3) * 65536 + rate_data:byte(4) * 16777216
    local data_size = data_size_data:byte(1) + data_size_data:byte(2) * 256 +
                      data_size_data:byte(3) * 65536 + data_size_data:byte(4) * 16777216
    if channels > 0 and rate > 0 and data_size > 0 then
        local secs = data_size / (rate * channels * 2)
        logger.dbg("MediaEngine: WAV header duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:probeDuration(path)
    local ext = path:match("%.([^.]+)$") or ""
    ext = ext:lower()

    -- ffprobe is most reliable for all formats
    local dur = self:_probeDurationFfprobe(path)
    if dur then return dur end

    -- Bundled ffmpeg (no ffprobe shipped): parse "Duration: HH:MM:SS.cc"
    -- from its banner output.
    local ffmpeg = self:_findFfmpeg()
    if ffmpeg then
        local h = io.popen(string.format(
            "%s -i '%s' 2>&1", ffmpeg:gsub("'", "'\\''"), path:gsub("'", "'\\''")))
        if h then
            local out = h:read("*a") or ""
            h:close()
            local hh, mm, ss = out:match("Duration:%s*(%d+):(%d+):([%d%.]+)")
            if hh then
                return tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
            end
        end
    end

    -- gst-discoverer-1.0 fallback (Kobo, etc.)
    dur = self:_probeDurationGstDiscoverer(path)
    if dur then return dur end

    -- mpv can also probe
    if self.backend == self.BACKENDS.MPV then
        dur = self:_probeDurationMpv(path)
        if dur then return dur end
    end

    -- WAV fallback: parse header directly
    if ext == "wav" then
        dur = self:_probeDurationWav(path)
        if dur then return dur end
    end

    logger.warn("MediaEngine: could not probe duration for", path)
    return nil
end

-- ---------------------------------------------------------------------------
-- IPC helpers (mpv)
-- ---------------------------------------------------------------------------

function MediaEngine:_hasLuaSocket()
    local ok, socket = pcall(require, "socket")
    return ok and socket ~= nil
end

function MediaEngine:_mpvSendIpc(cmd_table, timeout_ms)
    timeout_ms = timeout_ms or 500
    if not self._socket_path then return nil end

    -- Try LuaSocket first
    if self:_hasLuaSocket() then
        local ok, socket = pcall(require, "socket")
        if ok then
            local unix = socket.unix and socket.unix()
            if unix then
                unix:settimeout(timeout_ms / 1000)
                local connected, err = unix:connect(self._socket_path)
                if connected then
                    local ok_json, json = pcall(require, "json")
                    if ok_json and json then
                        local payload = json.encode(cmd_table) .. "\n"
                        unix:send(payload)
                        local response = unix:receive("*l")
                        unix:close()
                        if response then
                            local ok2, decoded = pcall(json.decode, response)
                            if ok2 then return decoded end
                        end
                    end
                else
                    logger.dbg("MediaEngine: LuaSocket connect failed:", err)
                end
            end
        end
    end

    -- Fallback: write directly to Unix socket via FFI
    if ffi.C.open then
        local ok_json, json = pcall(require, "json")
        if ok_json and json then
            local O_WRONLY = 1
            local fd = ffi.C.open(self._socket_path, O_WRONLY)
            if fd >= 0 then
                local payload = json.encode(cmd_table) .. "\n"
                ffi.C.write(fd, payload, #payload)
                ffi.C.close(fd)
                -- For commands that don't need response, this is sufficient
                return {data = true}
            end
        end
    end

    return nil
end

function MediaEngine:_mpvSendFifo(command_str)
    if not self._fifo_path then return false end
    local f = io.open(self._fifo_path, "w")
    if f then
        f:write(command_str .. "\n")
        f:close()
        return true
    end
    return false
end

function MediaEngine:_setupMpvIpc()
    local tmpdir = self:_getTempDir()
    local gen = self.play_generation

    -- Try Unix socket first
    self._socket_path = string.format("%s/mpv-audiobook-%d.sock", tmpdir, gen)
    -- Remove stale socket
    os.remove(self._socket_path)

    -- Also prepare FIFO fallback
    self._fifo_path = string.format("%s/mpv-fifo-%d", tmpdir, gen)
    os.remove(self._fifo_path)
    if ffi.C.mkfifo then
        ffi.C.mkfifo(self._fifo_path, 384) -- 0600 octal = 384 decimal
    else
        os.execute("mkfifo '" .. self._fifo_path:gsub("'", "'\\''") .. "'")
    end
end

function MediaEngine:_cleanupIpc()
    if self._socket_path then
        os.remove(self._socket_path)
        self._socket_path = nil
    end
    if self._fifo_path then
        os.remove(self._fifo_path)
        self._fifo_path = nil
    end
    if self._ipc_file then
        os.remove(self._ipc_file)
        self._ipc_file = nil
    end
end

-- ---------------------------------------------------------------------------
-- Playback control
-- ---------------------------------------------------------------------------

function MediaEngine:load(path)
    if not path or path == "" then
        logger.err("MediaEngine: load() called with empty path")
        return false
    end

    self:detectBackend()
    if not self.backend then
        logger.err("MediaEngine: no backend available")
        return false
    end

    -- Pre-start the persistent pipeline on MTK so play() has no latency.
    if self._use_persistent_pipeline then
        if not self:_startPersistentPipeline() then
            logger.warn("MediaEngine: persistent pipeline failed on load, falling back")
            self._use_persistent_pipeline = false
        end
    end

    self.current_path = path
    self.current_duration = self:probeDuration(path)
    self.is_playing = false
    self.is_paused = false
    self._seek_offset = 0
    self._use_progress_position = false
    self._progress_file = nil

    logger.warn("MediaEngine: loaded", path,
        "backend=", self.backend,
        "duration=", self.current_duration)
    return true
end

function MediaEngine:play(on_complete, on_fail)
    if not self.current_path then
        logger.err("MediaEngine: play() called without load()")
        if on_fail then on_fail("no file loaded") end
        return false
    end

    self:stop()
    local gen = self:_nextGeneration()
    self._on_complete = on_complete
    self._on_fail = on_fail
    self.is_playing = true
    self.is_paused = false
    -- Reset elapsed-time tracking
    self._play_start_time = UIManager:getTime()
    self._pause_start_time = nil
    self._total_pause_ms = 0

    if self._use_persistent_pipeline then
        local ok = self:_playPersistentPipeline(gen)
        if ok then return true end
        logger.warn("MediaEngine: persistent pipeline play failed, falling back to standard backend")
        self._use_persistent_pipeline = false
    end

    if self.backend == self.BACKENDS.MPV then
        return self:_playMpv(gen)
    elseif self.backend == self.BACKENDS.MPLAYER then
        return self:_playMplayer(gen)
    elseif self.backend == self.BACKENDS.FFMPEG_PIPE then
        return self:_playFfmpegPipe(gen)
    elseif self.backend == self.BACKENDS.GST_PLAY then
        return self:_playGstPlay(gen)
    elseif self.backend == self.BACKENDS.GST_PIPELINE then
        return self:_playGstPipeline(gen)
    elseif self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY then
        return self:_playAplay(gen)
    elseif self.backend == self.BACKENDS.KINDLE_GST_PLAY then
        return self:_playKindleGstPlay(gen)
    elseif self.backend == self.BACKENDS.KINDLE_LIPC then
        return self:_playKindleLipc(gen)
    end

    logger.err("MediaEngine: unknown backend", self.backend)
    if on_fail then on_fail("unknown backend") end
    return false
end

--[[--
Spawn a backend command in the background, capture its PID, and start the
position poller + completion watcher.  Every spawning backend shares this
boilerplate; only the command string and a few shell knobs differ.

@param cmd   string  the shell command to run inside `sh -c`
@param gen   number  the play generation guarding the deferred PID read
@param opts  table   optional:
  name   string   label for the temp PID file and logs (default "audio")
  exec   bool     prefix the command with `exec` (default true).  Use false
                  for pipelines: `exec a | b` would replace the shell with the
                  last stage, losing the PID we just echoed.
  setsid bool     run under setsid so kill(-pid) reaches the whole group
                  (needed for ffmpeg|gst pipelines)
  quiet  bool     redirect the wrapper's stdout/stderr to /dev/null
  delay  number   seconds to wait before reading the PID file (default 0.3)
@return true
--]]
function MediaEngine:_spawnTracked(cmd, gen, opts)
    opts = opts or {}
    local name = opts.name or "audio"
    local pid_file = self:_getTempDir() .. "/" .. name .. "-pid-" .. gen
    os.remove(pid_file)

    local setsid = ""
    if opts.setsid and self:commandExists("setsid") then setsid = "setsid " end
    local exec = (opts.exec ~= false) and "exec " or ""
    local redirect = opts.quiet and " >/dev/null 2>&1" or ""
    local wrapper = string.format(
        "%ssh -c 'echo $$ > %s; %s%s'%s &",
        setsid, pid_file, exec, cmd:gsub("'", "'\\''"), redirect)
    os.execute(wrapper)

    -- Retry PID capture a few times: on slow Kindle devices the wrapper shell
    -- may not have written the PID file within the first 0.3 s, leaving the
    -- old pipeline untracked.  An untracked pipeline keeps playing across seeks
    -- and sounds like audio looping/stuttering.
    local function try_capture_pid(attempt)
        if self.play_generation ~= gen then return end
        local pf = io.open(pid_file, "r")
        local pid
        if pf then
            local pid_str = pf:read("*l")
            pf:close()
            pid = tonumber(pid_str)
        end
        if pid then
            self.audio_pid = pid
            logger.warn("MediaEngine: " .. name .. " PID =", self.audio_pid)
            os.remove(pid_file)
            self:_startPositionPoller(gen)
            self:_startCompletionWatcher(gen)
        elseif attempt < 3 then
            UIManager:scheduleIn(0.2, function()
                try_capture_pid(attempt + 1)
            end)
        else
            logger.warn("MediaEngine: " .. name .. " PID capture failed after retries")
            os.remove(pid_file)
            self:_startPositionPoller(gen)
            self:_startCompletionWatcher(gen)
        end
    end
    UIManager:scheduleIn(opts.delay or 0.3, function()
        try_capture_pid(1)
    end)

    return true
end

function MediaEngine:_playMpv(gen)
    self:_setupMpvIpc()

    local ipc_arg
    if self:_hasLuaSocket() then
        ipc_arg = string.format('--input-ipc-server="%s"', self._socket_path)
    else
        ipc_arg = string.format('--input-file="%s"', self._fifo_path)
    end

    local cmd = string.format(
        '%s %s --no-video --really-quiet --idle=no --keep-open=no "%s" &',
        self.backend_cmd,
        ipc_arg,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: mpv launch gen=", gen, "cmd=", cmd:sub(1, 200))

    -- Spawn in background and capture PID
    local pid_file = self:_getTempDir() .. "/mpv-pid-" .. gen
    os.remove(pid_file)
    local wrapper = string.format("sh -c 'echo $$ > %s; exec %s' &", pid_file, cmd)
    os.execute(wrapper)

    -- Wait briefly for PID file
    UIManager:scheduleIn(0.2, function()
        if self.play_generation ~= gen then return end
        local pf = io.open(pid_file, "r")
        if pf then
            local pid_str = pf:read("*l")
            pf:close()
            self.audio_pid = tonumber(pid_str)
            logger.warn("MediaEngine: mpv PID =", self.audio_pid)
        end
        os.remove(pid_file)
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

function MediaEngine:_playMplayer(gen)
    self._ipc_file = self:_getTempDir() .. "/mplayer-fifo-" .. gen
    os.remove(self._ipc_file)
    os.execute("mkfifo '" .. self._ipc_file:gsub("'", "'\\''") .. "'")

    local cmd = string.format(
        '%s -slave -input file="%s" -really-quiet -novideo "%s" &',
        self.backend_cmd,
        self._ipc_file,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: mplayer launch gen=", gen)
    os.execute(cmd)

    UIManager:scheduleIn(0.3, function()
        if self.play_generation ~= gen then return end
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

function MediaEngine:_playFfmpegPipe(gen)
    -- ffmpeg decodes to raw PCM; on Kobo we pipe through gstreamer
    -- to the MTK Bluetooth sink because aplay has no ALSA soundcards.
    -- We use raw s16le instead of WAV because wavparse chokes on piped
    -- WAV streams with incomplete headers.
    -- Seeking is done via process restart with -ss offset.
    -- Pause/resume uses SIGSTOP/SIGCONT on the shell PID.
    local offset = self._seek_offset or 0
    local path = self.current_path:gsub('"', '\\"')
    local ffmpeg = self.backend_cmd

    -- Detect whether to use gstreamer + mtkbtmwrpcaudiosink or fall back to aplay
    local has_mtk_sink = false
    local has_gst_launch = self:commandExists("gst-launch-1.0")
    if has_gst_launch then
        local h = io.popen("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1 && echo yes || echo no")
        if h then
            has_mtk_sink = h:read("*l") == "yes"
            h:close()
        end
    end

    -- Raw PCM format: s16le, 44100 Hz, stereo.
    -- gstreamer pipeline uses audio/x-raw caps instead of wavparse.
    local player_cmd
    if has_mtk_sink then
        player_cmd = 'gst-launch-1.0 fdsrc fd=0 ! audio/x-raw,format=S16LE,rate=44100,channels=2 ! audioconvert ! audioresample ! mtkbtmwrpcaudiosink'
    else
        player_cmd = 'aplay -f S16_LE -r 44100 -c 2'
    end

    local atempo = self:_atempoFilterString(self._playback_speed)
    -- Splice the digital volume gain into the audio filter chain.
    local vol = self._volume or 1.0
    if math.abs(vol - 1.0) >= 0.001 then
        local vf = string.format("volume=%.3f", vol)
        if atempo == "" then
            atempo = ' -filter:a "' .. vf .. '"'
        else
            atempo = atempo:gsub('"$', "," .. vf .. '"')
        end
    end
    local cmd
    if offset > 0 then
        cmd = string.format(
            'nice -n 10 "%s" -ss %d -i "%s"%s -ar 44100 -ac 2 -f s16le - 2>/dev/null | %s',
            ffmpeg, math.floor(offset), path, atempo, player_cmd
        )
    else
        cmd = string.format(
            'nice -n 10 "%s" -i "%s"%s -ar 44100 -ac 2 -f s16le - 2>/dev/null | %s',
            ffmpeg, path, atempo, player_cmd
        )
    end

    logger.warn("MediaEngine: ffmpeg-pipe launch gen=", gen,
        "offset=", offset,
        "sink=", has_mtk_sink and "mtkbtmwrpcaudiosink" or "aplay",
        "cmd=", cmd:sub(1, 200))

    -- Kill any stale ffmpeg/gst-launch processes before starting.
    -- Previous crashes can leave zombie processes that hold the MTK
    -- Bluetooth socket, causing "Address already in use" errors.
    os.execute("killall -9 ffmpeg gst-launch-1.0 2>/dev/null")

    -- exec=false: `exec a | b` would replace the shell with the last pipeline
    -- stage (gst-launch), losing the PID we capture.
    return self:_spawnTracked(cmd, gen, { name = "ffmpeg", exec = false })
end

function MediaEngine:_playGstPlay(gen)
    -- gst-play-1.0 has limited seeking; we use it for playback and
    -- implement seek via process restart at new position.
    -- On Kobo with MTK Bluetooth, force the correct audio sink.
    local sink_arg = ""
    if Device:isKobo() and os.execute("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1") == 0 then
        sink_arg = " --audiosink=mtkbtmwrpcaudiosink"
    end
    -- Best-effort time offset for seeking: append #t=<seconds> URI fragment
    local path = self.current_path:gsub('"', '\\"')
    if self._seek_offset and self._seek_offset > 0 then
        path = string.format("file://%s#t=%d", path, math.floor(self._seek_offset))
    end
    local cmd = string.format(
        '%s --quiet%s "%s"',
        self.backend_cmd,
        sink_arg,
        path
    )

    logger.warn("MediaEngine: gst-play launch gen=", gen,
        "seek_offset=", self._seek_offset or 0,
        "sink=", sink_arg ~= "" and "mtkbtmwrpcaudiosink" or "auto")

    return self:_spawnTracked(cmd, gen, { name = "gst-play" })
end

function MediaEngine:_playGstPipeline(gen)
    -- Build a decodebin pipeline for generic audio playback.
    -- Use uridecodebin when a time offset is set so GStreamer can
    -- attempt to start from that position via URI fragment (#t=).
    local sink = "autoaudiosink"
    if Device:isKobo() and os.execute("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1") == 0 then
        sink = "mtkbtmwrpcaudiosink"
    end

    local cmd
    local path = self.current_path:gsub('"', '\\"')
    if self._seek_offset and self._seek_offset > 0 then
        -- uridecodebin supports #t= URI fragments for some formats
        local uri = string.format("file://%s#t=%d", path, math.floor(self._seek_offset))
        cmd = string.format(
            '%s uridecodebin uri="%s" ! audioconvert ! audioresample ! ' ..
            '"audio/x-raw,format=S16LE,rate=48000,channels=2" ! %s',
            self.backend_cmd,
            uri,
            sink
        )
    else
        cmd = string.format(
            '%s filesrc location="%s" ! decodebin ! audioconvert ! audioresample ! ' ..
            '"audio/x-raw,format=S16LE,rate=48000,channels=2" ! %s',
            self.backend_cmd,
            path,
            sink
        )
    end

    logger.warn("MediaEngine: gst-pipeline launch gen=", gen,
        "seek_offset=", self._seek_offset or 0)

    return self:_spawnTracked(cmd, gen, { name = "gst-pipe" })
end

function MediaEngine:_playAplay(gen)
    local cmd = string.format(
        '%s "%s"',
        self.backend_cmd,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: aplay/wav-play launch gen=", gen)

    -- Set aplay start time for elapsed-time tracking
    self._aplay_start_time = UIManager:getTime()

    return self:_spawnTracked(cmd, gen, { name = "aplay" })
end

-- ---------------------------------------------------------------------------
-- Kindle-specific playback methods
-- ---------------------------------------------------------------------------

--[[--
Kill any previous audiobook pipeline spawned for the Kindle gst-launch-0.10
backends.  The ffmpeg path is identifiable by its -progress file path
containing "abk-progress", and every audiobook pipeline ends in
"mixersink stream-type=Music".  Calling this before starting a new stream
prevents two streams from mixing in mixersink, which the user hears as an
echo/loop.
--]]
function MediaEngine:_killOrphanKindleGstPipelines(name, wait_us)
    name = name or "kindle-gst"
    logger.warn("MediaEngine: killing orphan Kindle audiobook pipelines (", name, ")")
    -- ffmpeg side of the ffmpeg|gst-launch pipeline
    os.execute("pkill -9 -f 'abk-progress' 2>/dev/null")
    -- gst-launch-0.10 side: every audiobook pipeline uses mixersink with this
    -- exact stream-type.  This also kills the TTS keepalive, which restarts
    -- automatically when TTS is used again.
    os.execute("pkill -9 -f 'mixersink stream-type=Music' 2>/dev/null")
    -- Give the mixer a moment to release the old stream before the new one
    -- attaches; without this the new stream can still overlap the tail of the
    -- dying one.
    if wait_us and wait_us > 0 then
        os.execute("usleep " .. tostring(wait_us))
    end
end

--[[--
Play a WAV through the system gst-launch-0.10 with the pipeline verified
working on PW5/PW6 firmware:

    filesrc ! caps ! mixersink stream-type=Music sync=true

mixersink needs stream-type=Music (the only playback stream type audiomgrd
accepts) and sync=true: with the element's default sync=false the commit
vfunc is handed mismatched in/out sample counts, rejects every buffer
("MixerSink:Commit:in != out" in syslog) and the pipeline hangs silently.
audiomgrd must also be focused on 'Music' before the stream attaches.

Seeking is done by skipping bytes when stripping the WAV header.

@treturn boolean|nil true on launch, nil if the file is not a plain PCM WAV
    (caller should fall back to the bundled gst-play binary)
--]]
function MediaEngine:_playSystemGstLaunch(gen)
    local fh = io.open(self.current_path, "rb")
    if not fh then return nil end
    local header = fh:read(44)
    fh:close()
    if not header or #header < 44
        or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
        -- Not a plain PCM WAV (mp3/m4b/etc.): stream bundled-ffmpeg output
        -- straight into the same mixersink pipeline.
        return self:_playSystemGstLaunchFfmpeg(gen)
    end
    local function le_u16(off)
        return string.byte(header, off) + string.byte(header, off + 1) * 256
    end
    local function le_u32(off)
        return le_u16(off) + le_u16(off + 2) * 65536
    end
    local fmt = le_u16(21)
    local channels = le_u16(23)
    local rate = le_u32(25)
    local bits = le_u16(35)
    if fmt ~= 1 or channels < 1 or channels > 2 or rate == 0
        or (bits ~= 8 and bits ~= 16) then
        return nil
    end

    -- Strip header (+ seek offset) into a raw PCM temp file.
    -- tail -c +N is 1-indexed; frame-align the seek so we never start
    -- mid-sample.
    local frame_bytes = channels * (bits / 8)
    local seek_frames = math.floor((self._seek_offset or 0) * rate)
    local skip = 44 + seek_frames * frame_bytes
    if self._system_raw_file then
        os.remove(self._system_raw_file)
    end
    local raw_file = self:_getTempDir() .. "/kindle-gst-raw-" .. gen .. ".pcm"
    -- Lead-in: audiomgrd suspends the A2DP datapath while idle and resume
    -- takes a few hundred ms after the stream attaches, swallowing the
    -- start of the clip; half a second of silence up front absorbs that.
    -- Tail: at EOS the pipeline tears down while the ring buffer and BT
    -- chain still hold ~1 s of audio, cutting off the end.
    local rc = os.execute(string.format(
        "( dd if=/dev/zero bs=%d count=1 2>/dev/null;"
        .. " tail -c +%d '%s';"
        .. " dd if=/dev/zero bs=%d count=1 2>/dev/null ) > '%s' 2>/dev/null",
        -- whole frames only: a non-frame-aligned pad byte count shifts all
        -- following 16-bit samples and turns the payload into white noise
        math.floor(rate / 2) * frame_bytes,
        skip + 1,
        self.current_path:gsub("'", "'\\''"),
        rate * frame_bytes,
        raw_file:gsub("'", "'\\''")))
    if rc ~= 0 and rc ~= true then
        os.remove(raw_file)
        return nil
    end
    self._system_raw_file = raw_file
    -- What the user hears lags wall-clock position by the lead-in pad plus
    -- the mixer ring (~0.9 s) and BT chain (~0.3 s); the sync loop
    -- subtracts this so highlights match the audible audio.
    self.position_latency_s = 1.7

    -- Sweep shm stream files orphaned by pipelines killed mid-play
    -- (pause/seek), then take audio focus before the stream attaches.
    os.execute("for f in /dev/shm/mstream*; do p=${f#/dev/shm/mstream}; p=${p%%_*};"
        .. " [ -d /proc/$p ] || rm -f \"$f\"; done 2>/dev/null")
    MediaEngine._takeMusicFocusOnce()

    -- Nuke any previous audiobook gst-launch-0.10 pipeline before attaching
    -- a new stream to mixersink.  If the old pipeline is still draining its
    -- ring buffer while the new one starts, the user hears both streams as an
    -- echo/loop ("this is this is an an example example").
    self:_killOrphanKindleGstPipelines("kindle-gst-wav", 150000)

    local caps = string.format(
        "audio/x-raw-int,endianness=1234,signed=true,width=%d,depth=%d,rate=%d,channels=%d",
        bits, bits, rate, channels)
    local cmd = string.format(
        "gst-launch-0.10 filesrc location='%s' ! capsfilter caps='%s'"
        .. " ! mixersink stream-type=Music sync=true",
        raw_file:gsub("'", "'\\''"), caps)
    logger.warn("MediaEngine: system gst-launch gen=", gen,
        "rate=", rate, "ch=", channels, "seek_offset=", self._seek_offset or 0)

    return self:_spawnTracked(cmd, gen, { name = "kindle-gst", quiet = true })
end

--[[--
Play a non-WAV file (mp3/m4b/aac/...) on Kindle by streaming bundled-ffmpeg
output into the system GStreamer:

    ffmpeg -ss <seek> -i file -f s16le -ar 22050 -ac 1 -af apad=pad_dur=1 -
      | gst-launch-0.10 fdsrc ! caps ! mixersink stream-type=Music sync=true

Verified on PW5 against Storyteller EPUB audio.  No temp files, instant
start, seeking via ffmpeg -ss.  22050/mono is deliberate: audiomgrd's
output record is mono and resamples to 48 kHz anyway, and the lower input
rate keeps the decode cheap on this CPU.  apad appends the 1 s tail that
would otherwise be swallowed by the ring/BT chain at EOS.

@treturn boolean|nil true on launch, nil when ffmpeg or gst-launch are
    unavailable (caller falls back to the bundled gst-play binary)
--]]
function MediaEngine:_playSystemGstLaunchFfmpeg(gen)
    local ffmpeg = self:_findFfmpeg()
    if not ffmpeg or not self:commandExists("gst-launch-0.10") then
        return nil
    end

    -- Guarantee a single audiobook pipeline: kill any still-running ffmpeg
    -- stream before starting a new one.  PID capture is asynchronous, so a
    -- rapid restart (seek / volume change) that lands inside that window never
    -- tracks the freshly spawned pipeline; stop() then can't kill it and it
    -- keeps playing -> overlapping audio.
    self:_killOrphanKindleGstPipelines("kindle-gst-ffmpeg", 150000)

    -- Take focus after the old pipeline has had a moment to tear down.
    MediaEngine._takeMusicFocusOnce()

    local seek = self._seek_offset or 0

    -- Position is read from ffmpeg's own -progress feed (out_time) instead of
    -- wall-clock.  Because the downstream mixersink (sync=true) throttles
    -- consumption to realtime, ffmpeg is back-pressured to realtime and its
    -- out_time reflects exactly how far the decoded stream has been pushed --
    -- immune to the variable spawn/decode startup delay and to CPU stalls
    -- (if ffmpeg stalls, out_time freezes and the highlight waits instead of
    -- creeping ahead).  See getPosition() / _readLastOutTime().
    local progress_file = self:_getTempDir() .. "/abk-progress-" .. gen
    os.remove(progress_file)
    self._progress_file = progress_file
    self._use_progress_position = true
    -- adelay prepends 0.5 s of silence inside the decoded stream, so out_time
    -- is 0.5 s larger than the real content time; getPosition() subtracts it.
    self._progress_adelay_s = 0.5

    -- adelay=500: lead-in silence absorbing the A2DP datapath resume
    -- (which otherwise swallows the start); apad: tail silence covering
    -- the ring/BT buffers at EOS (which otherwise clip the end).
    local pipeline = string.format(
        "%s -loglevel error -progress '%s' -nostats -ss %.3f -i '%s'"
        .. " -f s16le -ar 22050 -ac 1"
        .. " -af adelay=500%s,apad=pad_dur=1 - 2>/dev/null"
        .. " | gst-launch-0.10 fdsrc"
        .. " ! 'audio/x-raw-int,rate=22050,channels=1,width=16,depth=16,signed=true,endianness=1234'"
        .. " ! mixersink stream-type=Music sync=true",
        ffmpeg:gsub("'", "'\\''"), progress_file:gsub("'", "'\\''"), seek,
        self.current_path:gsub("'", "'\\''"), self:_volumeFilterPart())
    -- out_time is the PRODUCER side: it leads what the listener hears by the
    -- whole downstream buffer -- OS pipe (~1.5 s when full) + gst/mixersink
    -- ring (~0.9 s) + BT chain (~0.3 s) ~= 2.7 s.  The sync loop subtracts
    -- this so highlights match the audible audio.  Single stable constant
    -- now (no variable startup mixed in); tune here if needed, the user's
    -- live nudge handles any residual.
    self.position_latency_s = 2.7
    logger.warn("MediaEngine: system gst-launch (ffmpeg stream) gen=", gen,
        "seek_offset=", seek, "progress=", progress_file)

    -- setsid: the wrapper shell becomes a process-group leader so stop()'s
    -- kill(-pid) takes down ffmpeg AND gst-launch; without it the pipeline
    -- would be orphaned and keep playing.  exec=false: it's a pipeline.
    return self:_spawnTracked(pipeline, gen,
        { name = "kindle-gst", setsid = true, exec = false, quiet = true })
end

-- ---------------------------------------------------------------------------
-- Persistent GStreamer pipeline for MTK Bluetooth (Kobo)
-- Keeps gst-launch alive across seeks and pause/resume so the exclusive
-- mtkbtmwrpcaudiosink abstract socket is never torn down.
-- ---------------------------------------------------------------------------

function MediaEngine:_writePersistentPipelineScript()
    local sr = 44100
    local channels = 2
    local silence_samples = math.floor(sr * 0.05)
    local silence_bytes = silence_samples * channels * 2
    local script = string.format([=[
#!/bin/sh
CTRL="%s"
FIFO="%s"
mkdir -p "$CTRL"
rm -f "$CTRL/stop" "$CTRL/play" "$CTRL/done" "$CTRL/gst_pid" "$CTRL/pipeline_stderr"
rm -f "$FIFO"
mkfifo "$FIFO"
# Silence chunk: ~50ms at %dHz 16-bit stereo = %d bytes
dd if=/dev/zero bs=%d count=1 of="$CTRL/s.raw" 2>/dev/null
gst-launch-1.0 filesrc location="$FIFO" \
  ! rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=%d \
  ! audioconvert ! audioresample \
  ! "audio/x-raw,format=S16LE,rate=48000,channels=2" \
  ! queue max-size-time=500000000 max-size-bytes=131072 \
  ! mtkbtmwrpcaudiosink sync=false >/dev/null 2>"$CTRL/pipeline_stderr" &
GST_PID=$!
exec 3>"$FIFO"
echo $GST_PID > "$CTRL/gst_pid"
cleanup() { exec 3>&- 2>/dev/null; kill $GST_PID 2>/dev/null; rm -f "$FIFO" "$CTRL/s.raw" "$CTRL/gst_pid" "$CTRL/pipeline_stderr"; }
trap cleanup EXIT TERM
CURRENT_FFMPEG_PID=""
while kill -0 $GST_PID 2>/dev/null && [ ! -f "$CTRL/stop" ]; do
  if [ -f "$CTRL/play" ]; then
    FILE=$(sed -n '1p' "$CTRL/play")
    OFFSET=$(sed -n '2p' "$CTRL/play")
    FILT=$(sed -n '3p' "$CTRL/play")
    rm -f "$CTRL/play" "$CTRL/done"
    if [ -n "$CURRENT_FFMPEG_PID" ]; then
      kill $CURRENT_FFMPEG_PID 2>/dev/null || true
      wait $CURRENT_FFMPEG_PID 2>/dev/null || true
      CURRENT_FFMPEG_PID=""
    fi
    if [ -n "$FILT" ]; then
      ffmpeg -ss "$OFFSET" -i "$FILE" -filter:a "$FILT" -f s16le -ar 44100 -ac 2 - >&3 2>/dev/null &
    else
      ffmpeg -ss "$OFFSET" -i "$FILE" -f s16le -ar 44100 -ac 2 - >&3 2>/dev/null &
    fi
    CURRENT_FFMPEG_PID=$!
  fi
  if [ -z "$CURRENT_FFMPEG_PID" ] || ! kill -0 $CURRENT_FFMPEG_PID 2>/dev/null; then
    CURRENT_FFMPEG_PID=""
    cat "$CTRL/s.raw" >&3
  fi
  usleep 1000
done
if [ -n "$CURRENT_FFMPEG_PID" ]; then
  kill $CURRENT_FFMPEG_PID 2>/dev/null || true
  wait $CURRENT_FFMPEG_PID 2>/dev/null || true
fi
]=], self._media_ctrl_dir, self._media_fifo, sr, silence_bytes, silence_bytes, sr, channels)
    local f = io.open(self._media_script, "w")
    if not f then return false end
    f:write(script)
    f:close()
    os.execute("chmod +x " .. self._media_script)
    return true
end

function MediaEngine:_startPersistentPipeline()
    self:_stopPersistentPipeline("restart")

    -- Wait for the exclusive MTK socket to be released.
    for attempt = 1, 5 do
        local pf = io.open("/proc/net/unix", "r")
        if pf then
            local content = pf:read("*a")
            pf:close()
            if not content:find("@kobo:mtkbtmwrpc") then
                break
            end
            logger.warn("MediaEngine: mtkbtmwrpc socket still held, attempt", attempt)
            os.execute("killall -9 gst-launch-1.0 2>/dev/null")
            os.execute("usleep 200000")
        else
            break
        end
    end

    if not self:_writePersistentPipelineScript() then
        logger.err("MediaEngine: cannot write persistent pipeline script")
        return false
    end

    os.execute("rm -f " .. self._media_ctrl_dir .. "/stop " .. self._media_ctrl_dir .. "/play " .. self._media_ctrl_dir .. "/done")

    local h = io.popen(self._media_script .. " >/dev/null 2>/dev/null & echo $!")
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    self._pipeline_wrapper_pid = tonumber(pid_str:match("(%d+)"))

    local gst_pid = nil
    for iter = 1, 60 do
        local pf = io.open(self._media_ctrl_dir .. "/gst_pid", "r")
        if pf then
            local pid = pf:read("*a")
            pf:close()
            gst_pid = tonumber((pid or ""):match("(%d+)"))
            if gst_pid then break end
        end
        os.execute("usleep 50000")
    end

    self._pipeline_gst_pid = gst_pid
    self.audio_pid = gst_pid
    self._persistent_pipeline_active = true
    -- Conservative pipe-buffer delay: assume 64KB FIFO at 44100Hz stereo 16-bit (~371ms).
    self._pipe_buffer_delay_ms = 400

    if gst_pid then
        logger.warn("MediaEngine: persistent pipeline started, wrapper=", self._pipeline_wrapper_pid, "gst=", gst_pid)
        return true
    end

    logger.err("MediaEngine: persistent pipeline failed to start")
    self:_stopPersistentPipeline("start_failed")
    return false
end

function MediaEngine:_stopPersistentPipeline(reason)
    reason = reason or "unknown"
    logger.warn("MediaEngine: _stopPersistentPipeline, reason=", reason, "gst_pid=", self._pipeline_gst_pid)

    local sf = io.open(self._media_ctrl_dir .. "/stop", "w")
    if sf then sf:write("1"); sf:close() end

    if self._pipeline_gst_pid then
        os.execute("kill -9 " .. self._pipeline_gst_pid .. " 2>/dev/null")
    end
    if self._pipeline_wrapper_pid then
        os.execute("kill -9 " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
    end
    os.execute("killall -9 gst-launch-1.0 2>/dev/null")

    if self._pipeline_wrapper_pid then
        for _ = 1, 20 do
            local pf = io.open("/proc/" .. self._pipeline_wrapper_pid .. "/status", "r")
            if not pf then break end
            pf:close()
            os.execute("usleep 50000")
        end
    end

    os.execute("rm -rf " .. self._media_ctrl_dir)
    os.execute("rm -f " .. self._media_fifo .. " " .. self._media_script)

    self._pipeline_gst_pid = nil
    self._pipeline_wrapper_pid = nil
    self._persistent_pipeline_active = false
end

function MediaEngine:_playPersistentPipeline(gen)
    if not self._persistent_pipeline_active then
        if not self:_startPersistentPipeline() then
            logger.err("MediaEngine: persistent pipeline unavailable, disabling for this session")
            self._use_persistent_pipeline = false
            return false
        end
    end

    local filter_arg = self:_atempoFilterString(self._playback_speed or 1.0)
    local filter_chain = filter_arg:match('-filter:a%s*"(.-)"') or ""

    os.remove(self._media_ctrl_dir .. "/done")
    local f = io.open(self._media_ctrl_dir .. "/play", "w")
    if not f then
        logger.err("MediaEngine: cannot write play control file")
        return false
    end
    f:write(self.current_path .. "\n")
    f:write(tostring(self._seek_offset or 0) .. "\n")
    f:write(filter_chain .. "\n")
    f:close()

    self._play_start_time = UIManager:getTime()
    self._pause_start_time = nil
    self._total_pause_ms = 0
    self.is_playing = true
    self.is_paused = false

    self:_startPositionPoller(gen)
    if self.current_duration and self.current_duration > 0 then
        self:_startPersistentCompletionWatcher(gen, self.current_duration)
    else
        logger.warn("MediaEngine: unknown duration, skipping completion watcher for persistent pipeline")
    end

    return true
end

function MediaEngine:_startPersistentCompletionWatcher(gen, duration)
    duration = duration or 0
    local pipe_delay_ms = self._pipe_buffer_delay_ms or 400
    local engine = self
    local function check()
        if engine.play_generation ~= gen then return end
        if not engine.is_playing then return end
        if engine.is_paused then
            UIManager:scheduleIn(0.5, check)
            return
        end
        if engine._play_start_time then
            local wall_ms = time.to_ms(UIManager:getTime() - engine._play_start_time)
            local real_ms = wall_ms - (engine._total_pause_ms or 0)
            local needed_ms = duration * 1000 + pipe_delay_ms + 500
            if real_ms < needed_ms then
                local wait_s = (needed_ms - real_ms) / 1000
                if wait_s < 0.2 then wait_s = 0.2 end
                UIManager:scheduleIn(wait_s, check)
                return
            end
        end
        logger.warn("MediaEngine: persistent pipeline playback complete")
        engine.is_playing = false
        engine.is_paused = false
        if engine._on_complete then
            local cb = engine._on_complete
            engine._on_complete = nil
            cb()
        end
    end
    local initial_delay_s = duration + (pipe_delay_ms / 1000) + 0.5
    UIManager:scheduleIn(initial_delay_s, check)
end

function MediaEngine:_playKindleGstPlay(gen)
    -- Prefer the system gst-launch-0.10 pipeline (verified working on
    -- PW5/PW6, see _playSystemGstLaunch).  The bundled gst-play binary
    -- sets neither stream-type nor sync on mixersink and hangs on these
    -- firmwares.  Fall back to it only for non-PCM-WAV input or when
    -- gst-launch-0.10 is missing.
    if self:commandExists("gst-launch-0.10") then
        local ok = self:_playSystemGstLaunch(gen)
        if ok then return ok end
    end

    if not (self._gst_play_cmd or self.backend_cmd) then
        -- Diagnose the most common Kindle failure: the file is not a plain
        -- PCM WAV and the bundled ffmpeg decoder is missing.  The system
        -- GStreamer on these devices has no mp3/aac/wavparse plugins, so
        -- without ffmpeg there is no way to decode Audiobookshelf tracks.
        local is_wav = false
        local fh = io.open(self.current_path, "rb")
        if fh then
            local header = fh:read(12)
            fh:close()
            is_wav = header and #header >= 12
                and header:sub(1, 4) == "RIFF"
                and header:sub(9, 12) == "WAVE"
        end
        local has_ffmpeg = self:_findFfmpeg() ~= nil
        logger.err("MediaEngine: no bundled gst-play and system pipeline failed",
            "is_wav=", is_wav, "has_ffmpeg=", has_ffmpeg)
        if self._on_fail then
            if not is_wav and not has_ffmpeg then
                self._on_fail(_("Cannot play this audio file. Kindle's GStreamer can only play raw PCM WAV files; MP3/M4B/AAC files need the bundled ffmpeg decoder. Please install the release .zip (not 'Source code') from GitHub so plugins/audiobook.koplugin/bin/ffmpeg is present."))
            else
                self._on_fail("no usable Kindle audio pipeline")
            end
        end
        return false
    end

    -- kindle/gst-play: a custom binary that feeds raw PCM to GStreamer's
    -- mixersink element, bypassing the missing wavparse on stripped firmware.
    -- The binary reads WAV files, strips the header, and pipes PCM to
    -- mixersink → audiomgrd → BT headphones.
    --
    -- Seeking: use the --seek=<seconds> argument.  Re-launch on seek.
    local gst_cmd = self._gst_play_cmd or self.backend_cmd

    -- Add seek offset if present
    local args = ""
    if self._seek_offset and self._seek_offset > 0 then
        args = string.format(" --seek=%d", math.floor(self._seek_offset))
    end

    local path = self.current_path:gsub('"', '\\"')
    local cmd = string.format(
        '%s%s "%s"',
        gst_cmd,
        args,
        path
    )
    logger.warn("MediaEngine: kindle-gst-play launch gen=", gen,
        "seek_offset=", self._seek_offset or 0)

    return self:_spawnTracked(cmd, gen, { name = "kindle-gst" })
end

function MediaEngine:_playKindleLipc(gen)
    -- Kindle LIPC: use Amazon's playermgr service via lipc-set-prop
    -- to play audio files.  playermgr uses GStreamer internally and
    -- routes audio through audiomgrd → BT headphones.
    --
    -- Seeking: seek-by-restart using Open + Play with the requested
    -- time offset approximated by InPlayback polling.
    --
    -- Supported file formats: MP3, AAC, possibly WAV (depends on
    -- wavparse availability in the device's GStreamer installation).
    -- The transcoder in main.lua already converts unsupported formats
    -- to MP3 or WAV before reaching MediaEngine.

    local file_path = self.current_path

    -- Stop any previous playback first
    os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")

    -- Request audio focus from audiomgrd
    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'audiobook' 2>/dev/null")

    -- Enable GStreamer debug logging
    os.execute("lipc-set-prop com.lab126.playermgr gstLogLevel 2 2>/dev/null")

    -- Helper to run LIPC commands and capture output
    local function lipc_cmd(cmd)
        local h = io.popen(cmd .. " 2>&1")
        local out = ""
        if h then out = h:read("*a") or ""; h:close() end
        return out
    end

    -- Try multiple strategies to start playback:
    local file_uri = "file://" .. file_path
    local started = false
    local strategies = {
        {name = "Open(URI)+Play", cmd1 = string.format(
            "lipc-set-prop com.lab126.playermgr Open '%s'", file_uri),
            cmd2 = "lipc-set-prop com.lab126.playermgr Play ''"},
        {name = "Open(path)+Play", cmd1 = string.format(
            "lipc-set-prop com.lab126.playermgr Open '%s'", file_path),
            cmd2 = "lipc-set-prop com.lab126.playermgr Play ''"},
        {name = "Play(URI)", cmd1 = "", cmd2 = string.format(
            "lipc-set-prop com.lab126.playermgr Play '%s'", file_uri)},
        {name = "Play(path)", cmd1 = "", cmd2 = string.format(
            "lipc-set-prop com.lab126.playermgr Play '%s'", file_path)},
    }

    for _, s in ipairs(strategies) do
        if started then break end
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        if s.cmd1 ~= "" then
            local out1 = lipc_cmd(s.cmd1)
            logger.warn("MediaEngine: kindle-lipc", s.name, "Open:", out1)
        end
        local out2 = lipc_cmd(s.cmd2)
        logger.warn("MediaEngine: kindle-lipc", s.name, "Play:", out2)

        -- Check if playback started
        local in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
        started = in_play:match("^%s*(%d+)") == "1"
        logger.warn("MediaEngine: kindle-lipc InPlayback:", in_play, "for strategy:", s.name)
    end

    if not started then
        logger.err("MediaEngine: Kindle LIPC -- none of 4 strategies got InPlayback=1")
        -- Try fallback to gst-play once
        if self._gst_play_cmd and not self._lipc_fallback_tried then
            self._lipc_fallback_tried = true
            logger.warn("MediaEngine: kindle-lipc failed, falling back to kindle-gst-play")
            self.backend = self.BACKENDS.KINDLE_GST_PLAY
            self.backend_cmd = self._gst_play_cmd
            return self:_playKindleGstPlay(gen)
        end
        self.is_playing = false
        if self._on_fail then
            local cb = self._on_fail
            self._on_fail = nil
            cb("kindle-lipc playback failed")
        end
        return false
    end

    self._lipc_fallback_tried = false
    self._audio_launched_at = UIManager:getTime()
    logger.warn("MediaEngine: kindle-lipc playback started")

    self:_startPositionPoller(gen)

    -- For Kindle LIPC, completion is detected by polling the InPlayback
    -- property instead of PID-based process watcher (playermgr is a
    -- system daemon, not a child process we spawned).
    local engine = self
    local poll_count = 0
    local dur_ms = (self.current_duration or 3600) * 1000
    local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
    local startup_polls = 5
    local ever_playing = false
    local function pollLipcDone()
        if engine.play_generation ~= gen then return end
        if not engine.is_playing then return end
        if engine.is_paused then
            UIManager:scheduleIn(0.3, pollLipcDone)
            return
        end
        poll_count = poll_count + 1
        if poll_count > startup_polls then
            local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
            if h then
                local val = h:read("*a") or ""
                h:close()
                val = val:match("(%d+)")
                if val and tonumber(val) == 1 then
                    ever_playing = true
                elseif val and tonumber(val) == 0 then
                    local elapsed_ms = 0
                    if engine._audio_launched_at then
                        elapsed_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                            - (engine._total_pause_ms or 0)
                    end
                    if ever_playing then
                        -- Was playing, now stopped → playback completed normally
                        logger.warn("MediaEngine: Kindle LIPC playback complete, elapsed=",
                            elapsed_ms, "ms")
                        engine.is_playing = false
                        if engine._on_complete then
                            local cb = engine._on_complete
                            engine._on_complete = nil
                            cb()
                        end
                        return
                    elseif elapsed_ms > 5000 then
                        -- Never started playing after 5 seconds → failure
                        logger.err("MediaEngine: Kindle LIPC playback never started, elapsed=",
                            elapsed_ms, "ms")
                        engine.is_playing = false
                        if engine._on_fail then
                            local cb = engine._on_fail
                            engine._on_fail = nil
                            cb("playback never started")
                        end
                        return
                    end
                end
            end
        end
        if poll_count > max_polls then
            logger.warn("MediaEngine: Kindle LIPC max polls reached, forcing stop")
            engine.is_playing = false
            if engine._on_complete then
                local cb = engine._on_complete
                engine._on_complete = nil
                cb()
            end
            return
        end
        UIManager:scheduleIn(0.1, pollLipcDone)
    end
    UIManager:scheduleIn(0.1, pollLipcDone)
    return true
end

-- ---------------------------------------------------------------------------
-- Position polling
-- ---------------------------------------------------------------------------

function MediaEngine:_startPositionPoller(gen)
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    local function poll()
        if self.play_generation ~= gen or not self.is_playing then
            return
        end
        -- Poll at 1Hz for position updates (e-ink friendly rate)
        self._position_timer = UIManager:scheduleIn(1.0, poll)
    end

    self._position_timer = UIManager:scheduleIn(1.0, poll)
end

function MediaEngine:_startCompletionWatcher(gen)
    -- Watch for process exit via PID polling
    local function check()
        if self.play_generation ~= gen then return end
        if not self.is_playing then return end

        -- Check if process is still alive
        if self.audio_pid then
            local h = io.open("/proc/" .. self.audio_pid .. "/status", "r")
            if not h then
                -- Process exited
                self.is_playing = false
                self.is_paused = false
                self.audio_pid = nil
                if self._on_complete then
                    local cb = self._on_complete
                    self._on_complete = nil
                    cb()
                end
                return
            end
            h:close()
        end

        -- For backends without IPC, estimate completion from elapsed time.
        -- Skip this on the ffmpeg -progress path: out_time is the producer
        -- side and reaches the end while ~the downstream buffer is still
        -- draining, so a position>=duration test would clip each chapter's
        -- tail.  There, completion is driven purely by PID exit above (the
        -- wrapper shell lives until gst-launch finishes actual playout).
        if (self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY
            or self.backend == self.BACKENDS.GST_PLAY or self.backend == self.BACKENDS.GST_PIPELINE
            or self.backend == self.BACKENDS.KINDLE_GST_PLAY)
            and not self._use_progress_position
            and self._play_start_time and self.current_duration then
            local pos = self:getPosition()
            if pos >= self.current_duration then
                self.is_playing = false
                self.is_paused = false
                if self._on_complete then
                    local cb = self._on_complete
                    self._on_complete = nil
                    cb()
                end
                return
            end
        end

        UIManager:scheduleIn(0.5, check)
    end

    UIManager:scheduleIn(1.0, check)
end

-- ---------------------------------------------------------------------------
-- Pause / Resume / Stop
-- ---------------------------------------------------------------------------

function MediaEngine:pause()
    if not self.is_playing or self.is_paused then return end
    self.is_paused = true
    self._pause_start_time = UIManager:getTime()

    if self._persistent_pipeline_active then
        if self._pipeline_gst_pid and ffi.C.kill then
            ffi.C.kill(self._pipeline_gst_pid, 19) -- SIGSTOP on gst-launch only
            logger.warn("MediaEngine: paused persistent pipeline, gst=", self._pipeline_gst_pid)
        end
        return
    end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "pause", true}})
        elseif self._fifo_path then
            self:_mpvSendFifo("set pause yes")
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write("pause\n")
                f:close()
            end
        end
    elseif self.audio_pid and ffi.C.kill then
        -- Signal the whole process group: for the ffmpeg|gst-launch
        -- pipeline audio_pid is a setsid'd wrapper shell, and stopping
        -- only the shell leaves both pipeline halves playing.
        ffi.C.kill(-self.audio_pid, 19) -- SIGSTOP group
        ffi.C.kill(self.audio_pid, 19)  -- SIGSTOP pid (non-leader case)
    end
end

function MediaEngine:resume()
    if not self.is_playing or not self.is_paused then return end
    self.is_paused = false
    if self._pause_start_time then
        self._total_pause_ms = self._total_pause_ms + time.to_ms(UIManager:getTime() - self._pause_start_time)
        self._pause_start_time = nil
    end

    if self._persistent_pipeline_active then
        if self._pipeline_gst_pid and ffi.C.kill then
            ffi.C.kill(self._pipeline_gst_pid, 18) -- SIGCONT on gst-launch only
            logger.warn("MediaEngine: resumed persistent pipeline, gst=", self._pipeline_gst_pid)
        end
        return
    end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "pause", false}})
        elseif self._fifo_path then
            self:_mpvSendFifo("set pause no")
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write("pause\n")
                f:close()
            end
        end
    elseif self.backend == self.BACKENDS.KINDLE_LIPC then
        -- Kindle playermgr: Resume (set Play again)
        os.execute("lipc-set-prop com.lab126.playermgr Play '' 2>/dev/null")
    elseif self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE
        or self.backend == self.BACKENDS.KINDLE_GST_PLAY then
        -- After a paused seek the process was killed; restart it.
        if self.audio_pid and ffi.C.kill then
            ffi.C.kill(-self.audio_pid, 18) -- SIGCONT group
        ffi.C.kill(self.audio_pid, 18)  -- SIGCONT pid
        else
            self:play(self._on_complete, self._on_fail)
        end
    elseif self.audio_pid and ffi.C.kill then
        ffi.C.kill(-self.audio_pid, 18) -- SIGCONT group
        ffi.C.kill(self.audio_pid, 18)  -- SIGCONT pid
    end
end

function MediaEngine:stop()
    self:_nextGeneration()
    self.is_playing = false
    self.is_paused = false

    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    if self._persistent_pipeline_active then
        self:_stopPersistentPipeline("stop")
    end

    -- Kill audio process (for most backends).
    -- Kill the process group first so ffmpeg/gst-launch children inside
    -- the shell pipeline also receive the signal.  Fall back to the
    -- individual PID if the group kill fails.
    local dying_pid = self.audio_pid
    if dying_pid then
        if ffi.C.kill then
            ffi.C.kill(-dying_pid, 15) -- SIGTERM to process group
            ffi.C.kill(dying_pid, 15)  -- SIGTERM to shell itself
            UIManager:scheduleIn(0.3, function()
                local h = io.open("/proc/" .. dying_pid .. "/status", "r")
                if h then
                    h:close()
                    ffi.C.kill(-dying_pid, 9) -- SIGKILL to group
                    ffi.C.kill(dying_pid, 9)  -- SIGKILL to shell
                end
            end)
        end
        self.audio_pid = nil
    end

    -- Fallback for slow Kindle boots where PID capture failed: nuke any orphan
    -- pipelines we may have spawned, otherwise seek-by-restart leaves the old
    -- audio running and the user hears overlapping/looping audio.
    if self.backend == self.BACKENDS.KINDLE_GST_PLAY then
        if not dying_pid and not ffi.C.kill then
            logger.warn("MediaEngine: ffi.C.kill unavailable; relying on pkill fallback for Kindle gst")
        end
        self:_killOrphanKindleGstPipelines("stop")
    end

    -- Remove the raw PCM temp file created by _playSystemGstLaunch
    if self._system_raw_file then
        os.remove(self._system_raw_file)
        self._system_raw_file = nil
    end

    -- Remove the ffmpeg -progress feed and disable progress-based position
    -- tracking; the next play() re-enables it if it takes that path.
    if self._progress_file then
        os.remove(self._progress_file)
        self._progress_file = nil
    end
    self._use_progress_position = false

    -- For mplayer, also send quit command
    if self.backend == self.BACKENDS.MPLAYER and self._ipc_file then
        local f = io.open(self._ipc_file, "w")
        if f then
            f:write("quit\n")
            f:close()
        end
    end

    -- For mpv, send quit via IPC
    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            pcall(function()
                self:_mpvSendIpc({command = {"quit"}})
            end)
        elseif self._fifo_path then
            self:_mpvSendFifo("quit")
        end
    end

    -- For Kindle LIPC, tell playermgr to stop
    if self.backend == self.BACKENDS.KINDLE_LIPC then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end

    self:_cleanupIpc()
    self._on_complete = nil
    self._on_fail = nil
    self._play_start_time = nil
    self._aplay_start_time = nil
    self._pause_start_time = nil
    self._total_pause_ms = 0
    -- NOTE: do NOT reset _seek_offset here.
    -- GST backends use seek-by-restart: seek() sets _seek_offset, calls stop(),
    -- then schedules play().  If we zero it here, the restart loses its target.
    -- _seek_offset is reset in load() when a new file is loaded.
end

-- ---------------------------------------------------------------------------
-- Seeking
-- ---------------------------------------------------------------------------

function MediaEngine:seek(seconds, mode)
    mode = mode or "absolute"

    -- Non-seekable backends
    if self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY then
        logger.warn("MediaEngine: seek not supported on", self.backend)
        return false
    end

    -- Remember whether we were actually playing (not paused) so we can stay
    -- paused after a seek.  is_playing stays true when paused; is_paused is
    -- the real indicator.
    local was_playing = self.is_playing and not self.is_paused

    if self.backend == self.BACKENDS.MPV then
        local mode_str = mode == "relative" and "relative" or "absolute"
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"seek", seconds, mode_str}})
            return true
        elseif self._fifo_path then
            local cmd = string.format("seek %f %s", seconds, mode_str)
            return self:_mpvSendFifo(cmd)
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        local cmd
        if mode == "relative" then
            cmd = string.format("seek %f 0", seconds) -- 0 = relative seconds
        else
            cmd = string.format("seek %f 2", seconds) -- 2 = absolute seconds
        end
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write(cmd .. "\n")
                f:close()
                return true
            end
        end
    elseif self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE
        or self.backend == self.BACKENDS.KINDLE_GST_PLAY
        or self.backend == self.BACKENDS.FFMPEG_PIPE then
        -- For relative seeks, compute target from current position.
        local target = seconds
        if mode == "relative" then
            target = self:getPosition() + seconds
        end
        target = math.max(0, target)

        if self._persistent_pipeline_active then
            logger.warn("MediaEngine: persistent-pipeline seek mode=", mode,
                "req=", seconds, "current=", self:getPosition(),
                "target=", target, "was_playing=", was_playing)
            self._seek_offset = target
            self._play_start_time = UIManager:getTime()
            self._total_pause_ms = 0
            self._pause_start_time = nil
            -- Cancel old completion watcher.
            self:_nextGeneration()
            local new_gen = self.play_generation
            -- Write new play control with the target offset.
            local filter_arg = self:_atempoFilterString(self._playback_speed or 1.0)
            local filter_chain = filter_arg:match('-filter:a%s*"(.-)"') or ""
            os.remove(self._media_ctrl_dir .. "/done")
            local f = io.open(self._media_ctrl_dir .. "/play", "w")
            if f then
                f:write(self.current_path .. "\n")
                f:write(tostring(target) .. "\n")
                f:write(filter_chain .. "\n")
                f:close()
            end
            -- Preserve paused state.
            if not was_playing then
                self.is_playing = true
                self.is_paused = true
                self._pause_start_time = UIManager:getTime()
            else
                self.is_playing = true
                self.is_paused = false
            end
            self:_startPersistentCompletionWatcher(new_gen, self.current_duration)
            return true
        end

        -- Seek via process restart with time offset.
        logger.warn("MediaEngine: seek-by-restart mode=", mode, "req=", seconds,
            "current=", self:getPosition(), "target=", target,
            "was_playing=", was_playing, "backend=", self.backend)
        -- Preserve callbacks before stop() nils them.
        local saved_on_complete = self._on_complete
        local saved_on_fail = self._on_fail
        self._seek_offset = target
        self._play_start_time = UIManager:getTime()
        self._total_pause_ms = 0
        self._pause_start_time = nil
        self:stop()
        -- Capture the generation AFTER stop() (stop bumps it).  The scheduled
        -- restart fires unless something else supersedes it in the 0.5 s gap
        -- (another seek/stop/play, which bumps the generation again).  NOTE:
        -- capturing before stop() made this guard always true -> the restart
        -- was always cancelled, so seeks (and volume changes, which seek to
        -- re-apply the gain) silently killed playback.
        local restart_gen = self.play_generation
        -- Only restart playback if we were actually playing before the seek.
        -- When paused, restore the paused state so resume() can restart us.
        if was_playing then
            UIManager:scheduleIn(0.5, function()
                if self.play_generation ~= restart_gen then
                    logger.dbg("MediaEngine: seek restart cancelled (generation changed)")
                    return
                end
                self:play(saved_on_complete, saved_on_fail)
            end)
        else
            self.is_playing = true
            self.is_paused = true
            self._on_complete = saved_on_complete
            self._on_fail = saved_on_fail
            self._play_start_time = UIManager:getTime()
            self._pause_start_time = UIManager:getTime()
        end
        return true
    elseif self.backend == self.BACKENDS.KINDLE_LIPC then
        -- Seek via re-open at new position.  Kindle playermgr does not
        -- support direct seeking; we stop and restart via Open+Play.
        local target = seconds
        if mode == "relative" then
            target = self:getPosition() + seconds
        end
        target = math.max(0, target)
        logger.warn("MediaEngine: Kindle LIPC seek mode=", mode, "req=", seconds,
            "current=", self:getPosition(), "target=", target,
            "was_playing=", was_playing)
        local saved_on_complete = self._on_complete
        local saved_on_fail = self._on_fail
        self._seek_offset = target
        self._play_start_time = UIManager:getTime()
        self._total_pause_ms = 0
        self._pause_start_time = nil
        self:stop()
        -- Capture generation AFTER stop() (see the GST branch above for why).
        local lipc_restart_gen = self.play_generation
        -- Restart playback at new position
        if was_playing then
            UIManager:scheduleIn(0.5, function()
                if self.play_generation ~= lipc_restart_gen then
                    logger.dbg("MediaEngine: Kindle LIPC seek restart cancelled")
                    return
                end
                self:play(saved_on_complete, saved_on_fail)
            end)
        else
            self.is_playing = true
            self.is_paused = true
            self._on_complete = saved_on_complete
            self._on_fail = saved_on_fail
            self._play_start_time = UIManager:getTime()
            self._pause_start_time = UIManager:getTime()
        end
        return true
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Position / Duration queries
-- ---------------------------------------------------------------------------

--- Read the latest out_time from ffmpeg's -progress feed (see
--- _playSystemGstLaunchFfmpeg).  Tails the file so it stays cheap even for a
--- multi-hour book.  Returns seconds into the decoded stream, or nil if the
--- feed has not produced a numeric timestamp yet.
function MediaEngine:_readLastOutTime()
    local path = self._progress_file
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    if not size or size == 0 then f:close(); return nil end
    local back = (size > 4096) and 4096 or size
    f:seek("set", size - back)
    local tail = f:read("*a") or ""
    f:close()
    -- ffmpeg emits "out_time=HH:MM:SS.ffffff" per progress block (and
    -- "out_time=N/A" before the first frame, which the numeric pattern skips).
    -- Take the LAST match.
    local last
    for h, m, s in tail:gmatch("out_time=(%d+):(%d+):([%d%.]+)") do
        last = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    return last
end

function MediaEngine:getPosition()
    -- During a seek gap (after stop, before play restarts), return the seek
    -- offset so the UI doesn't flicker back to zero.
    if not self.is_playing then
        if self._seek_offset and self._seek_offset > 0 then
            return self._seek_offset
        end
        return 0
    end

    -- ffmpeg -progress backed position (EPUB read-along path): anchored to the
    -- actual decoded-stream progress rather than wall-clock, so startup jitter
    -- and stalls don't leak into the highlight.
    if self._use_progress_position then
        local ot = self:_readLastOutTime()
        if ot then
            return (self._seek_offset or 0)
                + math.max(0, ot - (self._progress_adelay_s or 0))
        end
        -- No numeric out_time yet.  Hold at seek_offset during the brief
        -- intro/startup (mirrors the iPad sitting on the first line until
        -- narration begins).  If ffmpeg never produces a feed (e.g. a build
        -- without -progress), fall through to the wall-clock estimate after a
        -- grace period so the UI never freezes permanently.
        local ok, elapsed_ms = pcall(function()
            return time.to_ms(UIManager:getTime()
                - (self._play_start_time or UIManager:getTime()))
        end)
        if not (ok and elapsed_ms and elapsed_ms > 3000) then
            return self._seek_offset or 0
        end
        -- else: fall through to wall-clock below
    end

    -- For backends without IPC (gst-play, aplay, ffmpeg-pipe), estimate from elapsed time.
    -- Scale elapsed real time by playback speed so the reported position tracks the
    -- actual audio position when atempo / speed filters are in use.
    if self._play_start_time then
        local ok, elapsed_ms = pcall(function()
            if self.is_paused and self._pause_start_time then
                return time.to_ms(self._pause_start_time - self._play_start_time) - self._total_pause_ms
            else
                return time.to_ms(UIManager:getTime() - self._play_start_time) - self._total_pause_ms
            end
        end)
        if ok and elapsed_ms then
            local speed = self._playback_speed or 1.0
            local pos = math.max(0, elapsed_ms / 1000) * speed + (self._seek_offset or 0)
            pos = math.min(pos, self.current_duration or pos)
            logger.dbg("MediaEngine: getPosition elapsed=", elapsed_ms, "offset=", self._seek_offset,
                "speed=", speed, "pos=", pos)
            return pos
        else
            logger.warn("MediaEngine: getPosition elapsed-time failed, ok=", ok, "err=", elapsed_ms)
        end
        -- Fall through to other methods if elapsed-time fails
    end

    -- For aplay legacy fallback
    if (self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY)
        and self._aplay_start_time then
        local ok, elapsed = pcall(function()
            return time.to_ms(UIManager:getTime() - self._aplay_start_time) / 1000
        end)
        if ok and elapsed then
            return math.min(elapsed, self.current_duration or elapsed)
        end
    end

    -- Try mpv IPC for accurate position
    if self.backend == self.BACKENDS.MPV and self:_hasLuaSocket() and self._socket_path then
        local resp = self:_mpvSendIpc({command = {"get_property", "time-pos"}}, 300)
        if resp and resp.data then
            local pos = tonumber(resp.data)
            if pos then return pos end
        end
    end

    -- Try mplayer slave mode
    if self.backend == self.BACKENDS.MPLAYER and self._ipc_file then
        local f = io.open(self._ipc_file, "w")
        if f then
            f:write("get_time_pos\n")
            f:close()
        end
        -- Response comes asynchronously; we'd need a reader thread.
        -- For now, return estimated position.
    end

    return 0
end

function MediaEngine:getDuration()
    return self.current_duration or 0
end

function MediaEngine:isPlaying()
    return self.is_playing
end

function MediaEngine:isPaused()
    return self.is_paused
end

-- ---------------------------------------------------------------------------
-- Playback speed (mpv / mplayer only)
-- ---------------------------------------------------------------------------

function MediaEngine:setSpeed(speed)
    speed = tonumber(speed) or 1.0
    if speed < 0.5 then speed = 0.5 end
    if speed > 3.0 then speed = 3.0 end
    local old_speed = self._playback_speed or 1.0
    self._playback_speed = speed

    if not self.is_playing then return end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "speed", speed}})
        elseif self._fifo_path then
            self:_mpvSendFifo(string.format("set speed %f", speed))
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write(string.format("speed_set %f\n", speed))
                f:close()
            end
        end
    elseif self.backend == self.BACKENDS.FFMPEG_PIPE
        or self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE then
        -- ffmpeg-pipe and the persistent MTK pipeline support speed only via
        -- the atempo filter, so restart at the current position when speed changes.
        if math.abs(speed - old_speed) >= 0.01 then
            local pos = self:getPosition() or 0
            logger.warn("MediaEngine: restarting pipeline for speed change",
                old_speed, "->", speed, "at pos", pos)
            self:seek(pos, "absolute")
        end
    end
    -- aplay / wav-play / Kindle do not support speed control
end

function MediaEngine:getSpeed()
    return self._playback_speed or 1.0
end

-- ---------------------------------------------------------------------------
-- Playback volume (digital gain)
-- ---------------------------------------------------------------------------

--- Comma-prefixed ffmpeg `volume` filter fragment, or "" at unity gain.
-- Meant to be spliced into an existing -af / -filter:a chain.
function MediaEngine:_volumeFilterPart()
    local v = self._volume or 1.0
    if math.abs(v - 1.0) < 0.001 then return "" end
    return string.format(",volume=%.3f", v)
end

--- Set playback volume as a percentage (0..100).
-- mpv/mplayer adjust live; the pipeline backends (ffmpeg/gst/kindle) restart
-- at the current position so the new gain takes effect, mirroring how speed
-- changes are handled.  Called before play() it just records the level, so the
-- initial spawn already carries it (no restart).
function MediaEngine:setVolume(pct)
    pct = tonumber(pct) or 100
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local v = pct / 100
    if math.abs(v - (self._volume or 1.0)) < 0.001 then return end
    self._volume = v

    if not self.is_playing then return end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "volume", pct}})
        elseif self._fifo_path then
            self:_mpvSendFifo(string.format("set volume %d", pct))
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then f:write(string.format("volume %d 1\n", pct)); f:close() end
        end
    else
        -- ffmpeg-pipe / gst / kindle: the gain is baked into the decode
        -- pipeline, so restart to apply it.  Restart at the AUDIBLE position:
        -- getPosition() is the producer/decode position, which leads the
        -- listener by position_latency_s, so seeking to the raw value would
        -- skip the audio still in flight (~2.7 s jump forward every change).
        if not self.is_paused then
            local pos = (self:getPosition() or 0) - (self.position_latency_s or 0)
            self:seek(math.max(0, pos), "absolute")
        end
    end
end

function MediaEngine:getVolume()
    return math.floor((self._volume or 1.0) * 100 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Chapter support (via m4bparser integration)
-- ---------------------------------------------------------------------------

function MediaEngine:setChapters(chapters)
    -- chapters: array of {title, start_time, end_time}
    self._chapters = chapters
end

function MediaEngine:getChapters()
    return self._chapters or {}
end

function MediaEngine:seekToChapter(index)
    local chapters = self._chapters
    if not chapters or not chapters[index] then return false end
    return self:seek(chapters[index].start_time, "absolute")
end

return MediaEngine
