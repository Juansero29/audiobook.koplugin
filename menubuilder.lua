--[[--
Menu builder functions for the Audiobook plugin.
Pure factory functions that return KOReader menu item tables.

All functions take `plugin` (the Audiobook WidgetContainer instance)
as their first parameter to access settings and engine state.

@module menubuilder
--]]

local _ = require("audiobook_gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")

-- Shared utility module
local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_dir .. "utils.lua")
local ElevenLabs = dofile(_dir .. "elevenlabs.lua")

local MenuBuilder = {}

--[[--
Friendly name of Android's preferred TTS engine (SherpaTTS, Google, …).
@return string|nil
--]]
function MenuBuilder.androidSystemEngineName(plugin)
    local engine = plugin and plugin.tts_engine
    if not engine or not engine.androidEngineDisplayName then
        return nil
    end
    return engine:androidEngineDisplayName()
end

--[[--
"System TTS" or "System TTS (SherpaTTS)" when the preferred engine is known.
--]]
function MenuBuilder.systemTtsMenuLabel(plugin)
    local name = MenuBuilder.androidSystemEngineName(plugin)
    if name and name ~= "" then
        return T(_("System TTS (%1)"), name)
    end
    return _("System TTS")
end

--[[--
Engine picker row: keep "(Android)" until the preferred engine is known.
--]]
function MenuBuilder.systemTtsAndroidChoiceLabel(plugin)
    local name = MenuBuilder.androidSystemEngineName(plugin)
    if name and name ~= "" then
        return T(_("System TTS (Android) — %1"), name)
    end
    return _("System TTS (Android)")
end

function MenuBuilder.buildVoiceSettingsMenu(plugin)
    local menu = {}

    -- TTS Engine selector (espeak-ng vs Piper)
    table.insert(menu, {
        text_func = function()
            local backend = plugin.tts_engine.backend or "none"
            local labels = {
                espeak = _("espeak-ng"),
                piper = _("Piper (neural)"),
                pico = _("Pico TTS"),
                flite = _("Flite"),
                festival = _("Festival"),
                android = MenuBuilder.systemTtsMenuLabel(plugin),
                elevenlabs = _("ElevenLabs"),
                ["platform-native"] = _("Platform-native helper"),
            }
            return T(_("TTS engine: %1"), labels[backend] or backend)
        end,
        sub_item_table_func = function()
            return MenuBuilder.buildEngineSelectMenu(plugin)
        end,
    })

    local backend = plugin.tts_engine and plugin.tts_engine.backend
    local BACKENDS = plugin.tts_engine and plugin.tts_engine.BACKENDS

    -- Platform-native helper settings (only visible when that backend is active).
    if BACKENDS and backend == BACKENDS.NATIVE then
        table.insert(menu, {
            text = _("Platform-native helper settings"),
            sub_item_table_func = function()
                return MenuBuilder.buildNativeTtsSettingsMenu(plugin)
            end,
        })
    end

    -- Engine-specific settings: only the active backend. Switching engine
    -- (buildEngineSelectMenu) closes the menu so the next open is rebuilt.
    if BACKENDS and backend == BACKENDS.ELEVENLABS then
        for _, item in ipairs(MenuBuilder.buildElevenLabsSettingsMenu(plugin)) do
            table.insert(menu, item)
        end
    elseif BACKENDS and backend == BACKENDS.ANDROID then
        for _, item in ipairs(MenuBuilder.buildSystemTtsSettingsMenu(plugin)) do
            table.insert(menu, item)
        end
    end

    -- MBROLA voice selection (espeak-ng backend only).
    -- On Kobo devices with the MTK Bluetooth chip, only mb-en1 works
    -- reliably; all other MBROLA voices trigger mid-sentence audio repeats.
    -- On every other device, expose the full MBROLA voice menu.
    -- See docs/MBROLA_MTK_REPEAT_BUG.md for the full diagnostic report.
    if plugin.tts_engine and plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK then
        if plugin.bt_manager and plugin.bt_manager:isMtkKobo() then
            -- MTK Kobo: restrict to the single known-working MBROLA voice.
            table.insert(menu, {
                text = _("MBROLA voice UK English Male 1"),
                checked_func = function()
                    return plugin:getSetting("tts_mbrola_voice", "") == "en1"
                end,
                callback = function()
                    local current = plugin:getSetting("tts_mbrola_voice", "")
                    if current == "en1" then
                        -- Uncheck: disable MBROLA
                        plugin:setSetting("tts_mbrola_voice", "")
                        plugin:setSetting("tts_mbrola_voice_label", "")
                        local base = plugin:getSetting("tts_voice", "en")
                        local var = plugin:getSetting("tts_voice_variant", "")
                        local full = base
                        if var ~= "" then
                            full = base .. "+" .. var
                        end
                        plugin.tts_engine:setVoice(full)
                        UIManager:show(InfoMessage:new{
                            text = _("MBROLA disabled. Using regular espeak-ng voice."),
                            timeout = 2,
                        })
                    else
                        -- Check: enable mb-en1 only
                        plugin:setSetting("tts_mbrola_voice", "en1")
                        plugin:setSetting("tts_mbrola_voice_label", "UK English Male 1")
                        plugin.tts_engine:setVoice("mb-en1")
                        UIManager:show(InfoMessage:new{
                            text = _(
                                "MBROLA voice enabled: UK English Male 1.\n\n"
                                .. "Other MBROLA voices are unavailable because they trigger "
                                .. "a firmware bug in the MTK Bluetooth chip that causes "
                                .. "mid-sentence audio repeats. See the full report on GitHub."
                            ),
                            timeout = 5,
                        })
                    end
                end,
            })
            -- If user had a different MBROLA voice selected, migrate to disabled
            do
                local current_mb = plugin:getSetting("tts_mbrola_voice", "")
                if current_mb ~= "" and current_mb ~= "en1" then
                    plugin:setSetting("tts_mbrola_voice", "")
                    plugin:setSetting("tts_mbrola_voice_label", "")
                    local base = plugin:getSetting("tts_voice", "en")
                    local var = plugin:getSetting("tts_voice_variant", "")
                    local full = base
                    if var ~= "" then
                        full = base .. "+" .. var
                    end
                    plugin.tts_engine:setVoice(full)
                end
            end
        else
            -- Non-MTK devices: expose all bundled/installed MBROLA voices.
            table.insert(menu, {
                text_func = function()
                    local label = plugin:getSetting("tts_mbrola_voice_label", "")
                    if label == "" then
                        return _("MBROLA voice")
                    end
                    return T(_("MBROLA voice: %1"), label)
                end,
                sub_item_table_func = function()
                    return MenuBuilder.buildMbrolaVoiceMenu(plugin)
                end,
                help_text = _(
                    "Select a bundled or installed MBROLA voice. "
                    .. "Non-English MBROLA voices are available on devices "
                    .. "that do not use the MTK Bluetooth chip."
                ),
            })
        end
    end

    -- Quick start with espeak (Piper-only): play first sentences via espeak
    -- while Piper warms up.  Only relevant when both backends are usable.
    if plugin.tts_engine
       and plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PIPER
       and plugin.tts_engine.espeak_bin then
        table.insert(menu, {
            text = _("Quick start with espeak (while Piper loads)"),
            checked_func = function()
                return plugin:getSetting("espeak_cold_start", true)
            end,
            callback = function()
                plugin:toggleSetting("espeak_cold_start", true)
            end,
        })
    end

    -- Piper mitigations for underpowered devices (single-core, low RAM).
    -- Both are OFF by default; the RTF auto-degrade can also enable them
    -- for a session when Piper measurably cannot keep up with playback.
    if plugin.tts_engine
       and plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PIPER then
        table.insert(menu, {
            text = _("Low-resource mode (slow devices)"),
            checked_func = function()
                return plugin:getSetting("piper_low_resource", false)
            end,
            callback = function()
                plugin:toggleSetting("piper_low_resource", false)
            end,
            help_text = _(
                "Synthesizes one sentence at a time and prioritizes the "
                .. "sentence currently being read. Helps on single-core "
                .. "devices where Piper is slower than playback."
            ),
        })
        table.insert(menu, {
            text = _("Split sentences aggressively for Piper"),
            checked_func = function()
                return plugin:getSetting("piper_aggressive_split", false)
            end,
            callback = function()
                plugin:toggleSetting("piper_aggressive_split", false)
            end,
            help_text = _(
                "Limits synthesis chunks to about 150 characters instead "
                .. "of 300. Reduces the wait per sentence and avoids "
                .. "synthesis failures with long sentences on low-memory "
                .. "devices. Applies from the next page."
            ),
        })
    end

    -- Speech rate submenu
    table.insert(menu, {
        text_func = function()
            return T(_("Speech rate: %1x"), plugin:getSetting("speech_rate", 1.0))
        end,
        sub_item_table = MenuBuilder.buildSpeechRateMenu(plugin),
    })

    -- Pitch submenu (espeak-ng only)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK then
        table.insert(menu, {
            text_func = function()
                return T(_("Pitch: %1"), plugin:getSetting("speech_pitch", 50))
            end,
            sub_item_table = MenuBuilder.buildPitchMenu(plugin),
        })
    end

    -- Volume submenu
    table.insert(menu, {
        text_func = function()
            return T(_("Volume: %1%%"), math.floor(plugin:getSetting("speech_volume", 1.0) * 100))
        end,
        sub_item_table = MenuBuilder.buildVolumeMenu(plugin),
    })

    -- Pause between sentences / paragraphs (Lua chain delay)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK
        or plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ANDROID
        or plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ELEVENLABS then
        table.insert(menu, {
            text_func = function()
                return T(_("Sentence pause (. ? !): %1s"), plugin:getSetting("sentence_pause", 0.1))
            end,
            sub_item_table = MenuBuilder.buildSentencePauseMenu(plugin),
        })

        table.insert(menu, {
            text_func = function()
                return T(_("Paragraph pause (newlines): %1s"), plugin:getSetting("paragraph_pause", 0.8))
            end,
            sub_item_table = MenuBuilder.buildParagraphPauseMenu(plugin),
        })
    end

    -- Piper inter-sentence gaps (natural pacing + synthesis buffer)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PIPER then
        table.insert(menu, {
            text_func = function()
                return T(_("Sentence gap (. ? !): %1s"), plugin:getSetting("piper_sentence_gap", 0.3))
            end,
            sub_item_table = MenuBuilder.buildPiperSentenceGapMenu(plugin),
        })

        table.insert(menu, {
            text_func = function()
                return T(_("Paragraph gap (newlines): %1s"), plugin:getSetting("piper_paragraph_gap", 1.0))
            end,
            sub_item_table = MenuBuilder.buildPiperParagraphGapMenu(plugin),
        })

        -- Gap test mode: replaces silence with audible tones so the user
        -- can hear exactly where each gap is placed.  Sentence gaps use a
        -- 220 Hz tone; paragraph gaps use 330 Hz.
        table.insert(menu, {
            text = _("Gap test mode (audible tones)"),
            checked_func = function()
                return plugin:getSetting("gap_test_mode", false)
            end,
            callback = function()
                local new_val = not plugin:getSetting("gap_test_mode", false)
                plugin:setSetting("gap_test_mode", new_val)
                if plugin.tts_engine then
                    plugin.tts_engine._gap_test_mode = new_val
                end
            end,
        })
    end

    -- Clause pause (espeak-ng only — uses SSML)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK then
        table.insert(menu, {
            text_func = function()
                return T(_("Clause pause (, ; : -): %1s"), plugin:getSetting("clause_pause", 0))
            end,
            sub_item_table = MenuBuilder.buildClausePauseMenu(plugin),
        })

        -- Word gap (espeak-ng only)
        table.insert(menu, {
            text_func = function()
                return T(_("Word gap (between words): %1"), plugin:getSetting("word_gap", 2))
            end,
            sub_item_table = MenuBuilder.buildWordGapMenu(plugin),
        })
    end

    -- Voice / accent selection (differs by backend)
    if plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PIPER then
        table.insert(menu, {
            text_func = function()
                local model = plugin:getSetting("piper_model_label", "default")
                return T(_("Piper voice: %1"), model)
            end,
            sub_item_table_func = function()
                return MenuBuilder.buildPiperVoiceMenu(plugin)
            end,
        })
        -- Downloadable Piper voices (HuggingFace upstream) — only relevant when Piper is active
        table.insert(menu, {
            text = _("Download Piper voice…"),
            sub_item_table_func = function()
                local ok, result = pcall(function()
                    local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
                    local Downloader = dofile(_dir .. "downloader.lua")
                    return MenuBuilder.buildPiperDownloadMenu(plugin, Downloader)
                end)
                if ok then
                    return result
                else
                    logger.err("MenuBuilder: buildPiperDownloadMenu crashed:", result)
                    return {{
                        text = _("Could not load voice download menu."),
                        enabled = false,
                    }}
                end
            end,
        })
    elseif plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.ESPEAK
        or plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.PICO
        or plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.FLITE
        or plugin.tts_engine.backend == plugin.tts_engine.BACKENDS.FESTIVAL then
        table.insert(menu, {
            text_func = function()
                if plugin:getSetting("tts_mbrola_voice", "") ~= "" then
                    return _("Voice: (disabled while MBROLA is on)")
                end
                return T(_("Voice: %1"), plugin:getSetting("tts_voice_label", "English (GB)"))
            end,
            sub_item_table = MenuBuilder.buildVoiceMenu(plugin),
            enabled_func = function()
                return plugin:getSetting("tts_mbrola_voice", "") == ""
            end,
            help_text = _(
                "Base voice and accent variant are ignored when a MBROLA voice is active. "
                .. "Disable MBROLA to use regular espeak-ng voices."
            ),
        })
    end

    return menu
end

function MenuBuilder.buildAlsaDeviceMenu(plugin)
    local pb_default = plugin.tts_engine._pb_has_tts_sm and "tts_sm" or ""
    local devices = {
        { id = "tts_sm",   label = _("PocketBook pipeline - tts_sm (recommended)"),
          help = _("Routes through the PocketBook audio daemon (softvol, dmix, resampling). Best compatibility on devices that expose tts_sm in /etc/asound.conf.") },
        { id = "plughw:0", label = _("Direct hardware with resampling - plughw:0"),
          help = _("Direct hardware access through the ALSA plug layer. On some PocketBooks (e.g. PB631) the plug layer does not actually resample; if you hear playback at 2-3x speed, switch back to tts_sm or Auto.") },
        { id = "",         label = _("Auto (default ALSA device)"),
          help = _("Uses the system default ALSA device, then falls back to tts_sm and plughw:0 if the default is unavailable.") },
        { id = "inkview",  label = _("System player (InkView) - experimental"),
          help = _("Uses the PocketBook InkView PlayFile API. Some firmwares (PB740, PB631) export PlayFile but do not actually play audio; if no sound comes out, switch back to tts_sm or Auto.") },
    }
    -- hwout_mix: daemon-routed dmix without the softvol/nested-plug layers.
    -- Only offered when present in asound.conf; it is the fallback for
    -- devices whose alsa-lib aborts opening tts_sm (issue #49).
    if plugin.tts_engine and plugin.tts_engine._pb_has_hwout_mix then
        table.insert(devices, 2, {
            id = "hwout_mix",
            label = _("PocketBook pipeline (direct dmix) - hwout_mix"),
            help = _("Routes to the same PocketBook audio daemon output as tts_sm but skips the softvol layers that crash on some firmwares. Try this if tts_sm produces no sound or playback stops with an error. Loses the system TTS volume control."),
        })
    end
    local menu = {}
    for _, d in ipairs(devices) do
        table.insert(menu, {
            text = d.label,
            help_text = d.help,
            checked_func = function()
                return plugin:getSetting("pb_alsa_device", pb_default) == d.id
            end,
            callback = function()
                plugin:setSetting("pb_alsa_device", d.id)
                -- Invalidate cached player so the next playback uses the new device
                if plugin.tts_engine then
                    plugin.tts_engine._cached_player = nil
                end
            end,
        })
    end
    return menu
end

function MenuBuilder.buildSpeechRateMenu(plugin)
    local rates = {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0}
    local menu = {}

    for _i, rate in ipairs(rates) do
        table.insert(menu, {
            text = string.format("%.2fx", rate),
            checked_func = function()
                return plugin:getSetting("speech_rate", 1.0) == rate
            end,
            callback = function()
                plugin:setSetting("speech_rate", rate)
                plugin.tts_engine:setRate(rate)
            end,
        })
    end

    return menu
end

function MenuBuilder.buildPitchMenu(plugin)
    -- espeak-ng pitch range: 0–99, default 50
    local pitches = {0, 10, 20, 30, 40, 50, 60, 70, 80, 99}
    local labels = {
        [0] = _("0 (very low)"),
        [10] = "10", [20] = "20", [30] = "30", [40] = "40",
        [50] = _("50 (default)"),
        [60] = "60", [70] = "70", [80] = "80",
        [99] = _("99 (very high)"),
    }
    local menu = {}
    for _i, p in ipairs(pitches) do
        table.insert(menu, {
            text = labels[p] or tostring(p),
            checked_func = function()
                return plugin:getSetting("speech_pitch", 50) == p
            end,
            callback = function()
                plugin:setSetting("speech_pitch", p)
                plugin.tts_engine:setPitch(p)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildVolumeMenu(plugin)
    local volumes = {0.25, 0.50, 0.75, 1.0}
    local menu = {}
    for _i, v in ipairs(volumes) do
        table.insert(menu, {
            text = string.format("%d%%", math.floor(v * 100)),
            checked_func = function()
                return plugin:getSetting("speech_volume", 1.0) == v
            end,
            callback = function()
                plugin:setSetting("speech_volume", v)
                plugin.tts_engine:setVolume(v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildSentencePauseMenu(plugin)
    -- Pause after sentence-ending punctuation (.?!;:) within the same paragraph
    local values = {0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.8, 1.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.2fs", v)
        if v == 0.1 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("sentence_pause", 0.1) == v
            end,
            callback = function()
                plugin:setSetting("sentence_pause", v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildParagraphPauseMenu(plugin)
    -- Pause at paragraph/newline boundaries
    local values = {0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.5, 2.0, 3.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.1fs", v)
        if v == 0.8 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("paragraph_pause", 0.8) == v
            end,
            callback = function()
                plugin:setSetting("paragraph_pause", v)
            end,
        })
    end
    return menu
end

-- Piper sentence gap: silence inserted between sentences for natural pacing.
-- Also acts as a synthesis buffer — the pipeline plays silence while Piper
-- keeps working on the next batch.
function MenuBuilder.buildPiperSentenceGapMenu(plugin)
    local values = {0, 0.1, 0.2, 0.3, 0.5, 0.8, 1.0, 1.5, 2.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.1fs", v)
        if v == 0.3 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("piper_sentence_gap", 0.3) == v
            end,
            callback = function()
                plugin:setSetting("piper_sentence_gap", v)
            end,
        })
    end
    return menu
end

-- Piper paragraph gap: longer silence at paragraph boundaries (newlines).
function MenuBuilder.buildPiperParagraphGapMenu(plugin)
    local values = {0, 0.3, 0.5, 0.8, 1.0, 1.5, 2.0}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.1fs", v)
        if v == 1.0 then label = label .. _(" (default)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("piper_paragraph_gap", 1.0) == v
            end,
            callback = function()
                plugin:setSetting("piper_paragraph_gap", v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildClausePauseMenu(plugin)
    -- Pause at clause-level punctuation (commas, semicolons, colons, hyphens)
    -- Injected as silence in the espeak text via SSML-like pauses
    local values = {0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5}
    local menu = {}
    for _i, v in ipairs(values) do
        local label = string.format("%.2fs", v)
        if v == 0 then label = label .. _(" (default / off)") end
        table.insert(menu, {
            text = label,
            checked_func = function()
                return plugin:getSetting("clause_pause", 0) == v
            end,
            callback = function()
                plugin:setSetting("clause_pause", v)
                plugin.tts_engine:setClausePause(v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildWordGapMenu(plugin)
    -- espeak-ng word gap: extra silence (in units of 10ms) between words
    -- 0 = default (no extra gap), higher values slow down speech
    local values = {0, 1, 2, 5, 10, 20, 50}
    local labels = {
        [0] = _("0 (no extra gap)"),
        [1] = _("1 (10ms)"),
        [2] = _("2 (20ms - default)"),
        [5] = _("5 (50ms)"),
        [10] = _("10 (100ms)"),
        [20] = _("20 (200ms)"),
        [50] = _("50 (500ms)"),
    }
    local menu = {}
    for _i, v in ipairs(values) do
        table.insert(menu, {
            text = labels[v] or tostring(v),
            checked_func = function()
                return plugin:getSetting("word_gap", 2) == v
            end,
            callback = function()
                plugin:setSetting("word_gap", v)
                plugin.tts_engine:setWordGap(v)
            end,
        })
    end
    return menu
end

function MenuBuilder.buildVoiceMenu(plugin)
    -- Voices are split into sections: accents (male base) and voice variants
    -- Voice variants use espeak-ng "+variant" syntax: e.g. "en+f1" = English GB female1
    local current_base = plugin:getSetting("tts_voice", "en")
    local current_variant = plugin:getSetting("tts_voice_variant", "")
    local current_full = current_base
    if current_variant ~= "" then
        current_full = current_base .. "+" .. current_variant
    end

    local accents = {
        -- English variants
        { id = "en",              label = _("English (GB)") },
        { id = "en-us",           label = _("English (US)") },
        { id = "en-gb-x-rp",     label = _("English (Received Pronunciation)") },
        { id = "en-gb-scotland",  label = _("English (Scotland)") },
        { id = "en-gb-x-gbclan",  label = _("English (Lancaster)") },
        { id = "en-gb-x-gbcwmd", label = _("English (West Midlands)") },
        { id = "en-029",          label = _("English (Caribbean)") },
        { id = "en-us-nyc",       label = _("English (New York City)") },
        { separator = true },
        -- European languages
        { id = "de",              label = _("German") },
        { id = "es",              label = _("Spanish") },
        { id = "fr",              label = _("French") },
        { id = "it",              label = _("Italian") },
        { id = "pt",              label = _("Portuguese") },
        { id = "pt-br",           label = _("Portuguese (Brazil)") },
        { id = "nl",              label = _("Dutch") },
        { id = "ru",              label = _("Russian") },
        { id = "pl",              label = _("Polish") },
        { id = "cs",              label = _("Czech") },
        { id = "sv",              label = _("Swedish") },
        { id = "tr",              label = _("Turkish") },
        { id = "el",              label = _("Greek") },
        { id = "fi",              label = _("Finnish") },
        { id = "hu",              label = _("Hungarian") },
        { id = "ro",              label = _("Romanian") },
        { separator = true },
        -- Other languages
        { id = "ar",              label = _("Arabic") },
        { id = "zh",              label = _("Chinese (Mandarin)") },
        { id = "ja",              label = _("Japanese") },
        { id = "ko",              label = _("Korean") },
        { id = "hi",              label = _("Hindi") },
        { id = "vi",              label = _("Vietnamese") },
    }

    local variants = {
        { id = "",         label = _("Default (male)") },
        { separator = true },
        -- Female voices
        { id = "f1",       label = _("Female 1") },
        { id = "f2",       label = _("Female 2") },
        { id = "f3",       label = _("Female 3") },
        { id = "f4",       label = _("Female 4 (breathy)") },
        { id = "f5",       label = _("Female 5") },
        { separator = true },
        { id = "Annie",    label = _("Annie (F)") },
        { id = "Alicia",   label = _("Alicia (F)") },
        { id = "belinda",  label = _("Belinda (F)") },
        { id = "linda",    label = _("Linda (F)") },
        { id = "steph",    label = _("Steph (F)") },
        { id = "Andrea",   label = _("Andrea (F)") },
        { id = "anika",    label = _("Anika (F)") },
        { id = "aunty",    label = _("Aunty (F)") },
        { id = "grandma",  label = _("Grandma (F)") },
        { separator = true },
        -- Male voices
        { id = "m1",       label = _("Male 1") },
        { id = "m2",       label = _("Male 2") },
        { id = "m3",       label = _("Male 3") },
        { id = "m4",       label = _("Male 4") },
        { id = "m5",       label = _("Male 5") },
        { id = "m6",       label = _("Male 6") },
        { id = "m7",       label = _("Male 7") },
        { id = "Alex",     label = _("Alex (M)") },
        { id = "Andy",     label = _("Andy (M)") },
        { id = "Gene",     label = _("Gene (M)") },
        { id = "Lee",      label = _("Lee (M)") },
        { id = "shelby",   label = _("Shelby (M, smooth)") },
        { separator = true },
        -- Softer / less robotic
        { id = "robosoft",  label = _("Robosoft 1 (softer)") },
        { id = "robosoft2", label = _("Robosoft 2 (softer)") },
        { id = "robosoft3", label = _("Robosoft 3 (softer)") },
        { id = "robosoft4", label = _("Robosoft 4 (softer)") },
        { id = "robosoft5", label = _("Robosoft 5 (softer)") },
        { id = "robosoft6", label = _("Robosoft 6 (softer)") },
        { id = "robosoft7", label = _("Robosoft 7 (softer)") },
        { id = "robosoft8", label = _("Robosoft 8 (softer)") },
        { separator = true },
        -- Special
        { id = "whisper",  label = _("Whisper") },
        { id = "whisperf", label = _("Whisper (female)") },
        { id = "croak",    label = _("Croak") },
    }

    local menu = {}

    -- Accent submenu
    local accent_sub = {}
    for _i, a in ipairs(accents) do
        if not a.separator then
            table.insert(accent_sub, {
                text = a.label,
                checked_func = function()
                    return plugin:getSetting("tts_voice", "en") == a.id
                end,
                callback = function()
                    plugin:setSetting("tts_voice", a.id)
                    plugin:setSetting("tts_voice_label", a.label)
                    local var = plugin:getSetting("tts_voice_variant", "")
                    local full = a.id
                    if var ~= "" then full = a.id .. "+" .. var end
                    plugin.tts_engine:setVoice(full)
                end,
            })
        end
    end
    table.insert(menu, {
        text_func = function()
            return T(_("Accent: %1"), plugin:getSetting("tts_voice_label", "English (GB)"))
        end,
        sub_item_table = accent_sub,
    })

    -- Voice / gender variant submenu
    local variant_sub = {}
    for _i, v in ipairs(variants) do
        if not v.separator then
            table.insert(variant_sub, {
                text = v.label,
                checked_func = function()
                    return plugin:getSetting("tts_voice_variant", "") == v.id
                end,
                callback = function()
                    plugin:setSetting("tts_voice_variant", v.id)
                    plugin:setSetting("tts_variant_label", v.label)
                    local base = plugin:getSetting("tts_voice", "en")
                    local full = base
                    if v.id ~= "" then full = base .. "+" .. v.id end
                    plugin.tts_engine:setVoice(full)
                end,
            })
        end
    end
    table.insert(menu, {
        text_func = function()
            return T(_("Voice type: %1"), plugin:getSetting("tts_variant_label", "Default (male)"))
        end,
        sub_item_table = variant_sub,
    })

    return menu
end

function MenuBuilder.buildHighlightStyleMenu(plugin)
    local styles = {
        { id = "background", text = _("Background highlight") },
        { id = "underline", text = _("Underline") },
        { id = "box", text = _("Box border") },
        { id = "invert", text = _("Invert colors") },
    }
    local menu = {}

    for _, style in ipairs(styles) do
        table.insert(menu, {
            text = style.text,
            checked_func = function()
                return plugin:getSetting("highlight_style", "background") == style.id
            end,
            callback = function()
                plugin:setSetting("highlight_style", style.id)
                plugin.highlight_manager:setStyle(style.id)
            end,
        })
    end

    return menu
end

--[[--
Build TTS engine selection menu.
Lists all detected backends so the user can switch between espeak-ng and Piper.
--]]
function MenuBuilder.buildEngineSelectMenu(plugin)
    local menu = {}
    local engine = plugin.tts_engine

    -- Build a list of available backends with friendly labels
    local available = {}

    -- Android system TTS: the JNI bridge to the device's TextToSpeech
    -- engine.  Listed explicitly; without it the menu showed "No TTS
    -- engines found" on Android even though the bridge was working
    -- (issue #44), because every other entry probes CLI binaries that
    -- do not exist there.
    if engine._android_tts
        or engine._android_tts_deferred
        or engine.backend == engine.BACKENDS.ANDROID then
        table.insert(available, {
            id = engine.BACKENDS.ANDROID,
            label = MenuBuilder.systemTtsAndroidChoiceLabel(plugin),
        })
    end

    -- ElevenLabs: always listed. Needs an API key in TTS settings.
    table.insert(available, {
        id = engine.BACKENDS.ELEVENLABS,
        label = _("ElevenLabs (cloud, high quality)"),
    })

    -- espeak-ng: available if we detected it during init
    if engine.espeak_lib_path or Utils.commandExists("espeak-ng") or Utils.commandExists("espeak") then
        table.insert(available, {
            id = engine.BACKENDS.ESPEAK,
            label = _("espeak-ng (formant, fast, robotic)"),
        })
    end

    -- Piper: available if bundled binary or on PATH
    if engine.piper_cmd or Utils.commandExists("piper") then
        table.insert(available, {
            id = engine.BACKENDS.PIPER,
            label = _("Piper (neural, natural-sounding)"),
        })
    end

    -- Other system backends
    if Utils.commandExists("pico2wave") then
        table.insert(available, { id = engine.BACKENDS.PICO, label = _("Pico TTS") })
    end
    if Utils.commandExists("flite") then
        table.insert(available, { id = engine.BACKENDS.FLITE, label = _("Flite") })
    end
    if Utils.commandExists("festival") then
        table.insert(available, { id = engine.BACKENDS.FESTIVAL, label = _("Festival") })
    end

    -- Platform-native helper: user-supplied, device-specific engine wrapper.
    if engine.backend == engine.BACKENDS.NATIVE or engine:_nativeHelperConfigured() then
        table.insert(available, {
            id = engine.BACKENDS.NATIVE,
            label = _("Platform-native helper (user-supplied engine)"),
        })
    end

    if #available == 0 then
        table.insert(menu, {
            text = _("No TTS engines found"),
            enabled = false,
        })
        return menu
    end

    for _, backend in ipairs(available) do
        table.insert(menu, {
            text = backend.label,
            checked_func = function()
                return engine.backend == backend.id
            end,
            callback = function(touchmenu_instance)
                engine:setBackend(backend.id)
                plugin:setSetting("tts_backend", backend.id)
                -- An explicit engine choice clears the espeak-only mode
                -- setting; otherwise the user's selection would be silently
                -- overridden on the next page.
                plugin:setSetting("espeak_only_mode", false)
                -- Close the menu so the user reopens TTS settings and sees
                -- the correct engine-specific items (pitch, pauses, etc.).
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end
            end,
        })
    end

    return menu
end

--[[--
Build Piper voice model selection menu.
Lists .onnx files found in the bundled piper/ directory.
--]]
function MenuBuilder.buildPiperVoiceMenu(plugin)
    local menu = {}
    local voices = plugin.tts_engine:listPiperVoices()

    if #voices == 0 then
        table.insert(menu, {
            text = _("No voice models found"),
            enabled = false,
        })
        table.insert(menu, {
            text = _("Place .onnx files in plugins/audiobook.koplugin/piper/"),
            enabled = false,
        })
        return menu
    end

    -- Sort: medium before low (better quality first)
    table.sort(voices, function(a, b)
        local order = { high = 1, medium = 2, low = 3 }
        local oa = order[a.quality or "medium"] or 9
        local ob = order[b.quality or "medium"] or 9
        if oa ~= ob then return oa < ob end
        return a.name < b.name
    end)

    for _, voice in ipairs(voices) do
        local quality_label = ""
        if voice.quality then
            quality_label = string.format(" (%s · %d kHz)",
                voice.quality,
                (voice.sample_rate or 22050) / 1000)
        end
        local size_mb = voice.size and string.format(" · %.0f MB", voice.size / 1024 / 1024) or ""
        table.insert(menu, {
            text = voice.name .. quality_label .. size_mb,
            checked_func = function()
                return plugin:getSetting("piper_model", nil) == voice.path
                    or plugin.tts_engine.piper_model == voice.path
            end,
            callback = function()
                plugin.tts_engine:setPiperModel(voice.path)
                plugin:setSetting("piper_model", voice.path)
                -- Use quality-annotated label for the parent menu
                local label = voice.name
                if voice.quality then
                    label = label .. " (" .. voice.quality .. ")"
                end
                plugin:setSetting("piper_model_label", label)
                -- One-time-per-session heads-up on underpowered devices:
                -- Piper cannot sustain realtime playback on single-core /
                -- low-RAM hardware (measured ~8x slower than realtime on a
                -- Kobo Clara BW), so set expectations before the first stall.
                if not plugin._piper_weak_device_warned then
                    local cores = Utils.getCpuCores()
                    local mem_kb = Utils.getMemTotalKb()
                    if cores <= 1 or (mem_kb and mem_kb < 512 * 1024) then
                        plugin._piper_weak_device_warned = true
                        UIManager:show(InfoMessage:new{
                            text = _("Note: this device has limited CPU/RAM. Piper voices may pause between sentences or fall back to espeak during playback. Enabling \"Low-resource mode\" in TTS settings can help."),
                            timeout = 8,
                        })
                    end
                end
            end,
        })
    end

    return menu
end

--[[--
Build Android TTS language menu (auto-detect + common overrides).
--]]
function MenuBuilder.buildAndroidTtsLanguageMenu(plugin)
    local choices = {
        { id = "auto",  label = _("Auto-detect (script + book language)") },
        { id = "en-US", label = "English (US)" },
        { id = "en-GB", label = "English (UK)" },
        { id = "zh-CN", label = "Chinese (Simplified)" },
        { id = "zh-TW", label = "Chinese (Traditional)" },
        { id = "ja-JP", label = "Japanese" },
        { id = "ko-KR", label = "Korean" },
        { id = "fr-FR", label = "French" },
        { id = "de-DE", label = "German" },
        { id = "es-ES", label = "Spanish" },
        { id = "it-IT", label = "Italian" },
        { id = "pt-BR", label = "Portuguese (Brazil)" },
        { id = "ru-RU", label = "Russian" },
    }
    local menu = {}
    for _, choice in ipairs(choices) do
        table.insert(menu, {
            text = choice.label,
            checked_func = function()
                return plugin:getSetting("android_tts_language", "auto") == choice.id
            end,
            callback = function()
                plugin:setSetting("android_tts_language", choice.id)
                -- Force re-application (and re-warning) on the next chunk
                if plugin.tts_engine then
                    plugin.tts_engine._android_tts_lang = nil
                    plugin.tts_engine._android_lang_warned = nil
                end
            end,
            radio = true,
        })
    end
    return menu
end

function MenuBuilder.buildPiperDownloadMenu(plugin, Downloader)
    local menu = {}
    -- plugin.plugin_dir may be nil; fall back to deriving from piper_model_dir
    -- which is set during TTSEngine init as plugin_dir .. "/piper".
    local plugin_dir = plugin.plugin_dir
    if not plugin_dir then
        local pmd = plugin.tts_engine and plugin.tts_engine.piper_model_dir
        if pmd then
            plugin_dir = pmd:match("^(.+)/piper$")
        end
    end
    plugin_dir = plugin_dir or "."
    local voices = Downloader:getPiperVoiceList(plugin_dir)
    logger.warn("buildPiperDownloadMenu: plugin_dir=", plugin_dir, "voices=", #voices)

    -- Refresh voice list from internet (hybrid approach)
    table.insert(menu, {
        text = _("Refresh voice list from internet"),
        keep_menu_open = true,
        callback = function()
            local info = InfoMessage:new{
                text = _("Fetching latest voice list…"),
                timeout = 0,
            }
            UIManager:show(info)
            Downloader:refreshVoiceList(plugin_dir, function(ok, result)
                UIManager:close(info)
                if ok then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Voice list updated.\n%1 voices available."), #result),
                        timeout = 3,
                    })
                else
                    UIManager:show(InfoMessage:new{
                        text = _("Could not refresh voice list.\n\n") .. (result or _("unknown error")),
                        timeout = 5,
                    })
                end
            end)
        end,
    })
    table.insert(menu, {
        text = _("─"),
        enabled = false,
    })

    for __idx, voice in ipairs(voices) do
        -- In Lua 5.1 (LuaJIT) loop locals are reused across iterations,
        -- so closures must not capture 'installed' directly.  Re-query
        -- the disk state inside each closure instead.
        local voice_id = voice.id
        local voice_name = voice.name
        local size_mb = voice.size_mb
        local size_str = string.format(" · %d MB", size_mb)
        -- Debug: log first few voices to trace installed status
        if __idx <= 3 then
            local inst = Downloader:hasPiperVoice(voice_id, plugin_dir)
            logger.warn("buildPiperDownloadMenu voice", __idx, voice_id, "installed=", inst)
        end
        table.insert(menu, {
            text_func = function()
                local inst = Downloader:hasPiperVoice(voice_id, plugin_dir)
                local status = inst and _(" ✓ installed") or _("")
                return voice_name .. size_str .. status
            end,
            enabled_func = function()
                return not Downloader:hasPiperVoice(voice_id, plugin_dir)
            end,
            callback = function()
                if Downloader:hasPiperVoice(voice_id, plugin_dir) then return end
                local info = InfoMessage:new{
                    text = _("Downloading ") .. voice_name .. _("…\n(~")
                        .. size_mb .. _(" MB)"),
                    timeout = 0,
                }
                UIManager:show(info)
                Downloader:downloadPiperVoice(voice_id, plugin_dir,
                    function(done, total)
                        -- progress callback (optional)
                    end,
                    function(ok, err)
                        UIManager:close(info)
                        if ok then
                            -- Auto-select the downloaded voice so it appears
                            -- checked in the Piper voice menu immediately.
                            local voice_path = plugin_dir .. "/piper/" .. voice_id .. ".onnx"
                            if plugin.tts_engine then
                                plugin.tts_engine:setPiperModel(voice_path)
                            end
                            plugin:setSetting("piper_model", voice_path)
                            plugin:setSetting("piper_model_label", voice_name)
                            UIManager:show(InfoMessage:new{
                                text = _("Voice installed:\n") .. voice_name
                                    .. _("\n\nIt is now selected as your active Piper voice."),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Download failed:\n") .. (err or _("unknown error")),
                                timeout = 5,
                            })
                        end
                    end
                )
            end,
        })
    end

    return menu
end

--[[--
Build the MBROLA voice selection menu.
Lists bundled and installed MBROLA voices. Selecting one switches
espeak-ng to use the MBROLA voice (e.g. mb-us1).
--]]
function MenuBuilder.buildMbrolaVoiceMenu(plugin)
    local menu = {}
    local plugin_dir = plugin.plugin_dir
    if not plugin_dir then
        local esp = plugin.tts_engine and plugin.tts_engine.espeak_data_path
        if esp then
            plugin_dir = esp:match("^(.+)/espeak%-ng/share$")
        end
    end
    plugin_dir = plugin_dir or "."
    local _dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
    local Downloader = dofile(_dir .. "downloader.lua")
    local voices = Downloader:getMbrolaVoiceList(plugin_dir)
    local current_mb = plugin:getSetting("tts_mbrola_voice", "")

    -- Option to disable MBROLA and use regular espeak-ng voice
    table.insert(menu, {
        text = _("Disable MBROLA (use regular espeak-ng voice)"),
        checked_func = function()
            return plugin:getSetting("tts_mbrola_voice", "") == ""
        end,
        callback = function(touchmenu_instance)
            plugin:setSetting("tts_mbrola_voice", "")
            plugin:setSetting("tts_mbrola_voice_label", "")
            -- Restore regular espeak-ng voice
            local base = plugin:getSetting("tts_voice", "en")
            local var = plugin:getSetting("tts_voice_variant", "")
            local full = base
            if var ~= "" then full = base .. "+" .. var end
            plugin.tts_engine:setVoice(full)
            UIManager:show(InfoMessage:new{
                text = _("MBROLA disabled. Using regular espeak-ng voice."),
                timeout = 2,
            })
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
        end,
    })

    -- Group voices by language
    local lang_labels = {
        en = _("English"), fr = _("French"), de = _("German"),
        es = _("Spanish"), it = _("Italian"), pt = _("Portuguese"),
        nl = _("Dutch"), pl = _("Polish"), cs = _("Czech"),
        el = _("Greek"), ja = _("Japanese"), zh = _("Chinese"),
        ru = _("Russian"), ar = _("Arabic"), sv = _("Swedish"),
        tr = _("Turkish"),
    }

    local voices_by_lang = {}
    for _, v in ipairs(voices) do
        if v.bundled or v.installed then
            local lang = v.lang or "other"
            voices_by_lang[lang] = voices_by_lang[lang] or {}
            table.insert(voices_by_lang[lang], v)
        end
    end

    local sorted_langs = {}
    for lang in pairs(voices_by_lang) do
        table.insert(sorted_langs, lang)
    end
    table.sort(sorted_langs)

    for i, lang in ipairs(sorted_langs) do
        local lang_voices = voices_by_lang[lang]
        table.sort(lang_voices, function(a, b) return a.id < b.id end)

        for j, v in ipairs(lang_voices) do
            local voice_id = v.id
            local label = v.name
            if v.bundled then
                label = label .. _(" (bundled)")
            end
            table.insert(menu, {
                text_func = function()
                    local sel = plugin:getSetting("tts_mbrola_voice", "")
                    local mark = (sel == voice_id) and " ✓" or ""
                    return label .. mark
                end,
                callback = function(touchmenu_instance)
                    local mb_voice = "mb-" .. voice_id
                    plugin:setSetting("tts_mbrola_voice", voice_id)
                    plugin:setSetting("tts_mbrola_voice_label", v.name)
                    plugin.tts_engine:setVoice(mb_voice)
                    UIManager:show(InfoMessage:new{
                        text = T(_("MBROLA voice selected:\n%1"), v.name),
                        timeout = 2,
                    })
                    if touchmenu_instance then
                        touchmenu_instance:updateItems()
                    end
                end,
            })
        end
    end

    return menu
end

--[[--
Build the MBROLA voice download menu.
Lists downloadable MBROLA voices with size and install status.
--]]
function MenuBuilder.buildMbrolaDownloadMenu(plugin, Downloader)
    local menu = {}
    local plugin_dir = plugin.plugin_dir
    if not plugin_dir then
        local esp = plugin.tts_engine and plugin.tts_engine.espeak_data_path
        if esp then
            plugin_dir = esp:match("^(.+)/espeak%-ng/share$")
        end
    end
    plugin_dir = plugin_dir or "."
    local voices = Downloader:getMbrolaVoiceList(plugin_dir)

    for idx, v in ipairs(voices) do
        if v.bundled then
            -- Bundled voices are already included; skip in download menu
            goto continue
        end
        local voice_id = v.id
        local voice_name = v.name
        local size_str = string.format(" · %.1f MB", v.size_mb)

        table.insert(menu, {
            text_func = function()
                local inst = Downloader:hasMbrolaVoice(voice_id, plugin_dir)
                local status = inst and _(" ✓ installed") or _("")
                return voice_name .. size_str .. status
            end,
            enabled_func = function()
                return not Downloader:hasMbrolaVoice(voice_id, plugin_dir)
            end,
            callback = function()
                if Downloader:hasMbrolaVoice(voice_id, plugin_dir) then return end
                local info = InfoMessage:new{
                    text = _("Downloading ") .. voice_name .. _("…\n(~")
                        .. string.format("%.1f", v.size_mb) .. _(" MB)"),
                    timeout = 0,
                }
                UIManager:show(info)
                Downloader:downloadMbrolaVoice(voice_id, plugin_dir,
                    function(done, total)
                        -- progress callback (optional)
                    end,
                    function(ok, err)
                        UIManager:close(info)
                        if ok then
                            -- Auto-select the downloaded voice
                            plugin:setSetting("tts_mbrola_voice", voice_id)
                            plugin:setSetting("tts_mbrola_voice_label", voice_name)
                            if plugin.tts_engine then
                                plugin.tts_engine:setVoice("mb-" .. voice_id)
                            end
                            UIManager:show(InfoMessage:new{
                                text = _("Voice installed:\n") .. voice_name
                                    .. _("\n\nIt is now selected as your active MBROLA voice."),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Download failed:\n") .. (err or _("unknown error")),
                                timeout = 5,
                            })
                        end
                    end
                )
            end,
        })
        ::continue::
    end

    if #menu == 0 then
        table.insert(menu, {
            text = _("All available MBROLA voices are already installed."),
            enabled = false,
        })
    end

    return menu
end

--[[--
Build the platform-native TTS settings menu.
--]]
function MenuBuilder.buildNativeTtsSettingsMenu(plugin)
    local menu = {}

    -- Helper path
    table.insert(menu, {
        text_func = function()
            local path = plugin:getSetting("native_helper_path", "")
            if path == "" then
                return _("Native helper: not set")
            end
            return T(_("Native helper: %1"), path)
        end,
        callback = function(touchmenu_instance)
            MenuBuilder._showNativeHelperPathChooser(plugin, touchmenu_instance)
        end,
    })

    -- Input encoding
    table.insert(menu, {
        text_func = function()
            return T(_("Input encoding: %1"), plugin:getSetting("native_input_encoding", "utf-8"):upper())
        end,
        sub_item_table = {
            {
                text = "UTF-8",
                checked_func = function()
                    return plugin:getSetting("native_input_encoding", "utf-8") == "utf-8"
                end,
                callback = function()
                    plugin:setSetting("native_input_encoding", "utf-8")
                end,
            },
            {
                text = "CP1252",
                checked_func = function()
                    return plugin:getSetting("native_input_encoding", "utf-8") == "cp1252"
                end,
                callback = function()
                    plugin:setSetting("native_input_encoding", "cp1252")
                end,
            },
        },
    })

    -- Speed mode
    table.insert(menu, {
        text_func = function()
            local mode = plugin:getSetting("native_speed_mode", "oneshot")
            local label = (mode == "daemon") and _("daemon/FIFO") or _("one-shot")
            return T(_("Speed mode: %1"), label)
        end,
        sub_item_table = {
            {
                text = _("One-shot (run helper per sentence)"),
                checked_func = function()
                    return plugin:getSetting("native_speed_mode", "oneshot") == "oneshot"
                end,
                callback = function()
                    plugin:setSetting("native_speed_mode", "oneshot")
                end,
            },
            {
                text = _("Daemon/FIFO (keep helper running)"),
                checked_func = function()
                    return plugin:getSetting("native_speed_mode", "oneshot") == "daemon"
                end,
                callback = function()
                    plugin:setSetting("native_speed_mode", "daemon")
                end,
            },
        },
    })

    -- FIFO path
    table.insert(menu, {
        text_func = function()
            local path = plugin:getSetting("native_fifo_path", "")
            if path == "" then
                return _("FIFO path: default")
            end
            return T(_("FIFO path: %1"), path)
        end,
        callback = function(touchmenu_instance)
            MenuBuilder._showNativeFifoPathDialog(plugin, touchmenu_instance)
        end,
    })

    -- Pre-synthesis command
    table.insert(menu, {
        text_func = function()
            local cmd = plugin:getSetting("native_prestep_command", "")
            if cmd == "" then
                return _("Pre-synthesis command: none")
            end
            return T(_("Pre-synthesis command: %1"), cmd)
        end,
        callback = function(touchmenu_instance)
            MenuBuilder._showNativePrestepDialog(plugin, touchmenu_instance)
        end,
    })

    return menu
end

--[[--
Show a PathChooser to select the platform-native helper executable.
--]]
function MenuBuilder._showNativeHelperPathChooser(plugin, touchmenu_instance)
    local PathChooser = require("ui/widget/pathchooser")
    local home_dir = require("datastorage").getDataDir() or "/mnt"
    UIManager:show(PathChooser:new{
        title = _("Select native TTS helper"),
        path = home_dir,
        select_file = true,
        onConfirm = function(file_path)
            plugin:setSetting("native_helper_path", file_path)
            if plugin.tts_engine then
                plugin.tts_engine.backend_cmd = file_path
            end
            if touchmenu_instance then
                touchmenu_instance:updateItems()
            end
            UIManager:show(InfoMessage:new{
                text = _("Native helper path saved."),
                timeout = 2,
            })
        end,
    })
end

--[[--
Show an InputDialog for the native TTS FIFO path.
--]]
function MenuBuilder._showNativeFifoPathDialog(plugin, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local current = plugin:getSetting("native_fifo_path", "")
    local dialog
    dialog = InputDialog:new{
        title = _("Native TTS FIFO path"),
        input = current,
        input_hint = "/tmp/audiobook_native_tts.fifo",
        description = _(
            "Optional path to the request FIFO used in daemon mode. "
            .. "Leave empty to use the default."
        ),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        plugin:setSetting("native_fifo_path", dialog:getInputText())
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--[[--
Show an InputDialog for the native TTS pre-synthesis command.
--]]
function MenuBuilder._showNativePrestepDialog(plugin, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local current = plugin:getSetting("native_prestep_command", "")
    local dialog
    dialog = InputDialog:new{
        title = _("Pre-synthesis command"),
        input = current,
        input_hint = "",
        description = _(
            "Optional shell command to run before each synthesis request "
            .. "(for example, to wake or restart a device-specific audio path)."
        ),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        plugin:setSetting("native_prestep_command", dialog:getInputText())
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--[[--
Paste / replace the ElevenLabs API key (stored in KOReader settings only).
--]]
function MenuBuilder._showElevenLabsKeyDialog(plugin, touchmenu_instance)
    local InputDialog = require("ui/widget/inputdialog")
    local current = plugin:getSetting("elevenlabs_api_key", "")
    local dialog
    dialog = InputDialog:new{
        title = _("ElevenLabs API key"),
        input = current,
        input_hint = "sk_…",
        text_type = "password",
        description = _(
            "Your key stays on this device in KOReader settings. "
            .. "It is never written into the plugin folder or bug reports."
        ),
        buttons = {
            {
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local key = dialog:getInputText() or ""
                        key = key:gsub("^%s+", ""):gsub("%s+$", "")
                        plugin:setSetting("elevenlabs_api_key", key)
                        UIManager:close(dialog)
                        if key ~= "" then
                            plugin:setSetting("tts_backend", plugin.tts_engine.BACKENDS.ELEVENLABS)
                            if plugin.tts_engine then
                                plugin.tts_engine:setBackend(plugin.tts_engine.BACKENDS.ELEVENLABS)
                            end
                        end
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

--[[--
Languages from the bundled HuggingFace Piper catalog (voices.json), plus
the CJK locales Android TTS already handled.  Used as Android TTS language
shortcuts — the ONNX models themselves do not run on Android.
--]]
function MenuBuilder.huggingfaceLanguageChoices()
    return {
        { id = "fr-FR", label = _("French") },
        { id = "en-US", label = _("English (US)") },
        { id = "en-GB", label = _("English (UK)") },
        { id = "es-ES", label = _("Spanish") },
        { id = "de-DE", label = _("German") },
        { id = "it-IT", label = _("Italian") },
        { id = "pt-BR", label = _("Portuguese (Brazil)") },
        { id = "nl-NL", label = _("Dutch") },
        { id = "pl-PL", label = _("Polish") },
        { id = "cs-CZ", label = _("Czech") },
        { id = "uk-UA", label = _("Ukrainian") },
        { id = "hi-IN", label = _("Hindi") },
        { id = "ar-JO", label = _("Arabic") },
        { id = "ca-ES", label = _("Catalan") },
        { id = "zh-CN", label = _("Chinese (Simplified)") },
        { id = "zh-TW", label = _("Chinese (Traditional)") },
        { id = "ja-JP", label = _("Japanese") },
        { id = "ko-KR", label = _("Korean") },
        { id = "da-DK", label = _("Danish") },
        { id = "fi-FI", label = _("Finnish") },
        { id = "ru-RU", label = _("Russian") },
        { id = "el-GR", label = _("Greek") },
        { id = "no-NO", label = _("Norwegian") },
        { id = "sv-SE", label = _("Swedish") },
        { id = "tr-TR", label = _("Turkish") },
        { id = "hu-HU", label = _("Hungarian") },
        { id = "ro-RO", label = _("Romanian") },
    }
end

local function _localePrefix(tag)
    if not tag or tag == "" then return "" end
    return (tag:lower():gsub("_", "-"):match("^(%a+)") or tag:lower())
end

function MenuBuilder._androidVoiceLabel(voice)
    local loc = voice.locale or ""
    local lang_label = loc
    for _, choice in ipairs(MenuBuilder.huggingfaceLanguageChoices()) do
        if choice.id:lower() == loc:lower()
            or _localePrefix(choice.id) == _localePrefix(loc) then
            lang_label = choice.label
            break
        end
    end
    local net = voice.network and _("online") or _("offline")
    if lang_label ~= "" then
        return T(_("%1 · %2 (%3)"), lang_label, voice.name, net)
    end
    return T(_("%1 (%2)"), voice.name, net)
end

function MenuBuilder.applyTtsLanguage(plugin, lang, label)
    plugin:setSetting("android_tts_language", lang)
    plugin:setSetting("android_tts_voice", "")
    plugin:setSetting("android_tts_voice_label", label or lang)
    if plugin.tts_engine and plugin.tts_engine.invalidateAndroidVoice then
        plugin.tts_engine:invalidateAndroidVoice()
    end
    local atts = plugin.tts_engine and plugin.tts_engine._android_tts
    if atts and atts.setLanguage and lang and lang ~= "auto" then
        pcall(function() atts:setLanguage(lang) end)
        plugin.tts_engine._android_tts_lang = lang
        plugin.tts_engine._android_tts_voice = nil
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Voice set to %1."), label or lang),
        timeout = 2,
    })
end

function MenuBuilder.applyAndroidInstalledVoice(plugin, voice)
    local label = MenuBuilder._androidVoiceLabel(voice)
    plugin:setSetting("android_tts_voice", voice.name)
    if voice.locale and voice.locale ~= "" then
        plugin:setSetting("android_tts_language", voice.locale)
    end
    plugin:setSetting("android_tts_voice_label", label)
    if plugin.tts_engine and plugin.tts_engine.invalidateAndroidVoice then
        plugin.tts_engine:invalidateAndroidVoice()
    end
    local atts = plugin.tts_engine and plugin.tts_engine._android_tts
    if atts and atts.setVoice then
        pcall(function() atts:setVoice(voice.name) end)
        plugin.tts_engine._android_tts_voice = voice.name
        plugin.tts_engine._android_tts_lang = "voice:" .. voice.name
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Voice set to %1."), label),
        timeout = 2,
    })
end

--[[--
Paginated ButtonDialog picker.  Full Menu widgets have crashed on Boox;
this is the same pattern as the chapter list.
--]]
function MenuBuilder.showPagedPicker(opts)
    local items = opts.items or {}
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = opts.empty_text or _("No voices found."),
            timeout = 3,
        })
        return
    end
    local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if not ok_bd or not ButtonDialog then
        logger.err("MenuBuilder: ButtonDialog unavailable:", ButtonDialog)
        UIManager:show(InfoMessage:new{
            text = _("Could not open voice list."),
            timeout = 4,
        })
        return
    end

    local PAGE_SIZE = 8
    local page = 1
    local current = tonumber(opts.current) or 1
    if current < 1 then current = 1 end
    if current > #items then current = #items end
    page = math.floor((current - 1) / PAGE_SIZE) + 1

    local dialog
    local function close_picker()
        if dialog then
            pcall(function() UIManager:close(dialog) end)
        end
        dialog = nil
    end

    local function show_page()
        local total_pages = math.max(1, math.ceil(#items / PAGE_SIZE))
        if page < 1 then page = 1 end
        if page > total_pages then page = total_pages end
        local first = (page - 1) * PAGE_SIZE + 1
        local last = math.min(#items, page * PAGE_SIZE)

        local buttons = {}
        for i = first, last do
            local item = items[i]
            if item then
                local label = tostring(item.text or (_("Item") .. " " .. i))
                if #label > 80 then
                    label = label:sub(1, 77) .. "..."
                end
                if i == current then
                    label = "> " .. label
                end
                local cb = item.callback
                local enabled = item.enabled
                if enabled == nil then enabled = (cb ~= nil) end
                table.insert(buttons, {{
                    text = label,
                    enabled = enabled,
                    callback = function()
                        if not cb then return end
                        close_picker()
                        UIManager:scheduleIn(0.1, function()
                            pcall(cb)
                        end)
                    end,
                }})
            end
        end

        table.insert(buttons, {
            {
                text = _("Prev"),
                enabled = page > 1,
                callback = function()
                    page = page - 1
                    close_picker()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
            {
                text = _("Close"),
                callback = close_picker,
            },
            {
                text = _("Next"),
                enabled = page < total_pages,
                callback = function()
                    page = page + 1
                    close_picker()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
        })

        local title = string.format("%s (%d/%d)",
            tostring(opts.title or _("Select voice")), page, total_pages)
        local ok, err = pcall(function()
            dialog = ButtonDialog:new{
                title = title,
                buttons = buttons,
            }
            UIManager:show(dialog)
        end)
        if not ok then
            logger.err("MenuBuilder: voice ButtonDialog failed:", err)
            UIManager:show(InfoMessage:new{
                text = _("Could not open voice list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end

    UIManager:scheduleIn(0.15, function()
        local ok, err = pcall(show_page)
        if not ok then
            logger.err("MenuBuilder: voice picker failed:", err)
            UIManager:show(InfoMessage:new{
                text = _("Could not open voice list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end)
end

function MenuBuilder._androidVoicePickerItems(plugin)
    local items = {}
    local current_voice = plugin:getSetting("android_tts_voice", "")
    local current_lang = plugin:getSetting("android_tts_language", "auto")
    local current_idx = 1

    table.insert(items, {
        text = _("Auto (book language)"),
        callback = function()
            MenuBuilder.applyTtsLanguage(plugin, "auto", _("Auto-detect"))
        end,
    })
    if current_voice == "" and current_lang == "auto" then
        current_idx = #items
    end

    table.insert(items, {
        text = "— " .. _("Languages") .. " —",
        enabled = false,
    })

    local book_lang
    if plugin.tts_engine and plugin.tts_engine._androidBookLanguage then
        book_lang = plugin.tts_engine:_androidBookLanguage()
    end
    local langs = MenuBuilder.huggingfaceLanguageChoices()
    -- Book language first so a French EPUB surfaces French immediately.
    table.sort(langs, function(a, b)
        local function rank(c)
            if book_lang and (c.id:lower() == book_lang:lower()
                or _localePrefix(c.id) == _localePrefix(book_lang)) then
                return 0
            end
            return 1
        end
        local ra, rb = rank(a), rank(b)
        if ra ~= rb then return ra < rb end
        return a.label < b.label
    end)
    for _, choice in ipairs(langs) do
        table.insert(items, {
            text = choice.label,
            callback = function()
                MenuBuilder.applyTtsLanguage(plugin, choice.id, choice.label)
            end,
        })
        if current_voice == "" and current_lang:lower() == choice.id:lower() then
            current_idx = #items
        end
    end

    local voices = {}
    if plugin.tts_engine and plugin.tts_engine.listAndroidVoices then
        voices = plugin.tts_engine:listAndroidVoices() or {}
    end
    if #voices > 0 then
        table.insert(items, {
            text = "— " .. _("Installed voices") .. " —",
            enabled = false,
        })
        local prefer = current_lang ~= "auto" and current_lang or book_lang or ""
        table.sort(voices, function(a, b)
            local function rank(v)
                local r = 2
                if prefer ~= "" and v.locale
                    and _localePrefix(v.locale) == _localePrefix(prefer) then
                    r = 0
                end
                if v.network then r = r + 1 end
                return r, -(v.quality or 0), v.name or ""
            end
            local ra, qa, na = rank(a)
            local rb, qb, nb = rank(b)
            if ra ~= rb then return ra < rb end
            if qa ~= qb then return qa < qb end
            return na < nb
        end)
        for _, voice in ipairs(voices) do
            table.insert(items, {
                text = MenuBuilder._androidVoiceLabel(voice),
                callback = function()
                    MenuBuilder.applyAndroidInstalledVoice(plugin, voice)
                end,
            })
            if current_voice ~= "" and current_voice == voice.name then
                current_idx = #items
            end
        end
    end

    return items, current_idx
end

function MenuBuilder._piperVoicePickerItems(plugin)
    local items = {}
    local current = 1
    local voices = plugin.tts_engine and plugin.tts_engine.listPiperVoices
        and plugin.tts_engine:listPiperVoices() or {}
    local selected = plugin:getSetting("piper_model", nil)
    for i, voice in ipairs(voices) do
        local label = voice.name or voice.path or ("voice " .. i)
        if voice.quality then
            label = label .. " (" .. voice.quality .. ")"
        end
        table.insert(items, {
            text = label,
            callback = function()
                plugin.tts_engine:setPiperModel(voice.path)
                plugin:setSetting("piper_model", voice.path)
                plugin:setSetting("piper_model_label", label)
                UIManager:show(InfoMessage:new{
                    text = T(_("Voice set to %1."), label),
                    timeout = 2,
                })
            end,
        })
        if selected and selected == voice.path then
            current = #items
        end
    end
    return items, current
end

function MenuBuilder._espeakVoicePickerItems(plugin)
    local items = {}
    local current = 1
    local selected = plugin:getSetting("tts_voice", "en")
    local accents = MenuBuilder.huggingfaceLanguageChoices()
    for _, choice in ipairs(accents) do
        local espeak_id = _localePrefix(choice.id)
        if espeak_id == "en" then
            espeak_id = (choice.id == "en-US") and "en-us" or "en"
        elseif espeak_id == "pt" and choice.id == "pt-BR" then
            espeak_id = "pt-br"
        end
        table.insert(items, {
            text = choice.label,
            callback = function()
                local var = plugin:getSetting("tts_voice_variant", "")
                local full = espeak_id
                if var ~= "" then full = espeak_id .. "+" .. var end
                plugin:setSetting("tts_voice", espeak_id)
                plugin:setSetting("tts_voice_label", choice.label)
                if plugin.tts_engine then
                    plugin.tts_engine:setVoice(full)
                end
                UIManager:show(InfoMessage:new{
                    text = T(_("Voice set to %1."), choice.label),
                    timeout = 2,
                })
            end,
        })
        if selected == espeak_id then
            current = #items
        end
    end
    return items, current
end

local function _elevenLabsLangStored(plugin)
    local s = plugin:getSetting("elevenlabs_language", "auto")
    if type(s) ~= "string" or s == "" then return "auto" end
    return s
end

--- ISO code actually sent in ElevenLabs requests (auto resolved).
local function _elevenLabsLangPrefix(plugin)
    return ElevenLabs.resolvedRequestLanguage(plugin, plugin.tts_engine)
end

local function _elevenLabsLangLabel(prefix)
    prefix = ElevenLabs.isoLang(prefix) or prefix or "en"
    for _, choice in ipairs(MenuBuilder.huggingfaceLanguageChoices()) do
        if _localePrefix(choice.id) == prefix then
            return choice.label
        end
    end
    return prefix
end

function MenuBuilder.elevenLabsRequestLanguageText(plugin)
    local stored = _elevenLabsLangStored(plugin)
    local iso, source = ElevenLabs.resolvedRequestLanguage(plugin, plugin.tts_engine)
    local name = _elevenLabsLangLabel(iso)
    if stored == "auto" then
        if source == "book" then
            return T(_("Request language: Auto (%1, book)"), name)
        elseif source == "system" then
            return T(_("Request language: Auto (%1, device)"), name)
        end
        return T(_("Request language: Auto (%1)"), name)
    end
    return T(_("Request language: %1 (forced)"), name)
end

function MenuBuilder.buildElevenLabsLanguageMenu(plugin)
    local menu = {}
    local function add(id, label)
        table.insert(menu, {
            text = label,
            checked_func = function()
                return _elevenLabsLangStored(plugin) == id
            end,
            callback = function()
                plugin:setSetting("elevenlabs_language", id)
                if plugin.tts_engine and plugin.tts_engine.invalidateQueuedAudio then
                    pcall(function() plugin.tts_engine:invalidateQueuedAudio() end)
                end
            end,
        })
    end
    add("auto", _("Auto (book language, then device)"))
    local first = { "fr", "en", "es", "de", "it", "pt" }
    local seen = { auto = true }
    for _, prefix in ipairs(first) do
        add(prefix, _elevenLabsLangLabel(prefix))
        seen[prefix] = true
    end
    for _, choice in ipairs(MenuBuilder.huggingfaceLanguageChoices()) do
        local prefix = _localePrefix(choice.id)
        if prefix ~= "" and not seen[prefix] then
            add(prefix, choice.label)
            seen[prefix] = true
        end
    end
    return menu
end

function MenuBuilder.buildElevenLabsSettingsMenu(plugin)
    local menu = {}
    table.insert(menu, {
        text_func = function()
            local key = plugin:getSetting("elevenlabs_api_key", "")
            local masked = ElevenLabs.maskKey(key)
            if masked == "" then
                return _("ElevenLabs API key (not set)")
            end
            return T(_("ElevenLabs API key: %1"), masked)
        end,
        callback = function(touchmenu_instance)
            MenuBuilder._showElevenLabsKeyDialog(plugin, touchmenu_instance)
        end,
        help_text = _(
            "Paste your ElevenLabs API key (xi-api-key). "
            .. "It is stored only in KOReader settings, never in the plugin files."
        ),
    })
    table.insert(menu, {
        text_func = function()
            local label = plugin:getSetting("elevenlabs_voice_label", "")
            if label == "" then
                label = plugin:getSetting("elevenlabs_voice_id", "")
            end
            if label == "" then
                return _("Voice: default")
            end
            return T(_("Voice: %1"), label)
        end,
        callback = function(touchmenu_instance)
            if touchmenu_instance then
                touchmenu_instance:closeMenu()
            end
            MenuBuilder.showVoicePicker(plugin, { engine = "elevenlabs" })
        end,
        help_text = _(
            "The voice’s accent is separate from the request language. "
            .. "A named English voice can still read French if the request language is French."
        ),
    })
    table.insert(menu, {
        text_func = function()
            return MenuBuilder.elevenLabsRequestLanguageText(plugin)
        end,
        sub_item_table_func = function()
            return MenuBuilder.buildElevenLabsLanguageMenu(plugin)
        end,
        help_text = _(
            "Language sent to ElevenLabs with every sentence. "
            .. "Auto uses the book language, or the device language if the book has none. "
            .. "Force a language when the book is mis-tagged or mixed. "
            .. "This is not the System TTS language."
        ),
    })
    table.insert(menu, {
        text_func = function()
            local m = plugin:getSetting("elevenlabs_model", "eleven_multilingual_v2")
            if m == "eleven_flash_v2_5" then
                return _("Model: Flash v2.5 (faster)")
            end
            return _("Model: Multilingual v2 (quality)")
        end,
        checked_func = function()
            return plugin:getSetting("elevenlabs_model", "eleven_multilingual_v2")
                == "eleven_flash_v2_5"
        end,
        callback = function()
            local cur = plugin:getSetting("elevenlabs_model", "eleven_multilingual_v2")
            if cur == "eleven_flash_v2_5" then
                plugin:setSetting("elevenlabs_model", "eleven_multilingual_v2")
            else
                plugin:setSetting("elevenlabs_model", "eleven_flash_v2_5")
            end
        end,
        help_text = _(
            "Multilingual v2 is best for French/English/Spanish books. "
            .. "Flash v2.5 is cheaper and lower latency, slightly less natural."
        ),
    })
    return menu
end

function MenuBuilder.buildSystemTtsSettingsMenu(plugin)
    local menu = {}
    local Device = require("device")
    if not (Device.isAndroid and Device:isAndroid()) then
        table.insert(menu, {
            text = _("System TTS is available on Android devices."),
            enabled = false,
        })
        return menu
    end
    -- Init the helper if System TTS is the active backend, so the
    -- preferred-engine row can show SherpaTTS / Google / …  Do not start
    -- Android TTS just because the user opened this submenu from ElevenLabs.
    local engine = plugin.tts_engine
    if engine and engine.BACKENDS and engine.backend == engine.BACKENDS.ANDROID
        and engine._ensureAndroidTts then
        pcall(function() engine:_ensureAndroidTts() end)
    end
    table.insert(menu, {
        text_func = function()
            local name = MenuBuilder.androidSystemEngineName(plugin)
            return T(_("Engine: %1"), name or _("Not detected"))
        end,
        enabled = false,
        help_text = _(
            "This is Android's preferred TTS engine. "
            .. "Change it in system Settings → Language & input → Text-to-speech."
        ),
    })
    table.insert(menu, {
        text_func = function()
            local label = plugin:getSetting("android_tts_voice_label", "")
            if label ~= "" then
                return T(_("Voice: %1"), label)
            end
            local lang = plugin:getSetting("android_tts_language", "auto")
            if lang == "auto" then
                return T(_("Voice: %1"), _("Auto-detect"))
            end
            return T(_("Voice: %1"), lang)
        end,
        callback = function(touchmenu_instance)
            if touchmenu_instance then
                touchmenu_instance:closeMenu()
            end
            MenuBuilder.showVoicePicker(plugin, { engine = "android" })
        end,
        help_text = _(
            "On-device engine (Google, SherpaTTS, …). "
            .. "Independent from the language sent to ElevenLabs."
        ),
    })
    return menu
end

function MenuBuilder._commitElevenLabsVoice(plugin, id, name)
    if not id or id == "" then return end
    plugin:setSetting("elevenlabs_voice_id", id)
    plugin:setSetting("elevenlabs_voice_label", name or id)
    if plugin.tts_engine and plugin.tts_engine.invalidateQueuedAudio then
        pcall(function() plugin.tts_engine:invalidateQueuedAudio() end)
    end
    UIManager:show(InfoMessage:new{
        text = T(_("Voice set to %1."), name or id),
        timeout = 2,
    })
end

function MenuBuilder._resolveElevenLabsVoiceId(plugin, voice, key, on_done)
    if not voice or not voice.id then
        if on_done then on_done(nil, "no voice") end
        return
    end
    if voice.source ~= "library" or voice.added or voice.owner_id == "" then
        if on_done then on_done(voice.id, voice.name) end
        return
    end
    local info = InfoMessage:new{
        text = _("Adding ElevenLabs voice…"),
        timeout = 0,
    }
    UIManager:show(info)
    UIManager:scheduleIn(0.05, function()
        local id, err = ElevenLabs.addSharedVoice(key, voice.owner_id, voice.id, voice.name)
        UIManager:close(info)
        if not id then
            if on_done then on_done(nil, err or "error") end
            return
        end
        if on_done then on_done(id, voice.name) end
    end)
end

function MenuBuilder._selectElevenLabsVoice(plugin, voice, key)
    MenuBuilder._resolveElevenLabsVoiceId(plugin, voice, key, function(id, name_or_err)
        if not id then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not add this library voice: %1"), tostring(name_or_err or "error")),
                timeout = 6,
            })
            return
        end
        MenuBuilder._commitElevenLabsVoice(plugin, id, name_or_err)
    end)
end

local function _elPreviewPath(plugin)
    local engine = plugin and plugin.tts_engine
    local atts = engine and engine._android_tts
    local dir = "/tmp"
    if atts and atts.getTempDir then
        dir = atts:getTempDir() or dir
    elseif plugin then
        dir = "/sdcard/koreader/cache"
    end
    return dir .. "/audiobook_el_preview.mp3"
end

--- 2–3 sentences from the start of the current chapter (or this page).
--- Never logs book text. Restores the view afterwards.
function MenuBuilder._chapterPreviewSample(plugin)
    local ui = plugin and plugin.ui
    local doc = ui and ui.document
    if not doc then return nil end
    local parser = plugin.sync_controller and plugin.sync_controller.text_parser
    if not parser or not parser.parse then return nil end

    local saved_pos
    if ui.rolling and doc.getCurrentPos then
        local ok, pos = pcall(function() return doc:getCurrentPos() end)
        if ok then saved_pos = pos end
    end
    plugin._peeking_adjacent_page = true
    local function restore()
        if saved_pos and doc.gotoPos then
            pcall(function() doc:gotoPos(saved_pos) end)
        end
        plugin._peeking_adjacent_page = false
    end

    local toc
    if doc.getToc then
        local ok, t = pcall(function() return doc:getToc() end)
        if ok and type(t) == "table" then toc = t end
    end
    local current_page
    if doc.getCurrentPage then
        local ok, p = pcall(function() return doc:getCurrentPage() end)
        if ok then current_page = p end
    end
    local entry
    if toc and current_page then
        for _, e in ipairs(toc) do
            if e.page and e.page <= current_page then
                entry = e
            end
        end
    end
    if entry and entry.xpointer and ui.rolling and doc.gotoXPointer then
        pcall(function() doc:gotoXPointer(entry.xpointer) end)
    end

    local Screen = require("device").screen
    local chunks = {}
    local sample
    for _hop = 1, 4 do
        local text = plugin.getCurrentPageText and plugin:getCurrentPageText()
        if text and text ~= "" then
            chunks[#chunks + 1] = text
        end
        local parsed = parser:parse(table.concat(chunks, "\n"))
        local n = parsed and parsed.sentences and #parsed.sentences or 0
        if n > 0 then
            local take = math.min(3, n)
            local parts = {}
            for i = 1, take do
                parts[i] = parsed.sentences[i].text
            end
            sample = table.concat(parts, " ")
            if take >= 3 or #sample > 80 then
                break
            end
        end
        if not (ui.rolling and doc.gotoPos and doc.getCurrentPos) then
            break
        end
        pcall(function()
            doc:gotoPos(doc:getCurrentPos() + Screen:getHeight())
        end)
    end
    restore()
    if type(sample) ~= "string" or sample:match("^%s*$") then
        return nil
    end
    if #sample > 900 then
        sample = sample:sub(1, 900)
    end
    return sample
end

function MenuBuilder._stopElevenLabsPreview(plugin)
    local sess = plugin and plugin._el_voice_sess
    if sess then
        sess.preview_gen = (sess.preview_gen or 0) + 1
    end
    local engine = plugin and plugin.tts_engine
    if engine and engine.beginVoicePreview then
        pcall(function() engine:beginVoicePreview() end)
    elseif engine and engine._android_tts and engine._android_tts.stopPlayback then
        pcall(function() engine._android_tts:stopPlayback() end)
    end
    local path = _elPreviewPath(plugin)
    pcall(os.remove, path)
    -- Previous builds wrote a .wav preview.
    if type(path) == "string" then
        pcall(os.remove, path:gsub("%.mp3$", ".wav"))
    end
end

function MenuBuilder._restoreTtsAfterVoiceUi(plugin)
    if not plugin or not plugin._el_preview_used then return end
    plugin._el_preview_used = nil
    local sc = plugin.sync_controller
    if sc and sc.replayCurrentSentence then
        pcall(function() sc:replayCurrentSentence() end)
    end
end

function MenuBuilder._previewElevenLabsVoice(plugin, voice, key, on_ready)
    local sess = plugin._el_voice_sess
    if not sess then
        sess = { preview_gen = 0, mode = "test" }
        plugin._el_voice_sess = sess
    end
    sess.preview_gen = (sess.preview_gen or 0) + 1
    local my_gen = sess.preview_gen
    local sample = MenuBuilder._chapterPreviewSample(plugin)
    if not sample then
        UIManager:show(InfoMessage:new{
            text = _("No text found to preview."),
            timeout = 3,
        })
        if on_ready then on_ready(false) end
        return
    end
    MenuBuilder._resolveElevenLabsVoiceId(plugin, voice, key, function(id, name_or_err)
        if sess.preview_gen ~= my_gen then
            if on_ready then on_ready(false) end
            return
        end
        if not id then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not add this library voice: %1"), tostring(name_or_err or "error")),
                timeout = 6,
            })
            if on_ready then on_ready(false) end
            return
        end
        local engine = plugin.tts_engine
        if not engine then
            if on_ready then on_ready(false) end
            return
        end
        local sc = plugin.sync_controller
        if sc and sc.isPlaying and sc:isPlaying() then
            plugin._el_preview_used = true
            pcall(function() sc:pause() end)
        elseif sc and sc.isPaused and sc:isPaused() then
            plugin._el_preview_used = true
        end
        if engine.beginVoicePreview then
            engine:beginVoicePreview()
        end
        sess.last_tested = {
            id = id,
            name = name_or_err or voice.name or id,
            orig_id = voice.id,
        }

        local wait = InfoMessage:new{
            text = T(_("Previewing %1…"), sess.last_tested.name),
            timeout = 0,
        }
        UIManager:show(wait)

        local dest = _elPreviewPath(plugin)
        pcall(os.remove, dest)
        local model = plugin:getSetting("elevenlabs_model", "")
        if model == "" then model = ElevenLabs.DEFAULT_MODEL end
        local lang = ElevenLabs.isoLang(_elevenLabsLangPrefix(plugin))
        local url, body = ElevenLabs.buildPost(sample, {
            voice_id = id,
            model = model,
            language_code = lang,
        })
        local atts = engine._android_tts or (engine._ensureAndroidTts and engine:_ensureAndroidTts())
        local function playReady()
            if not sess or sess.preview_gen ~= my_gen then
                UIManager:close(wait)
                return
            end
            ElevenLabs.ensureWav(dest)
            UIManager:close(wait)
            if engine.playClipFile then
                engine:playClipFile(dest)
            elseif atts and atts.playMediaFile then
                atts:playMediaFile(dest)
            elseif atts and atts.playFile then
                atts:playFile(dest)
            end
            if on_ready then on_ready(true) end
        end
        if atts and atts.httpPostToFile then
            local job = atts:httpPostToFile(url, key, body, dest)
            if not job or job < 1 then
                UIManager:close(wait)
                UIManager:show(InfoMessage:new{
                    text = T(_("Could not preview this voice: %1"), "http"),
                    timeout = 4,
                })
                if on_ready then on_ready(false) end
                return
            end
            local polls = 0
            local function pollJob()
                if not sess or sess.preview_gen ~= my_gen then
                    UIManager:close(wait)
                    return
                end
                local st = atts.getHttpJobStatus and atts:getHttpJobStatus(job) or -1
                if st == 1 then
                    playReady()
                    return
                elseif st == 2 then
                    UIManager:close(wait)
                    local err = atts.getHttpLastError and atts:getHttpLastError() or "error"
                    UIManager:show(InfoMessage:new{
                        text = T(_("Could not preview this voice: %1"), tostring(err)),
                        timeout = 5,
                    })
                    if on_ready then on_ready(false) end
                    return
                end
                polls = polls + 1
                if polls > 200 then
                    UIManager:close(wait)
                    UIManager:show(InfoMessage:new{
                        text = T(_("Could not preview this voice: %1"), "timeout"),
                        timeout = 4,
                    })
                    if on_ready then on_ready(false) end
                    return
                end
                UIManager:scheduleIn(0.15, pollJob)
            end
            UIManager:scheduleIn(0.15, pollJob)
            return
        end
        local path, err = ElevenLabs.synthesize(key, dest, sample, {
            voice_id = id,
            model = model,
            language_code = lang,
        })
        if not path then
            UIManager:close(wait)
            UIManager:show(InfoMessage:new{
                text = T(_("Could not preview this voice: %1"), tostring(err or "error")),
                timeout = 5,
            })
            if on_ready then on_ready(false) end
            return
        end
        playReady()
    end)
end

function MenuBuilder._runElevenLabsVoiceDialog(plugin, opts)
    local items = opts.items or {}
    local key = opts.key
    local current = tonumber(opts.current) or 1
    local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if not ok_bd or not ButtonDialog then
        UIManager:show(InfoMessage:new{
            text = _("Could not open voice list."),
            timeout = 4,
        })
        return
    end

    plugin._el_voice_sess = plugin._el_voice_sess or {}
    local sess = plugin._el_voice_sess
    sess.mode = sess.mode or "select"
    sess.preview_gen = sess.preview_gen or 0
    if not opts.keep_restore then
        sess.last_tested = nil
        sess.mode = "select"
    end

    local PAGE_SIZE = 7
    local page = math.floor((math.max(1, current) - 1) / PAGE_SIZE) + 1
    local dialog
    local dismissing = true

    local function close_dialog()
        if dialog then
            pcall(function() UIManager:close(dialog) end)
        end
        dialog = nil
    end

    local function finish(restore)
        MenuBuilder._stopElevenLabsPreview(plugin)
        close_dialog()
        if restore then
            MenuBuilder._restoreTtsAfterVoiceUi(plugin)
        else
            plugin._el_preview_used = nil
        end
    end

    local function show_page()
        local total_pages = math.max(1, math.ceil(#items / PAGE_SIZE))
        if page < 1 then page = 1 end
        if page > total_pages then page = total_pages end
        local first = (page - 1) * PAGE_SIZE + 1
        local last = math.min(#items, page * PAGE_SIZE)
        local current_id = plugin:getSetting("elevenlabs_voice_id", "")

        local buttons = {}
        for i = first, last do
            local item = items[i]
            if item then
                local label = tostring(item.text or (_("Item") .. " " .. i))
                if #label > 72 then
                    label = label:sub(1, 69) .. "..."
                end
                if item.voice and item.voice.id == current_id then
                    label = "> " .. label
                elseif item.voice and sess.last_tested
                    and (item.voice.id == sess.last_tested.id
                        or item.voice.id == sess.last_tested.orig_id) then
                    label = "~ " .. label
                end
                local enabled = item.enabled
                if enabled == nil then enabled = true end
                local voice = item.voice
                local cb = item.callback
                table.insert(buttons, {{
                    text = label,
                    enabled = enabled and (cb ~= nil or voice ~= nil),
                    callback = function()
                        if cb then
                            dismissing = false
                            MenuBuilder._stopElevenLabsPreview(plugin)
                            close_dialog()
                            UIManager:scheduleIn(0.1, function()
                                pcall(cb)
                            end)
                            return
                        end
                        if not voice then return end
                        if sess.mode == "test" then
                            MenuBuilder._previewElevenLabsVoice(plugin, voice, key, function()
                                close_dialog()
                                UIManager:scheduleIn(0.05, show_page)
                            end)
                            return
                        end
                        dismissing = false
                        MenuBuilder._stopElevenLabsPreview(plugin)
                        close_dialog()
                        MenuBuilder._resolveElevenLabsVoiceId(plugin, voice, key, function(id, name_or_err)
                            if not id then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Could not add this library voice: %1"),
                                        tostring(name_or_err or "error")),
                                    timeout = 6,
                                })
                                MenuBuilder._restoreTtsAfterVoiceUi(plugin)
                                return
                            end
                            MenuBuilder._commitElevenLabsVoice(plugin, id, name_or_err)
                            if plugin._el_preview_used then
                                MenuBuilder._restoreTtsAfterVoiceUi(plugin)
                            end
                        end)
                    end,
                }})
            end
        end

        local test_label = _("Test voice")
        local select_label = _("Select this voice")
        if sess.mode == "test" then
            test_label = "● " .. test_label
        else
            select_label = "● " .. select_label
        end
        table.insert(buttons, {
            {
                text = test_label,
                callback = function()
                    sess.mode = "test"
                    close_dialog()
                    UIManager:scheduleIn(0.05, show_page)
                    UIManager:show(InfoMessage:new{
                        text = _("Tap a voice to hear the start of this chapter."),
                        timeout = 2,
                    })
                end,
            },
            {
                text = select_label,
                callback = function()
                    if sess.mode == "test" and sess.last_tested then
                        dismissing = false
                        local picked = sess.last_tested
                        MenuBuilder._stopElevenLabsPreview(plugin)
                        close_dialog()
                        MenuBuilder._commitElevenLabsVoice(plugin, picked.id, picked.name)
                        if plugin._el_preview_used then
                            MenuBuilder._restoreTtsAfterVoiceUi(plugin)
                        end
                        return
                    end
                    sess.mode = "select"
                    close_dialog()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
        })
        table.insert(buttons, {
            {
                text = _("Prev"),
                enabled = page > 1,
                callback = function()
                    page = page - 1
                    close_dialog()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    finish(true)
                end,
            },
            {
                text = _("Next"),
                enabled = page < total_pages,
                callback = function()
                    page = page + 1
                    close_dialog()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
        })

        local lang_label = opts.lang_label or ""
        local title
        if sess.mode == "test" then
            title = T(_("Test ElevenLabs voice (%1)"), lang_label)
        else
            title = T(_("Select ElevenLabs voice (%1)"), lang_label)
        end
        title = string.format("%s (%d/%d)", title, page, total_pages)
        local ok, err = pcall(function()
            dialog = ButtonDialog:new{
                title = title,
                buttons = buttons,
            }
            UIManager:show(dialog)
        end)
        if not ok then
            logger.err("MenuBuilder: ElevenLabs voice dialog failed:", err)
            UIManager:show(InfoMessage:new{
                text = _("Could not open voice list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end

    UIManager:scheduleIn(0.15, show_page)
end

function MenuBuilder._showElevenLabsVoicePicker(plugin, picker_opts)
    picker_opts = picker_opts or {}
    local key = plugin:getSetting("elevenlabs_api_key", "")
    if key == "" then
        MenuBuilder._showElevenLabsKeyDialog(plugin)
        return
    end
    if not picker_opts.keep_restore then
        plugin._el_preview_used = nil
        if plugin._el_voice_sess then
            plugin._el_voice_sess.last_tested = nil
            plugin._el_voice_sess.mode = "select"
        end
    end
    local lang = _elevenLabsLangPrefix(plugin)
    local lang_label = _elevenLabsLangLabel(lang)
    local info = InfoMessage:new{
        text = _("Loading ElevenLabs voices…"),
        timeout = 0,
    }
    UIManager:show(info)
    UIManager:scheduleIn(0.05, function()
        local account, err = ElevenLabs.listVoices(key)
        local library, lib_err = ElevenLabs.listSharedVoices(key, lang)
        UIManager:close(info)
        if not account then
            UIManager:show(InfoMessage:new{
                text = T(_("Could not list ElevenLabs voices: %1"), tostring(err or "empty")),
                timeout = 5,
            })
            return
        end
        if type(library) ~= "table" then
            logger.warn("ElevenLabs: shared voice list failed:", tostring(lib_err))
            library = {}
        end

        local current_id = plugin:getSetting("elevenlabs_voice_id", "")
        local items, current = {}, 1

        local function addVoice(v)
            table.insert(items, {
                text = ElevenLabs.displayName(v),
                voice = v,
            })
            if v.id == current_id then current = #items end
        end

        table.insert(items, {
            text = MenuBuilder.elevenLabsRequestLanguageText(plugin),
            callback = function()
                MenuBuilder._showElevenLabsLangPicker(plugin, { after = "voice_picker" })
            end,
        })

        local lib_matched = {}
        for _, v in ipairs(library) do
            lib_matched[#lib_matched + 1] = v
        end
        if #lib_matched > 0 then
            table.insert(items, {
                text = "— " .. T(_("Library (%1)"), lang_label) .. " —",
                enabled = false,
            })
            for _, v in ipairs(lib_matched) do addVoice(v) end
        elseif lang ~= "en" then
            table.insert(items, {
                text = "— " .. T(_("No library voices for %1"), lang_label) .. " —",
                enabled = false,
            })
        end

        table.sort(account, function(a, b)
            local ma, mb = ElevenLabs.matchesLang(a, lang), ElevenLabs.matchesLang(b, lang)
            if ma ~= mb then return ma end
            return (a.name or "") < (b.name or "")
        end)
        table.insert(items, {
            text = "— " .. _("Your voices (multilingual)") .. " —",
            enabled = false,
        })
        for _, v in ipairs(account) do addVoice(v) end

        MenuBuilder._runElevenLabsVoiceDialog(plugin, {
            items = items,
            current = current,
            key = key,
            lang_label = lang_label,
            keep_restore = picker_opts.keep_restore,
        })
    end)
end

function MenuBuilder._showElevenLabsLangPicker(plugin, opts)
    opts = opts or {}
    local after = opts.after or "voice_picker"
    local current_lang = _elevenLabsLangStored(plugin)
    local items, current = {}, 1
    local function addLang(id, label)
        table.insert(items, {
            text = label,
            callback = function()
                plugin:setSetting("elevenlabs_language", id)
                if plugin.tts_engine and plugin.tts_engine.invalidateQueuedAudio then
                    pcall(function() plugin.tts_engine:invalidateQueuedAudio() end)
                end
                if after == "voice_picker" then
                    MenuBuilder._showElevenLabsVoicePicker(plugin, { keep_restore = true })
                elseif after == "tts_settings" then
                    MenuBuilder.showTtsSettingsPicker(plugin)
                end
            end,
        })
        if id == current_lang then current = #items end
    end
    addLang("auto", _("Auto (book language, then device)"))
    -- Prefer the languages the user actually reads.
    local first = { "fr", "en", "es", "de", "it", "pt" }
    local seen = { auto = true }
    for _, prefix in ipairs(first) do
        addLang(prefix, _elevenLabsLangLabel(prefix))
        seen[prefix] = true
    end
    for _, choice in ipairs(MenuBuilder.huggingfaceLanguageChoices()) do
        local prefix = _localePrefix(choice.id)
        if prefix ~= "" and not seen[prefix] then
            addLang(prefix, choice.label)
            seen[prefix] = true
        end
    end
    MenuBuilder.showPagedPicker({
        title = _("ElevenLabs language"),
        items = items,
        current = current,
    })
end

--[[--
Show a voice picker for the given engine (`opts.engine`) or the active TTS
backend.  Safe to call from the playback overlay or from TTS settings.
--]]
function MenuBuilder.showVoicePicker(plugin, opts)
    opts = opts or {}
    if not plugin or not plugin.tts_engine then
        UIManager:show(InfoMessage:new{
            text = _("TTS engine is not available."),
            timeout = 3,
        })
        return
    end
    local backend = plugin.tts_engine.backend
    local force = opts.engine
    if force == "elevenlabs"
        or (not force and backend == plugin.tts_engine.BACKENDS.ELEVENLABS) then
        MenuBuilder._showElevenLabsVoicePicker(plugin)
        return
    end
    if force == "android" or backend == plugin.tts_engine.BACKENDS.ANDROID then
        local info = InfoMessage:new{
            text = _("Loading voices…"),
            timeout = 0,
        }
        UIManager:show(info)
        UIManager:scheduleIn(0.05, function()
            local items, current = MenuBuilder._androidVoicePickerItems(plugin)
            UIManager:close(info)
            MenuBuilder.showPagedPicker({
                title = _("Select voice"),
                items = items,
                current = current,
            })
        end)
        return
    end
    local items, current
    if backend == plugin.tts_engine.BACKENDS.PIPER then
        items, current = MenuBuilder._piperVoicePickerItems(plugin)
    else
        items, current = MenuBuilder._espeakVoicePickerItems(plugin)
    end
    MenuBuilder.showPagedPicker({
        title = _("Select voice"),
        items = items,
        current = current,
    })
end

local function _valuePicker(title, values, current, format_fn, apply_fn)
    local items = {}
    local current_idx = 1
    for i, v in ipairs(values) do
        table.insert(items, {
            text = format_fn(v),
            callback = function() apply_fn(v) end,
        })
        if current == v then current_idx = i end
    end
    MenuBuilder.showPagedPicker({
        title = title,
        items = items,
        current = current_idx,
    })
end

function MenuBuilder._showTtsEnginePicker(plugin)
    local engine = plugin.tts_engine
    if not engine then return end
    local items, current = {}, 1
    local function add(id, label)
        table.insert(items, {
            text = label,
            callback = function()
                engine:setBackend(id)
                plugin:setSetting("tts_backend", id)
                plugin:setSetting("espeak_only_mode", false)
                if engine.invalidateQueuedAudio then
                    pcall(function() engine:invalidateQueuedAudio() end)
                end
                MenuBuilder.showTtsSettingsPicker(plugin)
            end,
        })
        if engine.backend == id then current = #items end
    end
    if engine._android_tts
        or engine._android_tts_deferred
        or engine.backend == engine.BACKENDS.ANDROID then
        add(engine.BACKENDS.ANDROID, MenuBuilder.systemTtsAndroidChoiceLabel(plugin))
    end
    add(engine.BACKENDS.ELEVENLABS, _("ElevenLabs (cloud, high quality)"))
    if engine.espeak_lib_path or Utils.commandExists("espeak-ng") or Utils.commandExists("espeak") then
        add(engine.BACKENDS.ESPEAK, _("espeak-ng (formant, fast, robotic)"))
    end
    if engine.piper_cmd or Utils.commandExists("piper") then
        add(engine.BACKENDS.PIPER, _("Piper (neural, natural-sounding)"))
    end
    MenuBuilder.showPagedPicker({
        title = _("TTS engine"),
        items = items,
        current = current,
    })
end

--[[--
Show TTS settings from the playback overlay: engine, then only the
active engine's settings, then speech rate, pauses, and volume.
--]]
function MenuBuilder.showTtsSettingsPicker(plugin)
    if not plugin or not plugin.tts_engine then
        UIManager:show(InfoMessage:new{
            text = _("TTS engine is not available."),
            timeout = 3,
        })
        return
    end
    local backend = plugin.tts_engine.backend
    local items = {}

    local engine_labels = {
        espeak = _("espeak-ng"),
        piper = _("Piper (neural)"),
        pico = _("Pico TTS"),
        flite = _("Flite"),
        festival = _("Festival"),
        android = MenuBuilder.systemTtsMenuLabel(plugin),
        elevenlabs = _("ElevenLabs"),
        ["platform-native"] = _("Platform-native helper"),
    }
    table.insert(items, {
        text = T(_("TTS engine: %1"), engine_labels[backend] or backend),
        callback = function()
            MenuBuilder._showTtsEnginePicker(plugin)
        end,
    })

    local B = plugin.tts_engine.BACKENDS
    if backend == B.ELEVENLABS then
        local key = plugin:getSetting("elevenlabs_api_key", "")
        if key == "" then
            table.insert(items, {
                text = _("ElevenLabs API key (not set)"),
                callback = function()
                    MenuBuilder._showElevenLabsKeyDialog(plugin)
                end,
            })
        else
            table.insert(items, {
                text = T(_("ElevenLabs API key: %1"), ElevenLabs.maskKey(key)),
                callback = function()
                    MenuBuilder._showElevenLabsKeyDialog(plugin)
                end,
            })
        end
        local el_voice = plugin:getSetting("elevenlabs_voice_label", "")
        if el_voice == "" then
            el_voice = plugin:getSetting("elevenlabs_voice_id", "")
        end
        local el_voice_text
        if el_voice == "" then
            el_voice_text = _("Voice: default")
        else
            el_voice_text = T(_("Voice: %1"), el_voice)
        end
        table.insert(items, {
            text = el_voice_text,
            callback = function()
                MenuBuilder.showVoicePicker(plugin, { engine = "elevenlabs" })
            end,
        })
        table.insert(items, {
            text = MenuBuilder.elevenLabsRequestLanguageText(plugin),
            callback = function()
                MenuBuilder._showElevenLabsLangPicker(plugin, { after = "tts_settings" })
            end,
        })
        local m = plugin:getSetting("elevenlabs_model", "eleven_multilingual_v2")
        local model_text = (m == "eleven_flash_v2_5")
            and _("Model: Flash v2.5 (faster)")
            or _("Model: Multilingual v2 (quality)")
        table.insert(items, {
            text = model_text,
            callback = function()
                if m == "eleven_flash_v2_5" then
                    plugin:setSetting("elevenlabs_model", "eleven_multilingual_v2")
                else
                    plugin:setSetting("elevenlabs_model", "eleven_flash_v2_5")
                end
                MenuBuilder.showTtsSettingsPicker(plugin)
            end,
        })
    elseif backend == B.ANDROID then
        local sys_voice = plugin:getSetting("android_tts_voice_label", "")
        if sys_voice == "" then
            local lang = plugin:getSetting("android_tts_language", "auto")
            if lang == "auto" then
                sys_voice = _("Auto-detect")
            else
                sys_voice = lang
            end
        end
        table.insert(items, {
            text = T(_("Voice: %1"), sys_voice),
            callback = function()
                MenuBuilder.showVoicePicker(plugin, { engine = "android" })
            end,
        })
    end

    table.insert(items, {
        text = T(_("Speech rate: %1x"), plugin:getSetting("speech_rate", 1.0)),
        callback = function()
            _valuePicker(_("Speech rate"), {0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0},
                plugin:getSetting("speech_rate", 1.0),
                function(v) return string.format("%.2fx", v) end,
                function(v)
                    plugin:setSetting("speech_rate", v)
                    if plugin.tts_engine then plugin.tts_engine:setRate(v) end
                    if plugin.sync_controller and plugin.sync_controller.playback_bar
                        and plugin.sync_controller.playback_bar.updateSpeed then
                        pcall(function()
                            plugin.sync_controller.playback_bar:updateSpeed(v)
                        end)
                    end
                    UIManager:show(InfoMessage:new{
                        text = T(_("Speech rate: %1x"), v),
                        timeout = 1.5,
                    })
                end)
        end,
    })
    if backend == plugin.tts_engine.BACKENDS.PIPER then
        table.insert(items, {
            text = T(_("Sentence gap (. ? !): %1s"), plugin:getSetting("piper_sentence_gap", 0.3)),
            callback = function()
                _valuePicker(_("Sentence pause"), {0, 0.1, 0.2, 0.3, 0.5, 0.8, 1.0, 1.5, 2.0},
                    plugin:getSetting("piper_sentence_gap", 0.3),
                    function(v) return string.format("%.1fs", v) end,
                    function(v)
                        plugin:setSetting("piper_sentence_gap", v)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Sentence gap (. ? !): %1s"), v),
                            timeout = 1.5,
                        })
                    end)
            end,
        })
        table.insert(items, {
            text = T(_("Paragraph gap (newlines): %1s"), plugin:getSetting("piper_paragraph_gap", 1.0)),
            callback = function()
                _valuePicker(_("Paragraph pause"), {0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.5, 2.0, 3.0},
                    plugin:getSetting("piper_paragraph_gap", 1.0),
                    function(v) return string.format("%.1fs", v) end,
                    function(v)
                        plugin:setSetting("piper_paragraph_gap", v)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Paragraph gap (newlines): %1s"), v),
                            timeout = 1.5,
                        })
                    end)
            end,
        })
    else
        table.insert(items, {
            text = T(_("Sentence pause (. ? !): %1s"), plugin:getSetting("sentence_pause", 0.1)),
            callback = function()
                _valuePicker(_("Sentence pause"), {0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.8, 1.0},
                    plugin:getSetting("sentence_pause", 0.1),
                    function(v) return string.format("%.2fs", v) end,
                    function(v)
                        plugin:setSetting("sentence_pause", v)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Sentence pause (. ? !): %1s"), v),
                            timeout = 1.5,
                        })
                    end)
            end,
        })
        table.insert(items, {
            text = T(_("Paragraph pause (newlines): %1s"), plugin:getSetting("paragraph_pause", 0.8)),
            callback = function()
                _valuePicker(_("Paragraph pause"), {0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.5, 2.0, 3.0},
                    plugin:getSetting("paragraph_pause", 0.8),
                    function(v) return string.format("%.1fs", v) end,
                    function(v)
                        plugin:setSetting("paragraph_pause", v)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Paragraph pause (newlines): %1s"), v),
                            timeout = 1.5,
                        })
                    end)
            end,
        })
    end
    table.insert(items, {
        text = T(_("Volume: %1%%"), math.floor(plugin:getSetting("speech_volume", 1.0) * 100)),
        callback = function()
            _valuePicker(_("Volume"), {0.25, 0.5, 0.75, 1.0},
                plugin:getSetting("speech_volume", 1.0),
                function(v) return string.format("%d%%", math.floor(v * 100)) end,
                function(v)
                    plugin:setSetting("speech_volume", v)
                    if plugin.tts_engine then plugin.tts_engine:setVolume(v) end
                    if plugin.sync_controller and plugin.sync_controller.playback_bar
                        and plugin.sync_controller.playback_bar.updateVolume then
                        pcall(function()
                            plugin.sync_controller.playback_bar:updateVolume(math.floor(v * 100))
                        end)
                    end
                    UIManager:show(InfoMessage:new{
                        text = T(_("Volume: %1%%"), math.floor(v * 100)),
                        timeout = 1.5,
                    })
                end)
        end,
    })
    MenuBuilder.showPagedPicker({
        title = _("TTS settings"),
        items = items,
    })
end

return MenuBuilder
