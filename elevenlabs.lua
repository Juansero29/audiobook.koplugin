--[[--
ElevenLabs cloud TTS for audiobook.koplugin.

POSTs sentence text to the ElevenLabs HTTP API and writes an MP3 (or WAV)
file that AndroidPlayer — the same JNI MediaPlayer as Storyteller — can play.

The API key is read from plugin settings (never logged, never committed).
Book text is sent in the HTTPS body only — not written to debug.log.

@module elevenlabs
--]]

local logger = require("logger")

local ElevenLabs = {}

ElevenLabs.API_BASE = "https://api.elevenlabs.io"
ElevenLabs.DEFAULT_MODEL = "eleven_multilingual_v2"
ElevenLabs.DEFAULT_VOICE_ID = "JBFqnCBsd6RMkjVDRZzb" -- George (docs default)
-- mp3_44100_128 matches Storyteller files on Boox. wav_24000 PCM was
-- synthesized fine but TtsHelper MediaPlayer stayed silent.
ElevenLabs.DEFAULT_FORMAT = "mp3_44100_128"
ElevenLabs.PCM_FORMAT = "pcm_24000"
ElevenLabs.PCM_RATE = 24000

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local WavUtils = dofile(_utils_dir .. "wavutils.lua")

local function jsonString(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
        :gsub("\"", "\\\"")
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
    return '"' .. s .. '"'
end

local function decodeJson(body)
    if type(body) ~= "string" or body == "" then
        return nil
    end
    local ok, JSON = pcall(require, "json")
    if not ok or not JSON or not JSON.decode then
        return nil
    end
    local ok2, data = pcall(JSON.decode, body)
    if ok2 and type(data) == "table" then
        return data
    end
    return nil
end

local function urlEncode(s)
    s = tostring(s or "")
    return (s:gsub("([^%w%-_%.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--- ISO 639-1 from a BCP-47 tag or "auto".
function ElevenLabs.isoLang(tag)
    if type(tag) ~= "string" or tag == "" or tag == "auto" then
        return nil
    end
    local iso = tag:lower():gsub("_", "-"):match("^(%a+)")
    if not iso or #iso < 2 or iso == "c" then return nil end
    return iso
end

--- Language sent in ElevenLabs TTS requests.
--- Stored setting is "auto" or an ISO code. Auto: book metadata, else device UI language.
--- Never uses the System TTS language setting (those are independent).
--- @return string iso  ISO 639-1
--- @return string source  "forced"|"book"|"system"|"fallback"
function ElevenLabs.resolvedRequestLanguage(plugin, engine)
    local stored = plugin and plugin.getSetting
        and plugin:getSetting("elevenlabs_language", "auto") or "auto"
    if type(stored) ~= "string" or stored == "" then stored = "auto" end
    if stored ~= "auto" then
        local iso = ElevenLabs.isoLang(stored)
        if iso then return iso, "forced" end
    end
    engine = engine or (plugin and plugin.tts_engine)
    if engine and engine._androidBookLanguage then
        local book = ElevenLabs.isoLang(engine:_androidBookLanguage())
        if book then return book, "book" end
    end
    local sys
    pcall(function()
        local gt = require("audiobook_gettext")
        sys = gt.current_lang
    end)
    if not sys then
        pcall(function()
            sys = require("gettext").current_lang
        end)
    end
    local iso = ElevenLabs.isoLang(tostring(sys or ""))
    if iso then return iso, "system" end
    return "en", "fallback"
end

local function eachArray(t, fn)
    if type(t) ~= "table" then return end
    if t[1] ~= nil then
        for _, v in ipairs(t) do fn(v) end
        return
    end
    for _, v in pairs(t) do
        if type(v) == "table" then fn(v) end
    end
end

local function normalizeVoice(raw, source)
    if type(raw) ~= "table" then return nil end
    local id = raw.voice_id or raw.voiceId
    if type(id) ~= "string" or id == "" then return nil end
    local labels = type(raw.labels) == "table" and raw.labels or {}
    local langs = {}
    local function addLang(x)
        if type(x) == "string" and x ~= "" then
            langs[#langs + 1] = x:lower()
        end
    end
    addLang(raw.language)
    addLang(labels.language)
    eachArray(raw.verified_languages, function(vl)
        if type(vl) == "table" then
            addLang(vl.language)
            addLang(vl.locale)
        end
    end)
    return {
        id = id,
        name = (type(raw.name) == "string" and raw.name ~= "") and raw.name or id,
        accent = raw.accent or labels.accent or "",
        gender = raw.gender or labels.gender or "",
        language = raw.language or labels.language or "",
        languages = langs,
        owner_id = raw.public_owner_id or raw.public_user_id or "",
        added = raw.is_added_by_user == true,
        source = source or "account",
        category = raw.category or "",
    }
end

function ElevenLabs.displayName(voice)
    if type(voice) ~= "table" then return "" end
    local extra = {}
    if type(voice.accent) == "string" and voice.accent ~= "" then
        extra[#extra + 1] = voice.accent
    end
    if type(voice.gender) == "string" and voice.gender ~= "" then
        extra[#extra + 1] = voice.gender
    elseif type(voice.language) == "string" and voice.language ~= ""
        and (not voice.accent or voice.accent == "") then
        extra[#extra + 1] = voice.language
    end
    local name = voice.name or voice.id or ""
    if #extra == 0 then return name end
    return name .. " · " .. table.concat(extra, ", ")
end

function ElevenLabs.matchesLang(voice, lang)
    lang = ElevenLabs.isoLang(lang) or lang
    if type(lang) ~= "string" or lang == "" then return true end
    lang = lang:lower()
    local hints = {
        fr = {
            fr = true, french = true, ["français"] = true, francais = true,
            parisian = true, quebec = true, quebecois = true, ["québécois"] = true,
            ["fr-fr"] = true, ["fr-ca"] = true,
        },
        en = { en = true, english = true, american = true, british = true, australian = true },
        es = { es = true, spanish = true, espanol = true, ["español"] = true },
        de = { de = true, german = true, deutsch = true },
        it = { it = true, italian = true, italiano = true },
        pt = { pt = true, portuguese = true, portugues = true, ["português"] = true, brazilian = true },
    }
    local accept = hints[lang]
    local function hit(s)
        if type(s) ~= "string" or s == "" then return false end
        s = s:lower()
        if s == lang or s:match("^" .. lang .. "%-") then return true end
        if accept and accept[s] then return true end
        return false
    end
    if type(voice) ~= "table" then return false end
    if hit(voice.language) or hit(voice.accent) then return true end
    if type(voice.languages) == "table" then
        for _, s in ipairs(voice.languages) do
            if hit(s) then return true end
        end
    end
    return false
end

local function buildBody(text, opts)
    opts = opts or {}
    local parts = {
        '"text":' .. jsonString(text),
        '"model_id":' .. jsonString(opts.model or ElevenLabs.DEFAULT_MODEL),
    }
    -- Speed is applied locally on MediaPlayer (see TTSEngine:_usesLocalPlaybackRate).
    -- Do not send voice_settings.speed: ElevenLabs rejects values outside 0.7–1.2.
    if opts.previous_text and opts.previous_text ~= "" then
        parts[#parts + 1] = '"previous_text":' .. jsonString(opts.previous_text)
    end
    if opts.next_text and opts.next_text ~= "" then
        parts[#parts + 1] = '"next_text":' .. jsonString(opts.next_text)
    end
    -- language_code tells the model which language to speak. Sent whenever
    -- we resolved one (forced, book, or device). Flash/Turbo require it;
    -- other models ignore an unknown field.
    local lang = ElevenLabs.isoLang(opts.language_code or opts.language)
    if lang then
        parts[#parts + 1] = '"language_code":' .. jsonString(lang)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--- HTTP request. Returns code, body, err.
local function httpRequest(method, url, headers, body)
    local http
    local ok_http, sockhttp = pcall(require, "socket.http")
    if ok_http then
        http = sockhttp
    elseif type(url) == "string" and url:match("^https:") then
        local ok_ssl, https = pcall(require, "ssl.https")
        if ok_ssl then
            http = https
        end
    end
    if not http then
        return nil, nil, "socket.http unavailable"
    end
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local ok_util, socketutil = pcall(require, "socketutil")
    if ok_util and socketutil then
        socketutil:set_timeout(20, 90)
    end
    local sink = {}
    local req = {
        url = url,
        method = method or "GET",
        headers = headers or {},
        sink = ltn12.sink.table(sink),
    }
    if body and body ~= "" then
        req.source = ltn12.source.string(body)
        req.headers["Content-Length"] = tostring(#body)
    end
    local ok, code, _headers, status = pcall(function()
        return socket.skip(1, http.request(req))
    end)
    if ok_util and socketutil then
        socketutil:reset_timeout()
    end
    if not ok then
        return nil, nil, tostring(code)
    end
    return tonumber(code) or code, table.concat(sink), status
end

local function parseErrorBody(body)
    if type(body) ~= "string" or body == "" then
        return "empty response"
    end
    -- Do not return the raw body (may echo request metadata). Pull a short status.
    local status = body:match('"status"%s*:%s*"([^"]+)"')
    local msg = body:match('"message"%s*:%s*"([^"]+)"')
    if status and msg then
        return status .. ": " .. msg
    end
    if status then return status end
    if msg then return msg end
    if body:sub(1, 1) == "{" then
        return "api error"
    end
    return "unexpected response"
end

local function isMpegAudio(body)
    if type(body) ~= "string" or #body < 3 then return false end
    if body:sub(1, 3) == "ID3" then return true end
    local b1, b2 = body:byte(1, 2)
    -- MPEG frame sync: 11 bits set (0xFFE0..0xFFFF).
    return b1 == 0xFF and b2 ~= nil and b2 >= 0xE0
end

local function writeBytes(path, body)
    local f = io.open(path, "wb")
    if not f then return nil, "cannot write audio" end
    f:write(body)
    f:close()
    return path
end

local function writeAudioFile(path, body, format)
    if not body or #body < 16 then
        return nil, "audio too short"
    end
    if body:sub(1, 4) == "RIFF" then
        return writeBytes(path, body)
    end
    if isMpegAudio(body) then
        return writeBytes(path, body)
    end
    -- Raw PCM (pcm_24000): wrap a WAV header. Do not wrap MP3/JSON.
    if format == ElevenLabs.PCM_FORMAT and body:byte(1) ~= 123 then
        if WavUtils.writePcmWav(path, body, ElevenLabs.PCM_RATE, 1, 16) then
            return path
        end
        return nil, "pcm wrap failed"
    end
    if body:byte(1) ~= 123 then
        -- Unknown binary: keep as-is (MediaPlayer will sniff).
        return writeBytes(path, body)
    end
    return nil, parseErrorBody(body)
end

function ElevenLabs.maskKey(key)
    if type(key) ~= "string" or key == "" then
        return ""
    end
    if #key <= 8 then return "••••" end
    return "••••" .. key:sub(-4)
end

--- List voices already on the account (premade + cloned). Never logs the key.
-- @return table|nil list of normalized voices
-- @return string|nil error
function ElevenLabs.listVoices(api_key)
    if not api_key or api_key == "" then
        return nil, "no api key"
    end
    local code, body, err = httpRequest("GET",
        ElevenLabs.API_BASE .. "/v1/voices",
        {
            ["xi-api-key"] = api_key,
            ["Accept"] = "application/json",
        })
    if not code then
        return nil, err or "network error"
    end
    if code ~= 200 then
        return nil, parseErrorBody(body)
    end
    local voices = {}
    local data = decodeJson(body)
    if data then
        eachArray(data.voices or data, function(raw)
            local v = normalizeVoice(raw, "account")
            if v then voices[#voices + 1] = v end
        end)
    end
    if #voices == 0 then
        for id, name in body:gmatch('"voice_id"%s*:%s*"([^"]+)"%s*,%s*"name"%s*:%s*"([^"]+)"') do
            voices[#voices + 1] = { id = id, name = name, source = "account" }
        end
    end
    if #voices == 0 then
        for name, id in body:gmatch('"name"%s*:%s*"([^"]+)".-"voice_id"%s*:%s*"([^"]+)"') do
            voices[#voices + 1] = { id = id, name = name, source = "account" }
        end
    end
    return voices
end

--- Search the public voice library for a language (ISO 639-1).
-- These voices must be added to the account before TTS (see addSharedVoice).
function ElevenLabs.listSharedVoices(api_key, lang)
    if not api_key or api_key == "" then
        return nil, "no api key"
    end
    lang = ElevenLabs.isoLang(lang) or lang
    if type(lang) ~= "string" or lang == "" then
        return {}, nil
    end
    local url = string.format(
        "%s/v1/shared-voices?page_size=30&language=%s",
        ElevenLabs.API_BASE, urlEncode(lang))
    local code, body, err = httpRequest("GET", url, {
        ["xi-api-key"] = api_key,
        ["Accept"] = "application/json",
    })
    if not code then
        return nil, err or "network error"
    end
    if code ~= 200 then
        return nil, parseErrorBody(body)
    end
    local voices = {}
    local data = decodeJson(body)
    if data then
        eachArray(data.voices or data, function(raw)
            local v = normalizeVoice(raw, "library")
            if v then voices[#voices + 1] = v end
        end)
    end
    return voices
end

--- Copy a library voice into the account. Returns the usable voice_id.
function ElevenLabs.addSharedVoice(api_key, owner_id, voice_id, name)
    if not api_key or api_key == "" then
        return nil, "no api key"
    end
    if type(owner_id) ~= "string" or owner_id == "" then
        return nil, "no owner id"
    end
    if type(voice_id) ~= "string" or voice_id == "" then
        return nil, "no voice id"
    end
    local url = string.format("%s/v1/voices/add/%s/%s",
        ElevenLabs.API_BASE, urlEncode(owner_id), urlEncode(voice_id))
    local body = '{"new_name":' .. jsonString(name or "Voice") .. "}"
    local code, resp, err = httpRequest("POST", url, {
        ["xi-api-key"] = api_key,
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
    }, body)
    if not code then
        return nil, err or "network error"
    end
    if code ~= 200 then
        return nil, parseErrorBody(resp)
    end
    local data = decodeJson(resp)
    if data and type(data.voice_id) == "string" and data.voice_id ~= "" then
        return data.voice_id
    end
    return voice_id
end

--- URL + JSON body for one TTS POST. Used by the Java background worker.
function ElevenLabs.buildPost(text, opts)
    opts = opts or {}
    local voice_id = opts.voice_id or ElevenLabs.DEFAULT_VOICE_ID
    if voice_id == "" then
        voice_id = ElevenLabs.DEFAULT_VOICE_ID
    end
    local format = opts.format or ElevenLabs.DEFAULT_FORMAT
    local url = string.format(
        "%s/v1/text-to-speech/%s?output_format=%s",
        ElevenLabs.API_BASE, voice_id, format)
    return url, buildBody(text, opts), format
end

--- If dest is raw PCM (not RIFF/MP3), wrap a WAV header in place.
function ElevenLabs.ensureWav(dest_path, format)
    local f = io.open(dest_path, "rb")
    if not f then return nil, "missing audio" end
    local body = f:read("*a")
    f:close()
    return writeAudioFile(dest_path, body, format or ElevenLabs.DEFAULT_FORMAT)
end

--- Duration for highlight scaling before MediaPlayer.prepare().
--- WAV: real header. MP3: CBR estimate for mp3_44100_128 (16 bytes/ms).
function ElevenLabs.guessDurationMs(path)
    local f = io.open(path, "rb")
    if not f then return 0 end
    local hdr = f:read(16)
    local size = f:seek("end")
    f:close()
    if not hdr or not size or size < 16 then return 0 end
    if hdr:sub(1, 4) == "RIFF" then
        return WavUtils.getDurationMs(path) or 0
    end
    local audio = size
    if hdr:sub(1, 3) == "ID3" then
        local b6, b7, b8, b9 = hdr:byte(7, 10)
        if b6 and b7 and b8 and b9 then
            local tag = (b6 % 128) * 2097152 + (b7 % 128) * 16384
                + (b8 % 128) * 128 + (b9 % 128) + 10
            if tag > 0 and tag < size then audio = size - tag end
        end
    end
    return math.max(200, math.floor(audio / 16))
end

--[[--
Synthesize `text` to `dest_path` (MP3 or WAV).
opts: model, voice_id, previous_text, next_text, speed
@return string|nil dest_path
@return string|nil error
--]]
function ElevenLabs.synthesize(api_key, dest_path, text, opts)
    if not api_key or api_key == "" then
        return nil, "no api key"
    end
    if not dest_path or dest_path == "" then
        return nil, "no dest"
    end
    if type(text) ~= "string" or text:match("^%s*$") then
        return nil, "empty text"
    end
    opts = opts or {}
    local voice_id = opts.voice_id or ElevenLabs.DEFAULT_VOICE_ID
    if voice_id == "" then
        voice_id = ElevenLabs.DEFAULT_VOICE_ID
    end
    local formats = opts.format
        and { opts.format, "mp3_44100_64", "wav_24000" }
        or { ElevenLabs.DEFAULT_FORMAT, "mp3_44100_64", "wav_24000" }
    local body = buildBody(text, opts)
    local last_err
    for i, format in ipairs(formats) do
        local url = string.format(
            "%s/v1/text-to-speech/%s?output_format=%s",
            ElevenLabs.API_BASE, voice_id, format)
        local code, resp, err = httpRequest("POST", url, {
            ["xi-api-key"] = api_key,
            ["Content-Type"] = "application/json",
            ["Accept"] = "audio/wav, audio/mpeg, application/json",
        }, body)
        if not code then
            last_err = err or "network error"
            logger.warn("ElevenLabs: request failed:", last_err)
            break
        end
        if code == 200 then
            local path, werr = writeAudioFile(dest_path, resp, format)
            if path then
                logger.dbg("ElevenLabs: wrote audio bytes=", resp and #resp or 0, "format=", format)
                return path
            end
            last_err = werr
            logger.warn("ElevenLabs: audio write failed:", werr)
            break
        end
        last_err = parseErrorBody(resp)
        logger.warn("ElevenLabs: HTTP", code, last_err)
        -- Retry a more compatible format if this output_format is not allowed.
        if code == 400 or code == 403 or code == 422 then
            -- try next format
        else
            break
        end
    end
    return nil, last_err or "synthesis failed"
end

return ElevenLabs
