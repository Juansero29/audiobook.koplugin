--[[--
Highlight Manager Module
Uses KOReader's native text selection to highlight the current sentence
being read by TTS. Works with both EPUB (CreDocument) and PDF.

For EPUB: Uses getTextFromPositions() with draw_selection enabled, which
lets crengine draw the selection highlight natively.

@module highlightmanager
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("audiobook_gettext")

-- Shared utility modules (DRY: ws helper)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")

local Screen = Device.screen

--[[--
Union of highlight box arrays, clamped to screen bounds.
Returns a Geom refresh region or nil when there is nothing to refresh.
--]]
local function boxesUnionRegion(arrays)
    local min_x, min_y, max_x, max_y
    for _, arr in ipairs(arrays) do
        if arr then
            for _, b in ipairs(arr) do
                local x2, y2 = b.x + b.w, b.y + b.h
                if not min_x or b.x < min_x then min_x = b.x end
                if not min_y or b.y < min_y then min_y = b.y end
                if not max_x or x2 > max_x then max_x = x2 end
                if not max_y or y2 > max_y then max_y = y2 end
            end
        end
    end
    if not min_x then return nil end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    min_x = math.max(0, min_x)
    min_y = math.max(0, min_y)
    max_x = math.min(sw, max_x)
    max_y = math.min(sh, max_y)
    if max_x <= min_x or max_y <= min_y then return nil end
    return Geom:new{x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y}
end

local HighlightManager = {
    STYLES = {
        UNDERLINE = "underline",
        BACKGROUND = "background",
        BOX = "box",
        INVERT = "invert",
    },
}

function HighlightManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.current_style = o.style or self.STYLES.BACKGROUND
    o.is_highlighting = false
    o.current_word = nil
    -- For native crengine highlighting
    o._selection_active = false
    -- Pending boxes for non-invert styles, drawn by the view module
    o._pending_boxes = nil
    o._view_module_registered = false
    -- Boxes of the highlight currently on screen (and their page), used to
    -- limit the next e-ink refresh to the changed strip.
    o._last_boxes = nil
    o._last_boxes_page = nil

    return o
end

--[[--
Refresh the screen region covering the previous and new highlight boxes.
Pages containing images are refreshed dithered by KOReader (slow waveform),
so a full-page refresh there flashes visibly once per sentence; limiting
the update to the changed strip keeps those updates cheap and flash-free.
When no boxes are known, fall back to the caller's previous full refresh.
@param new_boxes table|nil Boxes of the newly drawn highlight
@param page number|nil Current page, used to drop stale boxes from the union
--]]
function HighlightManager:_refreshHighlight(new_boxes, page)
    local arrays = {}
    if self._last_boxes and self._last_boxes_page == page then
        table.insert(arrays, self._last_boxes)
    end
    if new_boxes and #new_boxes > 0 then
        table.insert(arrays, new_boxes)
    end
    UIManager:setDirty(self.ui.dialog or "all", "ui",
        boxesUnionRegion(arrays))
    self._last_boxes = new_boxes
    self._last_boxes_page = page
end

function HighlightManager:setStyle(style)
    self.current_style = style
    if self.plugin then
        self.plugin:setSetting("highlight_style", style)
    end
end

function HighlightManager:getStyle()
    return self.current_style
end

--[[--
Highlight a sentence in the document using KOReader's native selection.

For EPUB (rolling/CreDocument): We call getTextFromPositions() which
internally tells crengine to draw a selection highlight over the text
range. This produces the standard blue/gray selection you see when
long-pressing text.

@param sentence table Sentence object with .text, .start_pos, .end_pos
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightSentence(sentence, parsed_data)
    if not sentence then return end
    if not self.ui or not self.ui.document then return end

    -- Always drop the previous highlight before searching for the new one;
    -- otherwise a sentence that is not visible on the current page would
    -- leave stale boxes that get mirrored at the wrong x,y.
    self._pending_boxes = nil
    self.is_highlighting = false

    local doc = self.ui.document

    -- EPUB / rolling mode: use screen-coordinate selection.
    -- Returns true when the sentence was found and highlighted on the
    -- visible page (callers use this for read-along page advancement).
    if self.ui.rolling then
        -- Storyteller / EPUB3 Media Overlays: prefer the SMIL fragment id
        -- (Readest-style) over fuzzy on-screen text matching.
        if sentence.fragment_id then
            local ok = self:_highlightByFragmentId(doc, sentence.fragment_id)
            if ok then return true end
        end
        return self:_highlightSentenceRolling(sentence, parsed_data, doc)
    else
        -- PDF / paged mode: use view.highlight.temp
        return self:_highlightSentencePaging(sentence, parsed_data, doc)
    end
end

--- Highlight a SMIL sentence via its DOM id (e.g. "html39-s12").
-- Works only when that content document is already the current CRe document.
function HighlightManager:_highlightByFragmentId(doc, fragment_id)
    if not doc or not fragment_id then return false end
    local xp0
    local ok_xp, norm = pcall(function()
        return doc:getNormalizedXPointer("#" .. fragment_id)
    end)
    if not (ok_xp and norm and norm ~= false) then
        return false
    end
    xp0 = norm
    local xp1 = xp0

    -- Expand to the full sentence/element when CRe supports it.
    pcall(function()
        local a, b = doc:extendXPointersToSentenceSegment(xp0, xp0)
        if a and b then
            xp0, xp1 = a, b
        end
    end)

    local drawn
    pcall(function()
        drawn = doc:getTextFromXPointers(xp0, xp1, true)
    end)
    if not drawn or drawn == "" then
        -- Fallback: DOM text + on-screen text match (still better than SMIL
        -- text that may diverge from CRe's rendered form).
        local node_text
        pcall(function() node_text = doc:getTextFromXPointer(xp0) end)
        pcall(function() doc:clearSelection() end)
        if node_text and node_text ~= "" then
            return self:_highlightSentenceRolling({ text = node_text }, nil, doc)
        end
        return false
    end

    self._selection_active = true
    self.is_highlighting = true
    self._pending_boxes = nil
    local boxes
    pcall(function()
        boxes = doc:getScreenBoxesFromPositions(xp0, xp1, true)
    end)
    if boxes and #boxes > 0 and self.current_style ~= self.STYLES.INVERT then
        self._pending_boxes = boxes
        self:_ensureViewModule()
        pcall(function() doc:clearSelection() end)
        self._selection_active = false
    end
    self:_refreshHighlight(boxes, doc:getCurrentPage())
    return true
end

--[[--
EPUB: Find the sentence on screen and have crengine draw the selection.

Strategy: getTextFromPositions() with two screen-coordinate points returns
the text and xpointer range. We need to find the screen position of the
sentence's first and last word. We do this by searching through the
visible text positions.

CRe snaps selections to word boundaries, and proportional fonts make
character-based x estimates unreliable.  We use a two-phase approach:
  1. Proportional char estimate as initial guess
  2. Binary-search refinement: query CRe, compare against expected text,
     adjust x inward (for overshoot) or outward (for undershoot)
This typically converges in 2-4 CRe calls — fast enough for e-ink.
--]]
function HighlightManager:_highlightSentenceRolling(sentence, parsed_data, doc, _retried)
    -- Clear any existing selection
    pcall(function() doc:clearSelection() end)

    -- Normalize sentence text for matching: collapse whitespace, normalize
    -- common Unicode punctuation that getTextFromPositions() may return
    -- differently, and undo apostrophe-run escaping in SMIL text.
    local sent_text = Utils.normalizeForMatching(sentence.text)
    if sent_text == "" then return end

    -- ── Cached line map ──────────────────────────────────────────
    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
    -- Include the current page in the cache key so a page turn invalidates
    -- the cached text/geometry; otherwise highlights can be drawn at stale
    -- x,y coordinates after the view changes.
    local cur_page = self.ui.document:getCurrentPage() or 0
    local cache = self._line_cache
    local built_text, cum, sboxes, n

    if cache and cache.screen_w == cur_w and cache.screen_h == cur_h and cache.page == cur_page then
        built_text = cache.built_text
        cum        = cache.cum
        sboxes     = cache.sboxes
        n          = cache.n
    else
        -- Build fresh line map (expensive path — N document calls)
        local full_res = doc:getTextFromPositions(
            {x = 0, y = 0},
            {x = cur_w, y = cur_h},
            true
        )
        if not full_res or not full_res.pos0 or not full_res.pos1 then
            return
        end

        sboxes = doc:getScreenBoxesFromPositions(full_res.pos0, full_res.pos1, true)
        if not sboxes or #sboxes == 0 then return end
        n = #sboxes

        built_text = ""
        cum = {[0] = 0}
        for i = 1, n do
            local box = sboxes[i]
            local r = doc:getTextFromPositions(
                {x = box.x, y = box.y + math.floor(box.h / 2)},
                {x = box.x + box.w - 1, y = box.y + math.floor(box.h / 2)},
                true)
            local lt = (r and r.text) and Utils.normalizeForMatching(r.text) or ""
            if i > 1 and lt ~= "" then
                built_text = built_text .. " "
            end
            built_text = built_text .. lt
            cum[i] = #built_text
        end

        self._line_cache = {
            screen_w   = cur_w,
            screen_h   = cur_h,
            page       = cur_page,
            built_text = built_text,
            cum        = cum,
            sboxes     = sboxes,
            n          = n,
        }
    end

    -- Find the sentence in our built text.
    -- Try exact match first, then progressively shorter prefixes (the
    -- sentence may wrap across a page boundary so only the tail is
    -- visible), then try matching from the sentence end (only the
    -- beginning is visible on the current page).
    local vis_start = built_text:find(sent_text, 1, true)
    local matched_len = vis_start and #sent_text
    if not vis_start then
        -- Try shorter prefixes: 40, 20, 10 chars
        for _, plen in ipairs({40, 20, 10}) do
            if plen < #sent_text then
                local prefix = sent_text:sub(1, plen)
                vis_start = built_text:find(prefix, 1, true)
                if vis_start then
                    matched_len = #sent_text
                    break
                end
            end
        end
    end
    if not vis_start then
        -- Sentence may start on the previous page.  Try matching the
        -- tail end of the sentence that is visible on this page.
        for _, slen in ipairs({40, 20, 10}) do
            if slen < #sent_text then
                local suffix = sent_text:sub(-slen)
                local pos = built_text:find(suffix, 1, true)
                if pos then
                    -- The visible portion starts at pos, but the sentence
                    -- logically started earlier.  Highlight from built_text
                    -- start of that line.
                    vis_start = pos
                    matched_len = slen
                    break
                end
            end
        end
    end
    if not vis_start then
        -- Last resort: word-by-word matching with tolerance.
        -- On some e-ink readers (especially PW5 at 300dpi), the text
        -- from getTextFromPositions() may differ from parsed sentence
        -- text due to hyphenation, font ligatures, or spacing peculiarities.
        -- Try to find the sentence by matching its first few words.
        local words = {}
        for w in sent_text:gmatch("%S+") do
            table.insert(words, w)
        end
        if #words >= 3 then
            -- Try matching first 3, then 2 words
            for _, nwords in ipairs({3, 2}) do
                local prefix = table.concat(words, " ", 1, nwords)
                local pp = built_text:find(prefix, 1, true)
                if pp then
                    vis_start = pp
                    matched_len = #sent_text
                    logger.dbg("HighlightManager: found by word prefix (", nwords, "words)")
                    break
                end
            end
        end
        if not vis_start and #words >= 3 then
            -- Try matching last 3, then 2 words
            for _, nwords in ipairs({3, 2}) do
                local suffix = table.concat(words, " ", #words - nwords + 1, #words)
                local pp = built_text:find(suffix, 1, true)
                if pp then
                    vis_start = pp
                    matched_len = nwords > 0 and #built_text - pp + 1 or #sent_text
                    -- But we need to bound it. Since we only matched the tail,
                    -- set vis_start to beginning of that line.
                    if vis_start then
                        local found_line = 1
                        for i = 1, n do
                            if cum[i] >= vis_start then
                                found_line = i
                                break
                            end
                        end
                        -- Highlight from start of found line
                        vis_start = cum[found_line - 1] + 1
                        matched_len = cum[found_line] - cum[found_line - 1]
                        logger.dbg("HighlightManager: found by word suffix (", nwords, "words), line", found_line)
                    end
                    break
                end
            end
        end
    end
    if not vis_start then
        if not _retried and self._line_cache then
            self._line_cache = nil
            return self:_highlightSentenceRolling(sentence, parsed_data, doc, true)
        end
        logger.dbg("HighlightManager: sentence not found:", sent_text:sub(1, 80))
        return
    end
    local vis_end = vis_start + matched_len - 1

    -- Find start and end lines
    local start_line = 1
    for i = 1, n do
        if cum[i] >= vis_start then
            start_line = i
            break
        end
    end
    local end_line = n
    for i = start_line, n do
        if cum[i] >= vis_end then
            end_line = i
            break
        end
    end

    local sb = sboxes[start_line]
    local eb = sboxes[end_line]
    if not sb or not eb then return end

    -- ── Helper: proportional x estimate within a line ────────────
    local function estimateX(box, line_idx, char_off)
        local total = cum[line_idx] - cum[line_idx - 1]
        if total <= 0 then return box.x end
        local x = box.x + math.floor((char_off / total) * box.w)
        return math.max(box.x, math.min(box.x + box.w - 1, x))
    end

    -- ── Helper: query CRe selection (no-draw) ────────────────────
    local function querySelection(sx, sy, ex, ey)
        local r = doc:getTextFromPositions({x = sx, y = sy}, {x = ex, y = ey}, true)
        return r and r.text and Utils.ws(r.text) or ""
    end

    local start_y = sb.y + math.floor(sb.h / 2)
    local end_y   = eb.y + math.floor(eb.h / 2)

    -- ── Phase 1: Initial proportional estimates ──────────────────
    local sl_off = vis_start - cum[start_line - 1]
    local el_off = vis_end   - cum[end_line - 1]
    -- sl_off is 1-based char offset within the line.  For the start
    -- position we want the LEFT edge of that character, so subtract 1
    -- to convert to 0-based.  For end we want the RIGHT edge, so the
    -- 1-based offset maps directly to "fraction of line covered".
    local start_x = estimateX(sb, start_line, math.max(0, sl_off - 1))
    local end_x   = estimateX(eb, end_line, el_off)

    -- ── Phase 2: Binary-search refinement for end_x ──────────────
    -- CRe snaps to word boundaries.  If our end_x estimate is slightly
    -- past the last word of the sentence, CRe grabs the NEXT word too
    -- (overshoot).  If it's slightly before the period, CRe drops the
    -- last word (undershoot).  Binary-search to find the sweet spot.
    local function refineEndX(cur_sx, cur_sy, cur_ey)
        local got = querySelection(cur_sx, cur_sy, end_x, cur_ey)
        local got_len = #got
        local want_len = #sent_text

        if got_len == want_len and got == sent_text then
            return end_x  -- perfect match on first try
        end

        local lo, hi
        if got_len > want_len then
            -- Overshoot: pull end_x left.  Binary search [eb.x, end_x]
            hi = end_x
            lo = eb.x
        else
            -- Undershoot: push end_x right.  Binary search [end_x, eb.x+eb.w]
            lo = end_x
            hi = eb.x + eb.w - 1
        end

        local best_x = end_x
        local best_diff = math.abs(got_len - want_len)
        local MAX_ITER = 6  -- converges in ~log2(box.w/char_w) ≈ 5-6 steps
        for iter = 1, MAX_ITER do
            if hi - lo < 2 then break end
            local mid = math.floor((lo + hi) / 2)
            local mid_text = querySelection(cur_sx, cur_sy, mid, cur_ey)
            local mid_len = #mid_text
            local diff = math.abs(mid_len - want_len)

            if mid_text == sent_text then
                return mid  -- exact match
            elseif mid_len > want_len then
                -- Still overshooting, pull left
                hi = mid
            else
                -- Undershooting, push right
                lo = mid
            end

            if diff < best_diff or (diff == best_diff and mid_len <= want_len) then
                best_diff = diff
                best_x = mid
            end
        end
        return best_x
    end

    end_x = refineEndX(start_x, start_y, end_y)

    -- ── Phase 3: Refine start_x if sentence starts mid-line ──────
    -- Same problem: proportional estimate may land on wrong word.
    if sl_off > 1 then
        local got = querySelection(start_x, start_y, end_x, end_y)
        if got ~= sent_text then
            local got_start = got:sub(1, math.min(20, #got))
            local want_start = sent_text:sub(1, math.min(20, #sent_text))
            -- If the start is wrong, binary-search start_x
            if got_start ~= want_start then
                local lo = sb.x
                local hi = start_x + math.floor(sb.w * 0.3) -- don't search too far right
                hi = math.min(hi, sb.x + sb.w - 1)
                local best_x = start_x
                for iter = 1, 6 do
                    if hi - lo < 2 then break end
                    local mid = math.floor((lo + hi) / 2)
                    local mid_text = querySelection(mid, start_y, end_x, end_y)
                    local mid_start = mid_text:sub(1, math.min(20, #mid_text))
                    if mid_start == want_start then
                        best_x = mid
                        -- Expand left to find leftmost pixel that still
                        -- selects the correct first word.  This ensures the
                        -- visual highlight box covers the full first word.
                        hi = mid
                    else
                        -- Went too far left (includes previous word) — go right
                        lo = mid
                    end
                end
                start_x = best_x
                -- Re-refine end_x with corrected start_x
                end_x = refineEndX(start_x, start_y, end_y)
            end
        end
    end

    -- ── Draw the final selection ─────────────────────────────────
    -- Try CRe-accurate boxes first: make a final getTextFromPositions
    -- call with the refined coordinates, get xpointers, then use
    -- getScreenBoxesFromPositions for pixel-perfect word-boundary-aligned
    -- boxes.  Falls back to line-map estimation if CRe query fails.
    local boxes
    local final_res = doc:getTextFromPositions(
        {x = start_x, y = start_y},
        {x = end_x,   y = end_y},
        true)
    if final_res and final_res.pos0 and final_res.pos1 then
        -- Guard: only use CRe boxes if the selected text matches the
        -- sentence length.  If CRe snapped to a wider word boundary
        -- the boxes would visually overflow into the next sentence.
        local cre_text = final_res.text and Utils.ws(final_res.text) or ""
        local len_ok = #cre_text <= #sent_text + 3
        if len_ok then
            local cre_boxes = doc:getScreenBoxesFromPositions(
                final_res.pos0, final_res.pos1, true)
            if cre_boxes and #cre_boxes > 0 then
                boxes = {}
                for _, cb in ipairs(cre_boxes) do
                    if cb.w > 0 and cb.h > 0 then
                        table.insert(boxes, {x = cb.x, y = cb.y, w = cb.w, h = cb.h})
                    end
                end
                if #boxes == 0 then boxes = nil end
            end
        end
    end
    -- Fallback: compute boxes from line map with estimated pixel coords
    if not boxes then
        boxes = {}
        for i = start_line, end_line do
            local box = sboxes[i]
            local bx, bw = box.x, box.w
            if i == start_line and i == end_line then
                bx = start_x
                bw = end_x - start_x
            elseif i == start_line then
                bw = (box.x + box.w) - start_x
                bx = start_x
            elseif i == end_line then
                bw = end_x - box.x
            end
            if bw > 0 and box.h > 0 then
                table.insert(boxes, {x = bx, y = box.y, w = bw, h = box.h})
            end
        end
    end
    if #boxes > 0 then
        self._pending_boxes = boxes
        self:_ensureViewModule()
        self.is_highlighting = true
        self:_refreshHighlight(boxes, cur_page)
        return true
    end
end

--[[--
Register a view module so our paintTo runs after page content is drawn.
This is necessary because painting directly onto Screen.bb before the
repaint cycle causes the page redraw to overwrite our rectangles.
--]]
function HighlightManager:_ensureViewModule()
    if self._view_module_registered then return end
    if not self.ui or not self.ui.view then return end
    -- Create a minimal view module that delegates paintTo to us
    local hm = self
    local module = { paintTo = function(_, bb, x, y) hm:_paintOverlay(bb, x, y) end }
    self.ui.view:registerViewModule("audiobook_highlight", module)
    self._view_module_registered = true
end

--[[--
Called by the view module after page content is drawn.
Paints highlight rectangles for all styles (including invert).
@param bb BlitBuffer The screen framebuffer
--]]
function HighlightManager:_paintOverlay(bb, _x, _y)
    local boxes = self._pending_boxes
    if not boxes or #boxes == 0 then return end
    if not bb then return end
    local style = self.current_style
    local line_w = Screen:scaleBySize(2)
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    for _, box in ipairs(boxes) do
        -- Clip to screen bounds to prevent out-of-range framebuffer access
        local bx = math.max(0, box.x)
        local by = math.max(0, box.y)
        local bw = math.min(box.w - (bx - box.x), sw - bx)
        local bh = math.min(box.h - (by - box.y), sh - by)
        if bw > 0 and bh > 0 then
            if style == self.STYLES.INVERT then
                pcall(function() bb:invertRect(bx, by, bw, bh) end)
            elseif style == self.STYLES.UNDERLINE then
                bb:paintRect(bx, by + bh - line_w, bw, line_w,
                    Blitbuffer.COLOR_BLACK)
            elseif style == self.STYLES.BACKGROUND then
                -- Match KOReader's native "lighten" highlight style:
                -- darkenRect dims existing pixels by a factor (0.2 = 20%),
                -- producing the same smooth gray overlay used for bookmarks.
                bb:darkenRect(bx, by, bw, bh, 0.2)
            elseif style == self.STYLES.BOX then
                -- Top
                bb:paintRect(bx, by, bw, line_w, Blitbuffer.COLOR_BLACK)
                -- Bottom
                bb:paintRect(bx, by + bh - line_w, bw, line_w,
                    Blitbuffer.COLOR_BLACK)
                -- Left
                bb:paintRect(bx, by, line_w, bh, Blitbuffer.COLOR_BLACK)
                -- Right
                bb:paintRect(bx + bw - line_w, by, line_w, bh,
                    Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

--[[--
PDF: Use view.highlight.temp to draw temporary highlights.
--]]
function HighlightManager:_highlightSentencePaging(sentence, parsed_data, doc)
    logger.dbg("HighlightManager: PDF sentence highlight not yet implemented")
end

--[[--
Highlight a single word. Stores current word for reference;
actual visual highlighting is done at the sentence level to avoid
excessive e-ink refreshes.
@param word table Word object
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightWord(word, parsed_data)
    self.current_word = word
    self.is_highlighting = true
end

--[[--
Clear all highlights.
--]]
function HighlightManager:clearHighlights()
    if self._selection_active and self.ui and self.ui.document then
        pcall(function() self.ui.document:clearSelection() end)
        self._selection_active = false
    end
    self._pending_boxes = nil
    if self.is_highlighting then
        -- Refresh only the strip where the highlight was drawn.
        self:_refreshHighlight(nil, self._last_boxes_page)
    end
    self.current_word = nil
    self.is_highlighting = false
end

function HighlightManager:clearWordHighlight()
    -- No separate word highlight to clear
end

function HighlightManager:clearSentenceHighlight()
    self:clearHighlights()
end

function HighlightManager:hasHighlights()
    return self.is_highlighting
end

function HighlightManager:getStyleMenu()
    local menu = {}
    local style_names = {
        { id = "invert", name = _("Invert (best for e-ink)") },
        { id = "underline", name = _("Underline") },
        { id = "box", name = _("Box") },
        { id = "background", name = _("Background") },
    }
    for _, style in ipairs(style_names) do
        table.insert(menu, {
            text = style.name,
            checked_func = function()
                return self.current_style == style.id
            end,
            callback = function()
                self:setStyle(style.id)
            end,
        })
    end
    return menu
end

function HighlightManager:updateHighlight(word, sentence, parsed_data)
    if not word then return end
    if self.current_word and self.current_word.index == word.index then
        return
    end
    self:highlightWord(word, parsed_data)
end

return HighlightManager
