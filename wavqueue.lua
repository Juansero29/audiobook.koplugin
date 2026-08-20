--[[--
Lookahead audio queue for Android TTS (WAV) and ElevenLabs (MP3).

Synthesizes upcoming sentences in the background (Java thread pool for
HTTPS, TTS worker for system voices) so playback can stay 4–5 sentences
ahead instead of stalling at every sentence boundary.

Never logs book text or API keys.

@module wavqueue
--]]

local logger = require("logger")
local UIManager = require("ui/uimanager")

local function dlog(...)
    local DL = package.loaded["audiobook_debuglog"]
    if DL and DL.log then
        pcall(DL.log, ...)
    end
end

local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local WavUtils = dofile(_dir .. "wavutils.lua")
local ElevenLabs = dofile(_dir .. "elevenlabs.lua")

local WavQueue = {}

WavQueue.LOOKAHEAD = 5
WavQueue.ELEVEN_PARALLEL = 3
WavQueue.ANDROID_PARALLEL = 1

function WavQueue:new(opts)
    local o = opts or {}
    setmetatable(o, self)
    self.__index = self
    o.engine = o.engine
    o._order = {}
    o._by_text = {}
    o._inflight = 0
    o._seq = 0
    o._gen = 0
    o._poll_on = false
    return o
end

local function tempDir(engine)
    local dir = "/tmp"
    if engine and engine._android_tts and engine._android_tts.getTempDir then
        dir = engine._android_tts:getTempDir() or dir
    elseif engine and engine.plugin then
        dir = "/sdcard/koreader/cache"
    end
    return dir
end

function WavQueue:_destPath()
    self._seq = (self._seq or 0) + 1
    local ext = (self:_kind() == "elevenlabs") and ".mp3" or ".wav"
    return tempDir(self.engine) .. "/audiobook_q_" .. tostring(os.time())
        .. "_" .. tostring(self._seq) .. ext
end

function WavQueue:_kind()
    local b = self.engine and self.engine.backend
    local B = self.engine and self.engine.BACKENDS
    if B and b == B.ELEVENLABS then return "elevenlabs" end
    if B and b == B.ANDROID then return "android" end
    return nil
end

function WavQueue:_maxParallel()
    if self:_kind() == "elevenlabs" then return WavQueue.ELEVEN_PARALLEL end
    return WavQueue.ANDROID_PARALLEL
end

function WavQueue:_moveToFront(text)
    for i, t in ipairs(self._order) do
        if t == text then
            if i == 1 then return end
            table.remove(self._order, i)
            table.insert(self._order, 1, text)
            return
        end
    end
end

function WavQueue:enqueue(text, dest_path, opts)
    if type(text) ~= "string" or text:match("^%s*$") then return end
    if not self:_kind() then return end
    local front = opts and opts.front
    local e = self._by_text[text]
    if e then
        -- Current sentence must jump ahead of lookahead (one Android worker).
        if front and e.status == "queued" then
            self:_moveToFront(text)
            self:kick()
        end
        return
    end
    local path = dest_path or self:_destPath()
    if self:_kind() == "elevenlabs" and type(path) == "string" then
        path = path:gsub("%.wav$", ".mp3")
        if not path:match("%.mp3$") and not path:match("%.wav$") then
            path = path .. ".mp3"
        end
    end
    e = {
        text = text,
        path = path,
        status = "queued",
        job_id = nil,
        timing = nil,
        dur_ms = 0,
    }
    self._by_text[text] = e
    if front then
        table.insert(self._order, 1, text)
    else
        table.insert(self._order, text)
    end
    self:kick()
end

function WavQueue:_nextQueued()
    for _, text in ipairs(self._order) do
        local e = self._by_text[text]
        if e and e.status == "queued" then return e end
    end
    return nil
end

function WavQueue:_previousText(text)
    for i, t in ipairs(self._order) do
        if t == text and i > 1 then
            return self._order[i - 1]
        end
    end
    return self.engine and self.engine._eleven_prev_text or nil
end

function WavQueue:_androidBusySynthesizing()
    -- One in-flight synthesizeToFile at a time. Do not consult the
    -- synth-then-play pipeline: that path races lookahead and used to
    -- mark the next sentence ready when the current one finished.
    return self._inflight > 0
end

function WavQueue:_start(entry)
    local kind = self:_kind()
    local engine = self.engine
    if kind == "elevenlabs" then
        local atts = engine:_ensureAndroidTts()
        local key = engine.plugin and engine.plugin:getSetting("elevenlabs_api_key", "") or ""
        if key == "" then
            entry.status = "failed"
            return false
        end
        local model = engine.plugin:getSetting("elevenlabs_model", "")
        if model == "" then model = ElevenLabs.DEFAULT_MODEL end
        local voice_id = engine.plugin:getSetting("elevenlabs_voice_id", "")
        local lang = ElevenLabs.resolvedRequestLanguage(engine.plugin, engine)
        local url, body = ElevenLabs.buildPost(entry.text, {
            voice_id = voice_id,
            model = model,
            previous_text = self:_previousText(entry.text),
            language_code = lang,
        })
        if atts and atts.httpPostToFile then
            local job = atts:httpPostToFile(url, key, body, entry.path)
            if not job or job < 1 then
                entry.status = "failed"
                return false
            end
            entry.job_id = job
            entry.status = "pending"
            self._inflight = self._inflight + 1
            return true
        end
        -- Old dex: blocking Lua HTTPS (no overlap).
        local path, err = ElevenLabs.synthesize(key, entry.path, entry.text, {
            voice_id = voice_id,
            model = model,
            previous_text = self:_previousText(entry.text),
            language_code = lang,
        })
        if path then
            self:_markReady(entry)
        else
            logger.warn("WavQueue: ElevenLabs Lua synth failed:", tostring(err))
            entry.status = "failed"
        end
        return false
    end

    if kind == "android" then
        if self:_androidBusySynthesizing() then return false end
        local atts = engine:_ensureAndroidTts()
        if not atts or not atts.synthesizeToFile then return false end
        if engine._androidPrepareEngine then
            engine:_androidPrepareEngine(entry.text)
        else
            atts:setRate(engine.rate or 1.0)
            atts:setPitch(engine:_androidPitchMultiplier(engine.pitch))
        end
        local dispatch = atts:synthesizeToFile(entry.text, entry.path)
        if dispatch ~= 0 then
            entry.status = "failed"
            return false
        end
        entry.status = "pending"
        self._inflight = self._inflight + 1
        dlog("tts-android", "synth-start", "queued", #self._order, "inflight", self._inflight)
        return true
    end
    return false
end

function WavQueue:_markReady(entry)
    if entry.status == "ready" then return end
    local engine = self.engine
    local saved_timing = engine.timing_data
    local saved_file = engine.current_audio_file
    engine:generateTimingEstimates(entry.text)
    entry.timing = engine.timing_data
    engine.timing_data = saved_timing
    engine.current_audio_file = saved_file
    local path, werr
    if self:_kind() == "android" then
        path = entry.path
    else
        path, werr = ElevenLabs.ensureWav(entry.path)
    end
    if not path then
        if self:_kind() == "android" then
            path = entry.path
        else
            logger.warn("WavQueue: audio finalize failed:", tostring(werr))
            entry.status = "failed"
            self._inflight = math.max(0, self._inflight - 1)
            return
        end
    end
    entry.path = path
    if self:_kind() == "elevenlabs" then
        entry.dur_ms = ElevenLabs.guessDurationMs(path) or 0
    else
        entry.dur_ms = WavUtils.getDurationMs(path) or 0
    end
    entry.status = "ready"
    self._inflight = math.max(0, self._inflight - 1)
end

function WavQueue:_markFailed(entry)
    if entry.status == "failed" then return end
    entry.status = "failed"
    self._inflight = math.max(0, self._inflight - 1)
end

function WavQueue:_pollOnce()
    local kind = self:_kind()
    local atts = self.engine and self.engine._android_tts
    for _, text in ipairs(self._order) do
        local e = self._by_text[text]
        if e and e.status == "pending" then
            if kind == "elevenlabs" then
                if not atts or not atts.getHttpJobStatus then
                    self:_markFailed(e)
                else
                    local st = atts:getHttpJobStatus(e.job_id or -1)
                    if st == 1 then
                        self:_markReady(e)
                    elseif st == 2 then
                        logger.warn("WavQueue: ElevenLabs job failed")
                        self:_markFailed(e)
                    end
                end
            elseif kind == "android" then
                if not atts then
                    self:_markFailed(e)
                else
                    local st = atts:getSynthStatus()
                    local dur = WavUtils.getDurationMs(e.path) or 0
                    if st == 1 then
                        -- onDone can fire before the WAV is fully flushed, or
                        -- for a different utterance. Require a real clip.
                        if dur >= 150 then
                            self:_markReady(e)
                        end
                    elseif st == 2 then
                        -- A stale onError from a cancelled job can arrive
                        -- after a real WAV was written. Keep the clip.
                        if dur >= 150 then
                            self:_markReady(e)
                        else
                            logger.warn("WavQueue: Android synth failed")
                            self:_markFailed(e)
                        end
                    end
                end
            end
        end
    end
    self:kick()
end

function WavQueue:_ensurePoll()
    if self._poll_on then return end
    self._poll_on = true
    local q = self
    local gen = self._gen
    local function tick()
        if q._gen ~= gen then
            q._poll_on = false
            return
        end
        q:_pollOnce()
        local busy = q._inflight > 0 or q:_nextQueued() ~= nil
        if busy then
            UIManager:scheduleIn(0.15, tick)
        else
            q._poll_on = false
        end
    end
    UIManager:scheduleIn(0.15, tick)
end

function WavQueue:kick()
    if not self:_kind() then return end
    while self._inflight < self:_maxParallel() do
        local e = self:_nextQueued()
        if not e then break end
        if not self:_start(e) then break end
    end
    if self._inflight > 0 or self:_nextQueued() then
        self:_ensurePoll()
    end
end

function WavQueue:status(text)
    local e = self._by_text[text]
    return e and e.status or nil
end

function WavQueue:peek(text)
    local e = self._by_text[text]
    if not e or e.status ~= "ready" then return nil, nil, 0 end
    return e.path, e.timing, e.dur_ms or 0
end

function WavQueue:useReady(text)
    local e = self._by_text[text]
    if not e or e.status ~= "ready" then return nil, nil end
    self._by_text[text] = nil
    for i, t in ipairs(self._order) do
        if t == text then table.remove(self._order, i); break end
    end
    return e.path, e.timing, e.dur_ms or 0
end

function WavQueue:clean()
    self._gen = (self._gen or 0) + 1
    self._poll_on = false
    local atts = self.engine and self.engine._android_tts
    if atts and atts.cancelSynth then
        pcall(function() atts:cancelSynth() end)
    end
    for _, e in pairs(self._by_text) do
        if e.path then pcall(os.remove, e.path) end
    end
    self._by_text = {}
    self._order = {}
    self._inflight = 0
end

return WavQueue
