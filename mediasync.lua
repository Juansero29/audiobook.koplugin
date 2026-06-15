--[[--
MediaSync Controller -- Synchronization loop for pre-recorded audio playback.
Maps audio time position to text positions for synchronized highlighting.
Mirrors SyncController patterns but without TTS synthesis or sentence prefetch.

@module koplugin.audiobook.mediasync
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = require("device").screen
local time = require("ui/time")
local _ = require("gettext")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local PLUGIN_PATH = _utils_dir

local MediaSync = {
    STATE = {
        STOPPED = "stopped",
        PLAYING = "playing",
        PAUSED = "paused",
        LOADING = "loading",
    },
}

function MediaSync:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.state = self.STATE.STOPPED
    o.timing_data = nil
    o.chapters = nil
    o.playback_bar = nil
    o.playlist_files = nil
    o.current_playlist_idx = nil
    o.is_shuffled = false
    o._original_playlist = nil
    o.loop_enabled = true

    -- Current playback position tracking
    o._current_sentence_idx = 0
    o._current_word_idx = 0
    o._total_sentences = 0
    o._sync_timer = nil
    o._position_timer = nil
    o._chain_generation = 0

    -- UI update throttling
    o._last_progress_pct = -1
    o._last_ui_update_time = nil

    -- Audiobookshelf tracking (set by main.lua when playing ABS items)
    o._abs_item_id = nil
    o._abs_duration = nil

    return o
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MediaSync:start(audio_path, timing_data, chapters, cover_path, playlist_files, original_path)
    if self.state == self.STATE.PLAYING or self.state == self.STATE.PAUSED then
        self:stop(true) -- keep chapter menu open during track transitions
    end

    if not audio_path or not timing_data or #timing_data == 0 then
        logger.err("MediaSync: start() called without valid audio or timing data")
        return false
    end

    self.state = self.STATE.LOADING
    self.timing_data = timing_data
    self.chapters = chapters or {}
    self.cover_path = cover_path
    -- EPUB Media Overlay entries carry SMIL fragment ids; their presence
    -- switches the UI into read-along mode (minimized player, page-follow).
    self.overlay_mode = (timing_data[1] and timing_data[1].fragment_id) and true or false

    -- Detect same-playlist BEFORE overwriting self.playlist_files,
    -- otherwise same_playlist is always true on first load and
    -- _original_playlist never gets saved.
    local same_playlist = playlist_files and self.playlist_files == playlist_files
    self.playlist_files = playlist_files

    -- Only reset shuffle state when starting a brand-new playlist.
    -- If playlist_files is the same table reference, we're transitioning
    -- between tracks within the same shuffled playlist.
    if not same_playlist then
        self.is_shuffled = false
        self._original_playlist = nil
    end
    self.current_playlist_idx = nil
    if playlist_files then
        if not same_playlist then
            -- Save original order so shuffle can be toggled
            self._original_playlist = {}
            for i, f in ipairs(playlist_files) do
                self._original_playlist[i] = {name = f.name, path = f.path}
            end
        end
        local lookup_path = original_path or audio_path
        for i, f in ipairs(playlist_files) do
            if f.path == lookup_path then
                self.current_playlist_idx = i
                break
            end
        end
    end
    self._current_sentence_idx = 1
    self._current_word_idx = 1
    self._chain_generation = self._chain_generation + 1
    self._last_progress_pct = -1
    self._last_ui_update_time = nil

    -- Build sentence index from timing data
    self:_buildSentenceIndex()

    -- Load and play audio
    if not self.media_engine:load(audio_path) then
        logger.err("MediaSync: failed to load audio", audio_path)
        self.state = self.STATE.STOPPED
        return false
    end

    -- If probing failed (e.g., no ffprobe for m4b), use the timing data
    -- end_time which was set from the known metadata duration.
    if not self.media_engine.current_duration or self.media_engine.current_duration == 0 then
        local known_dur = timing_data[1] and timing_data[1].end_time
        if known_dur and known_dur > 0 then
            self.media_engine.current_duration = known_dur
        end
    end

    -- Sync playlist menu highlight if it's open
    if self._chapter_menu and self.current_playlist_idx then
        pcall(function()
            if self._chapter_menu.item_table.current ~= self.current_playlist_idx then
                self._chapter_menu.item_table.current = self.current_playlist_idx
                self._chapter_menu:updateItems()
            end
        end)
    end

    -- Apply the persisted volume BEFORE play() so the initial decode spawn
    -- already carries the gain (setVolume is a no-op restart when not playing).
    if self.plugin and self.plugin.getSetting then
        pcall(function()
            self.media_engine:setVolume(self.plugin:getSetting("media_volume_pct", 100))
        end)
    end

    -- Show playback bar in scrubber mode
    self:showPlaybackBar()

    local gen = self._chain_generation
    local ok = self.media_engine:play(
        function() self:_onPlaybackComplete(gen) end,
        function(err) self:_onPlaybackFail(gen, err) end
    )

    if not ok then
        logger.err("MediaSync: media_engine:play() failed")
        self.state = self.STATE.STOPPED
        return false
    end

    self.state = self.STATE.PLAYING
    self:_startSyncLoop(gen)
    self:_startPositionPoller(gen)

    logger.warn("MediaSync: started playback, sentences=", self._total_sentences,
        "duration=", self.media_engine:getDuration())
    return true
end

function MediaSync:stop(keep_chapter_menu)
    local was_playing = self.state ~= self.STATE.STOPPED
    self.state = self.STATE.STOPPED
    self._chain_generation = self._chain_generation + 1

    if self._sync_timer then
        UIManager:unschedule(self._sync_timer)
        self._sync_timer = nil
    end
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    if self.media_engine then
        pcall(function() self.media_engine:stop() end)
    end
    if self.highlight_manager then
        pcall(function() self.highlight_manager:clearHighlights() end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:hide() end)
    end
    if not keep_chapter_menu then
        if self._chapter_menu_window then
            pcall(function() UIManager:close(self._chapter_menu_window) end)
            self._chapter_menu_window = nil
        end
        if self._chapter_menu then
            self._chapter_menu = nil
        end
    end

    if was_playing then
        logger.warn("MediaSync: stopped")
    end
end

function MediaSync:pause(auto)
    if self.state ~= self.STATE.PLAYING then return end
    self.state = self.STATE.PAUSED
    if self.media_engine then
        pcall(function() self.media_engine:pause() end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:setPlaying(false) end)
    end
    logger.dbg("MediaSync: paused", auto and "(auto)" or "")
end

function MediaSync:resume(auto)
    if self.state ~= self.STATE.PAUSED then return end
    self.state = self.STATE.PLAYING
    if self.media_engine then
        pcall(function() self.media_engine:resume() end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:setPlaying(true) end)
    end
    -- The sync loop self-terminates while paused: its tick bails out without
    -- rescheduling once state != PLAYING.  Restart it (and the position
    -- poller, for symmetry) so the highlight tracks the audio again instead of
    -- staying frozen at the pause point -- otherwise it looks badly desynced
    -- after every resume.  Reading getPosition() (ffmpeg out_time) re-snaps
    -- the highlight to where the audio actually is.
    self:_startSyncLoop(self._chain_generation)
    self:_startPositionPoller(self._chain_generation)
    logger.dbg("MediaSync: resumed", auto and "(auto)" or "")
end

function MediaSync:isPlaying()
    return self.state == self.STATE.PLAYING
end

function MediaSync:isPaused()
    return self.state == self.STATE.PAUSED
end

function MediaSync:setSpeed(speed)
    if self.media_engine then
        pcall(function() self.media_engine:setSpeed(speed) end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:updateSpeed(speed) end)
    end
end

function MediaSync:setVolume(pct)
    if self.media_engine then
        pcall(function() self.media_engine:setVolume(pct) end)
    end
    -- Persist so the level carries across tracks and sessions.
    if self.plugin and self.plugin.setSetting then
        self.plugin:setSetting("media_volume_pct", pct)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:updateVolume(pct) end)
    end
end

function MediaSync:getVolume()
    if self.plugin and self.plugin.getSetting then
        return self.plugin:getSetting("media_volume_pct", 100)
    end
    return self.media_engine and self.media_engine:getVolume() or 100
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

function MediaSync:seekToTime(seconds)
    if not self.media_engine then return end
    logger.warn("MediaSync: seekToTime", seconds)
    self.media_engine:seek(seconds, "absolute")
    -- Force immediate UI update so the bar doesn't wait for the next poller tick
    if self.playback_bar then
        local dur = self.media_engine:getDuration() or 0
        if dur > 0 then
            local pct = math.floor((seconds / dur) * 100)
            self._last_progress_pct = pct
            pcall(function()
                self.playback_bar:updateProgress(pct)
                self.playback_bar:updateTimeDisplay(seconds, dur)
            end)
        end
    end
    -- Full-screen refresh on e-ink to clear ghost trails when seeking
    -- backwards after the progress bar has filled.
    UIManager:setDirty("all", "ui")
end

function MediaSync:seekToChapter(index)
    if not self.chapters or not self.chapters[index] then return end
    local ch = self.chapters[index]
    logger.warn("MediaSync: seekToChapter", index, ch.title, "@", ch.start_time)
    self:seekToTime(ch.start_time)
end

function MediaSync:nextSentence()
    if not self.timing_data then return end
    local idx = self._current_sentence_idx + 1
    if idx > #self.timing_data then
        -- At end; seek to last sentence start or just seek forward 5s
        self.media_engine:seek(5, "relative")
        return
    end
    self:seekToTime(self.timing_data[idx].start_time)
end

function MediaSync:skipBack(seconds)
    seconds = seconds or 30
    if not self.media_engine then return end
    self.media_engine:seek(-seconds, "relative")
end

function MediaSync:skipForward(seconds)
    seconds = seconds or 30
    if not self.media_engine then return end
    self.media_engine:seek(seconds, "relative")
end

function MediaSync:prevSentence()
    if not self.timing_data then return end
    local idx = self._current_sentence_idx - 1
    if idx < 1 then idx = 1 end
    self:seekToTime(self.timing_data[idx].start_time)
end

function MediaSync:nextChapter()
    if self.playlist_files and #self.playlist_files > 0 then
        local idx = (self.current_playlist_idx or 1) + 1
        if idx <= #self.playlist_files then
            self:switchToPlaylistFile(idx)
        end
        return
    end
    if not self.chapters or #self.chapters == 0 then return end
    local current_time = self.media_engine:getPosition()
    for i, ch in ipairs(self.chapters) do
        if ch.start_time > current_time + 1 then
            self:seekToChapter(i)
            return
        end
    end
end

function MediaSync:prevChapter()
    if self.playlist_files and #self.playlist_files > 0 then
        local idx = (self.current_playlist_idx or 1) - 1
        if idx >= 1 then
            self:switchToPlaylistFile(idx)
        end
        return
    end
    if not self.chapters or #self.chapters == 0 then return end
    local current_time = self.media_engine:getPosition()
    for i = #self.chapters, 1, -1 do
        if self.chapters[i].start_time < current_time - 1 then
            self:seekToChapter(i)
            return
        end
    end
end

function MediaSync:switchToPlaylistFile(index)
    if not self.playlist_files or not self.playlist_files[index] then return end
    self.current_playlist_idx = index
    local file_path = self.playlist_files[index].path
    if self.plugin and self.plugin._playAudioFile then
        self.plugin:_playAudioFile(file_path, self.playlist_files)
    end
end

function MediaSync:toggleLoop()
    self.loop_enabled = not self.loop_enabled
    if self.playback_bar then
        pcall(function()
            self.playback_bar:setLoopActive(self.loop_enabled)
        end)
    end
    UIManager:show(InfoMessage:new{
        text = self.loop_enabled and _("Loop enabled.") or _("Loop disabled."),
        timeout = 1,
    })
end

function MediaSync:shufflePlaylist()
    if not self.playlist_files or #self.playlist_files <= 1 then return end

    local was_shuffled = self.is_shuffled
    if was_shuffled and self._original_playlist then
        -- Restore original alphabetical order
        self.playlist_files = {}
        for i, f in ipairs(self._original_playlist) do
            self.playlist_files[i] = {name = f.name, path = f.path}
        end
        self.is_shuffled = false
        -- Re-find current track position in restored order
        local current_path = self.media_engine and self.media_engine.current_path
        for i, f in ipairs(self.playlist_files) do
            if f.path == current_path then
                self.current_playlist_idx = i
                break
            end
        end
    else
        -- Shuffle
        math.randomseed(os.time())
        local current_path = self.playlist_files[self.current_playlist_idx or 1].path
        for i = #self.playlist_files, 2, -1 do
            local j = math.random(i)
            self.playlist_files[i], self.playlist_files[j] = self.playlist_files[j], self.playlist_files[i]
        end
        for i, f in ipairs(self.playlist_files) do
            if f.path == current_path then
                self.current_playlist_idx = i
                break
            end
        end
        self.is_shuffled = true
    end

    -- Update shuffle button visual state FIRST (before InfoMessage flash)
    if self.playback_bar then
        local ok, err = pcall(function()
            self.playback_bar:setShuffleActive(self.is_shuffled)
        end)
        if not ok then
            logger.warn("MediaSync: setShuffleActive failed:", err)
        end
    end

    UIManager:show(InfoMessage:new{
        text = self.is_shuffled and _("Playlist shuffled.") or _("Shuffle disabled."),
        timeout = 1,
    })
end

-- ---------------------------------------------------------------------------
-- Internal: sentence index
-- ---------------------------------------------------------------------------

function MediaSync:_buildSentenceIndex()
    -- timing_data is already sentence-level from parser/aligner.
    -- Each entry: {start_time, end_time, text, xpointer, words?}
    self._total_sentences = #self.timing_data
    -- Sort by start_time just in case
    table.sort(self.timing_data, function(a, b)
        return a.start_time < b.start_time
    end)
end

-- ---------------------------------------------------------------------------
-- Internal: sync loop (20Hz)
-- ---------------------------------------------------------------------------

function MediaSync:_startSyncLoop(gen)
    -- Idempotent: drop any existing timer so resume() can safely restart us
    -- without leaving two ticks running.
    if self._sync_timer then
        UIManager:unschedule(self._sync_timer)
        self._sync_timer = nil
    end
    local function tick()
        if self._chain_generation ~= gen or self.state ~= self.STATE.PLAYING then
            return
        end

        local ok, pos = pcall(function() return self.media_engine:getPosition() end)
        if not ok then
            logger.err("MediaSync: getPosition() error in sync loop:", pos)
            self._sync_timer = UIManager:scheduleIn(0.05, tick)
            return
        end

        -- Compensate for audio in flight (pads + mixer ring + BT chain):
        -- the listener hears position pos - latency.
        local lat = (self.media_engine and self.media_engine.position_latency_s) or 0
        local off = 0
        if self.plugin and self.plugin.getSetting then
            off = (self.plugin:getSetting("smil_sync_offset_ms", 0) or 0) / 1000
        end
        self:_updateHighlightAtTime(math.max(0, pos - lat - off))

        -- Check for sentence/chapter boundary advancement
        self:_checkAutoAdvance(pos)

        self._sync_timer = UIManager:scheduleIn(0.05, tick)
    end

    self._sync_timer = UIManager:scheduleIn(0.05, tick)
end

function MediaSync:_updateHighlightAtTime(pos)
    if not self.timing_data then return end

    -- Find current sentence by binary search on start_time
    local sent_idx = self:_findSentenceAtTime(pos)
    if not sent_idx then return end

    local sentence = self.timing_data[sent_idx]
    if not sentence then return end

    -- Update sentence highlight if changed
    if sent_idx ~= self._current_sentence_idx then
        self._current_sentence_idx = sent_idx
        self._current_word_idx = 1
        -- EPUB Media Overlay: keep the book view following the narration.
        -- The SMIL fragment id resolves as a "#id" xpointer in crengine;
        -- turn the page before highlighting so the text-matching
        -- highlighter can find the sentence on the visible page.
        if sentence.fragment_id then
            local ui = self.plugin and self.plugin.ui
            if ui and ui.rolling and ui.document then
                pcall(function()
                    local xp = "#" .. sentence.fragment_id
                    local target = ui.document:getPageFromXPointer(xp)
                    local cur = ui.document:getCurrentPage()
                    logger.dbg("MediaSync: page-follow", xp, "->", target, "cur", cur)
                    -- target == 1 is almost always a failed "#id" lookup
                    -- (crengine falls back to the start of the book, i.e.
                    -- the cover) -- never auto-turn there.
                    if target and target > 1 and target ~= cur then
                        ui.rolling:onGotoXPointer(xp)
                    end
                end)
            end
        end
        if self.highlight_manager and sentence.text then
            -- Build a synthetic sentence object for HighlightManager
            local sent_obj = {
                text = sentence.text,
                start_pos = sentence.start_pos or 0,
                end_pos = sentence.end_pos or #sentence.text,
            }
            local hl_ok = false
            pcall(function()
                hl_ok = self.highlight_manager:highlightSentence(sent_obj, {sentences = {sent_obj}})
            end)
            -- Read-along page advancement: narration flows forward, so when
            -- the next sequential sentence is not on the visible page it is
            -- on the following one -- turn and retry once.  Only for
            -- sequential advancement (not seeks), so a failed text match
            -- can never page away from where the user is reading.
            if not hl_ok and self.overlay_mode
                and sent_idx == (self._last_hl_idx or 0) + 1 then
                local ui = self.plugin and self.plugin.ui
                if ui then
                    pcall(function()
                        ui:handleEvent(Event:new("GotoViewRel", 1))
                        self.highlight_manager:highlightSentence(sent_obj, {sentences = {sent_obj}})
                    end)
                end
            end
            self._last_hl_idx = sent_idx
        end
    end

    -- Find current word within sentence (if word-level timing available)
    if sentence.words and #sentence.words > 0 then
        local word_idx = self:_findWordAtTime(sentence.words, pos)
        if word_idx and word_idx ~= self._current_word_idx then
            self._current_word_idx = word_idx
            local word = sentence.words[word_idx]
            if self.highlight_manager and word then
                pcall(function()
                    self.highlight_manager:highlightWord(word, {sentences = {sentence}})
                end)
            end
            -- Update playback bar word display (only in non-scrubber mode)
            if self.playback_bar and not self.playback_bar.scrubber_mode then
                pcall(function()
                    self.playback_bar:updateCurrentWord(word.text or "")
                end)
            end
        end
    end
end

function MediaSync:_findSentenceAtTime(pos)
    local data = self.timing_data
    local lo, hi = 1, #data
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local entry = data[mid]
        if pos >= entry.start_time and pos < entry.end_time then
            return mid
        elseif pos < entry.start_time then
            hi = mid - 1
        else
            lo = mid + 1
        end
    end
    -- If past the end, return last sentence
    if pos >= data[#data].end_time then
        return #data
    end
    -- If before the beginning, return first
    if pos < data[1].start_time then
        return 1
    end
    return nil
end

function MediaSync:_findWordAtTime(words, pos)
    for i, word in ipairs(words) do
        if pos >= word.start_time and pos < word.end_time then
            return i
        end
    end
    -- Fallback: find closest word
    local closest = 1
    local min_dist = math.huge
    for i, word in ipairs(words) do
        local dist = math.min(
            math.abs(pos - word.start_time),
            math.abs(pos - word.end_time)
        )
        if dist < min_dist then
            min_dist = dist
            closest = i
        end
    end
    return closest
end

function MediaSync:_checkAutoAdvance(pos)
    if not self.timing_data then return end
    local last_sent = self.timing_data[#self.timing_data]
    if not last_sent then return end

    -- Skip auto-advance during a seek: the media engine is temporarily
    -- stopped while it restarts the pipeline at the new offset.
    if self.media_engine and self.media_engine._seek_offset then
        return
    end

    -- If we're past the last sentence end, check if we should auto-advance
    -- (For standalone audio: just stop. For EPUB Media Overlays: advance page.)
    if pos >= last_sent.end_time then
        -- Small grace period to avoid premature stop
        if pos >= last_sent.end_time + 1 then
            -- Check if audio is still playing (might be silence at end)
            if not self.media_engine:isPlaying() then
                self:_onPlaybackComplete(self._chain_generation)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Internal: position poller (UI updates at 1Hz)
-- ---------------------------------------------------------------------------

function MediaSync:_startPositionPoller(gen)
    -- Idempotent: the poller keeps running while paused, so guard against a
    -- second concurrent loop when resume() restarts it.
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end
    local function poll()
        if self._chain_generation ~= gen then return end
        if self.state ~= self.STATE.PLAYING and self.state ~= self.STATE.PAUSED then
            return
        end

        local ok_pos, pos = pcall(function() return self.media_engine:getPosition() end)
        if not ok_pos then
            logger.err("MediaSync: getPosition() error in poller:", pos)
            self._position_timer = UIManager:scheduleIn(1.0, poll)
            return
        end

        local ok_dur, dur = pcall(function() return self.media_engine:getDuration() end)
        if not ok_dur then
            logger.err("MediaSync: getDuration() error in poller:", dur)
            self._position_timer = UIManager:scheduleIn(1.0, poll)
            return
        end

        -- Update progress bar
        if dur and dur > 0 and pos then
            local pct = math.floor((pos / dur) * 100)
            if pct ~= self._last_progress_pct then
                self._last_progress_pct = pct
                if self.playback_bar then
                    pcall(function()
                        self.playback_bar:updateProgress(pct)
                    end)
                end
            end
        end

        -- Update time display
        if self.playback_bar then
            pcall(function()
                self.playback_bar:updateTimeDisplay(pos or 0, dur or 0)
            end)
            -- Update chapter title and current chapter info
            local ok_ch, ch, ch_idx = pcall(function() return self:getCurrentChapter() end)
            if ok_ch and ch then
                pcall(function()
                    self.playback_bar:updateChapterTitle(ch.title or "")
                    self.playback_bar:setCurrentChapter(ch)
                end)
                -- Update chapter menu highlight if it's open (chapter mode only;
                -- playlist mode uses playlist index, not chapter index)
                if self._chapter_menu and ch_idx and not self.playlist_files then
                    local menu = self._chapter_menu
                    if menu.item_table.current ~= ch_idx then
                        menu.item_table.current = ch_idx
                        pcall(function()
                            menu:updateItems()
                        end)
                    end
                end
            end
        end

        self._position_timer = UIManager:scheduleIn(1.0, poll)
    end

    self._position_timer = UIManager:scheduleIn(1.0, poll)
end

-- ---------------------------------------------------------------------------
-- Completion / failure callbacks
-- ---------------------------------------------------------------------------

function MediaSync:_onPlaybackComplete(gen)
    if self._chain_generation ~= gen then return end
    logger.warn("MediaSync: playback complete")
    -- In playlist mode, auto-advance to the next track
    if self.playlist_files and #self.playlist_files > 0 then
        local next_idx = (self.current_playlist_idx or 1) + 1
        if next_idx <= #self.playlist_files then
            logger.warn("MediaSync: auto-advancing to playlist track", next_idx)
            self:switchToPlaylistFile(next_idx)
            return
        elseif self.loop_enabled then
            -- Loop: wrap back to start (or random if shuffled)
            if self.is_shuffled then
                math.randomseed(os.time())
                next_idx = math.random(#self.playlist_files)
            else
                next_idx = 1
            end
            logger.warn("MediaSync: looping to playlist track", next_idx)
            self:switchToPlaylistFile(next_idx)
            return
        end
    end
    self:stop()
end

function MediaSync:_onPlaybackFail(gen, err)
    if self._chain_generation ~= gen then return end
    logger.err("MediaSync: playback failed:", err)
    self:stop()
    UIManager:show(InfoMessage:new{
        text = _("Audio playback failed: ") .. tostring(err),
        timeout = 3,
    })
end

-- ---------------------------------------------------------------------------
-- Playback bar
-- ---------------------------------------------------------------------------

function MediaSync:showPlaybackBar()
    if self.playback_bar and self.playback_bar:isVisible() then
        return
    end
    -- For standalone audio (scrubber mode), use full-screen AudiobookPlayer overlay
    local AudiobookPlayer = dofile(PLUGIN_PATH .. "audiobookplayer.lua")
    local title = self.timing_data and self.timing_data[1] and self.timing_data[1].text or _("Audiobook")
    -- Derive output name: use original playlist filename when available
    local output_name = ""
    if self.playlist_files and self.current_playlist_idx then
        output_name = self.playlist_files[self.current_playlist_idx].name
    elseif self.media_engine and self.media_engine.current_path then
        output_name = self.media_engine.current_path:match("([^/]+)$") or ""
    end

    local player = AudiobookPlayer:new{
        title = title,
        output_name = output_name,
        cover_image_path = self.cover_path,
        -- Read-along (EPUB overlay) mode: start minimized so the book page
        -- stays visible; highlighting and page-follow are the primary UI.
        start_minimized = self.overlay_mode or nil,
        on_sync_nudge = self.overlay_mode and function(delta_ms)
            local p = self.plugin
            if not (p and p.getSetting) then return nil end
            local v = (p:getSetting("smil_sync_offset_ms", 0) or 0) + delta_ms
            p:setSetting("smil_sync_offset_ms", v)
            return v
        end or nil,
        show_shuffle = self.playlist_files and #self.playlist_files > 0,
        shuffle_active = self.is_shuffled,
        show_loop = self.playlist_files and #self.playlist_files > 0,
        loop_active = self.loop_enabled,
        volume_pct = self:getVolume(),
        on_volume = function(pct) self:setVolume(pct) end,
        ui_widget = self.plugin and self.plugin.ui,
        on_play_pause = function()
            if self.state == self.STATE.PLAYING then
                self:pause()
            elseif self.state == self.STATE.PAUSED then
                self:resume()
            end
        end,
        on_skip_back = function()
            self:skipBack(30)
        end,
        on_skip_forward = function()
            self:skipForward(30)
        end,
        on_prev_chapter = function()
            self:prevChapter()
        end,
        on_next_chapter = function()
            self:nextChapter()
        end,
        on_seek = function(pct)
            local dur = self.media_engine and self.media_engine:getDuration() or 0
            if dur > 0 then
                self:seekToTime(pct * dur)
            end
        end,
        on_minimize = function()
            -- Minimize is handled internally by AudiobookPlayer
            -- (shows mini bar; tap mini bar to restore)
        end,
        on_close = function()
            self:stop()
        end,
        on_chapter_list = function()
            self:showChapterList()
        end,
        on_speed = function()
            -- Cycle speeds: 0.8 → 1.0 → 1.25 → 1.5 → 2.0 → 0.8
            local speeds = {0.8, 1.0, 1.25, 1.5, 2.0}
            local current = self.media_engine and self.media_engine:getSpeed() or 1.0
            local next_speed = speeds[1]
            for i, s in ipairs(speeds) do
                if math.abs(current - s) < 0.01 then
                    next_speed = speeds[i + 1] or speeds[1]
                    break
                end
            end
            self:setSpeed(next_speed)
        end,
        on_shuffle = function()
            self:shufflePlaylist()
        end,
        on_loop = function()
            self:toggleLoop()
        end,
    }
    player:show()
    self.playback_bar = player
end

function MediaSync:hidePlaybackBar()
    if self.playback_bar then
        pcall(function() self.playback_bar:hide() end)
        self.playback_bar = nil
    end
end

--- Close the modal chapter/playlist menu and clear its references.
function MediaSync:_closeModalMenu()
    local window = self._chapter_menu_window
    self._chapter_menu = nil
    self._chapter_menu_window = nil
    if window then
        pcall(function() UIManager:close(window) end)
    end
end

--[[--
Show a modal list menu centered over the reader, with a full-screen wrapper
that closes the menu when the user taps/swipes outside it (and swallows
hold/pan outside so they don't fall through to the page underneath).  Shared
by showChapterList() and showPlaylist().

@param opts table  { title = string, items = item_table, current = number }
  Each item's `callback` decides whether to close the menu (call
  self:_closeModalMenu()) -- chapters close on select, the playlist stays open.
--]]
function MediaSync:_showModalMenu(opts)
    local Menu = require("ui/widget/menu")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")

    local menu_w = Screen:getWidth() * 0.8
    local menu_h = Screen:getHeight() * 0.7

    local items = opts.items
    items.current = opts.current or 1

    local menu = Menu:new{
        title = opts.title,
        item_table = items,
        width = menu_w,
        height = menu_h,
    }
    self._chapter_menu = menu

    local window = InputContainer:new{
        dimen = Screen:getSize(),
        CenterContainer:new{
            dimen = Screen:getSize(),
            menu,
        },
    }
    self._chapter_menu_window = window

    local menu_rect = Geom:new{
        x = math.floor((Screen:getWidth() - menu_w) / 2),
        y = math.floor((Screen:getHeight() - menu_h) / 2),
        w = menu_w,
        h = menu_h,
    }

    local ms = self
    local function outside(ges_ev)
        return ges_ev and ges_ev.pos and ges_ev.pos:notIntersectWith(menu_rect)
    end
    function window:onTap(arg, ges_ev)
        if outside(ges_ev) then ms:_closeModalMenu(); return true end
        return false
    end
    function window:onSwipe(arg, ges_ev)
        if outside(ges_ev) then ms:_closeModalMenu(); return true end
        return false
    end
    function window:onHold(arg, ges_ev)
        return outside(ges_ev) and true or false
    end
    function window:onPan(arg, ges_ev)
        return outside(ges_ev) and true or false
    end

    menu.close_callback = function() ms:_closeModalMenu() end

    UIManager:show(window)
    return menu
end

function MediaSync:showChapterList()
    if self.playlist_files and #self.playlist_files > 0 then
        self:showPlaylist()
        return
    end
    if not self.chapters or #self.chapters == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No chapters available."),
            timeout = 2,
        })
        return
    end

    local _, current_idx = self:getCurrentChapter()
    local items = {}
    for i, ch in ipairs(self.chapters) do
        table.insert(items, {
            text = (ch.title or _("Chapter") .. " " .. i)
                .. "  (" .. self:_formatTime(ch.start_time) .. ")",
            callback = function()
                self:_closeModalMenu()
                self:seekToChapter(i)
            end,
        })
    end
    self:_showModalMenu{ title = _("Chapters"), items = items, current = current_idx }
end

function MediaSync:showPlaylist()
    if not self.playlist_files or #self.playlist_files == 0 then
        return
    end

    local items = {}
    for i, f in ipairs(self.playlist_files) do
        table.insert(items, {
            text = f.name,
            callback = function()
                -- Keep the playlist open when switching tracks.
                self:switchToPlaylistFile(i)
            end,
        })
    end
    self:_showModalMenu{
        title = _("Playlist"),
        items = items,
        current = self.current_playlist_idx or 1,
    }
end

-- ---------------------------------------------------------------------------
-- Progress / time queries
-- ---------------------------------------------------------------------------

function MediaSync:getProgress()
    local dur = self.media_engine and self.media_engine:getDuration() or 0
    if dur <= 0 then return 0 end
    local pos = self.media_engine:getPosition()
    return math.floor((pos / dur) * 100)
end

function MediaSync:getCurrentTime()
    local pos = self.media_engine and self.media_engine:getPosition() or 0
    return self:_formatTime(pos)
end

function MediaSync:getTotalTime()
    local dur = self.media_engine and self.media_engine:getDuration() or 0
    return self:_formatTime(dur)
end

function MediaSync:_formatTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    if mins >= 60 then
        local hours = math.floor(mins / 60)
        mins = mins % 60
        return string.format("%d:%02d:%02d", hours, mins, secs)
    end
    return string.format("%d:%02d", mins, secs)
end

-- ---------------------------------------------------------------------------
-- Chapter queries
-- ---------------------------------------------------------------------------

function MediaSync:getCurrentChapter()
    if not self.chapters or #self.chapters == 0 then return nil end
    local pos = self.media_engine:getPosition()
    for i = #self.chapters, 1, -1 do
        local st = self.chapters[i].start_time or self.chapters[i].start or 0
        if pos >= st then
            return self.chapters[i], i
        end
    end
    return self.chapters[1], 1
end

return MediaSync
