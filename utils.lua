--[[--
Shared Utility Functions
Common helpers used across the audiobook plugin modules.
Eliminates duplication of commandExists, ws, countSyllables.

@module utils
--]]

local Utils = {}

--- Check if a command exists on the system PATH.
-- @param cmd string  Command name (e.g. "piper", "espeak-ng")
-- @return boolean
function Utils.commandExists(cmd)
    local handle = io.popen("which " .. cmd .. " 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result and result ~= ""
    end
    return false
end

--- Normalise whitespace: collapse runs to single space, trim edges.
-- @param s string
-- @return string
function Utils.ws(s)
    if not s then return "" end
    return s:gsub("%s+", " "):match("^%s*(.-)%s*$")
end

--- Normalize text for matching against crengine-rendered text.
-- SMIL/source text and rendered text differ systematically: curly quotes,
-- dashes, non-breaking spaces, zero-width chars, and (in some production
-- pipelines) runs of straight apostrophes used as an escaping convention,
-- e.g. "June'''s" for "June's".  Matching only, never for display.
-- @param s string
-- @return string
function Utils.normalizeForMatching(s)
    if not s then return "" end
    return s
        :gsub("[\n\r]+", " ")
        :gsub("%s+", " ")
        :gsub("\226\128[\152-\155]", "'")    -- curly quotes U+2018-U+201B → straight '
        :gsub("\226\128[\156-\159]", '"')    -- curly double quotes U+201C-U+201F → straight "
        :gsub("\194\171", '"')               -- « guillemet → straight "
        :gsub("\194\187", '"')               -- » guillemet → straight "
        :gsub("\226\128[\147-\148]", "-")    -- en/em-dash → hyphen
        :gsub("\226\128\166", "...")         -- ellipsis
        :gsub("\194\160", " ")               -- non-breaking space → space
        :gsub("\194\173", "")                -- soft hyphen removed
        :gsub("\226\128[\139\169]", "")      -- zero-width chars removed
        :gsub("\239\187\191", "")            -- BOM removed
        :gsub("''+", "'")                    -- apostrophe-run artifact
        :gsub("^%s+", ""):gsub("%s+$", "")
end

--- Count the number of syllables in an English word (heuristic).
-- @param word string
-- @return number  Syllable count (minimum 1)
function Utils.countSyllables(word)
    if not word or word == "" then return 1 end

    word = word:lower()
    local count = 0
    local prev_vowel = false

    for i = 1, #word do
        local char = word:sub(i, i)
        local is_vowel = char:match("[aeiouy]")
        if is_vowel and not prev_vowel then
            count = count + 1
        end
        prev_vowel = is_vowel
    end

    -- Silent-e rule
    if word:sub(-1) == "e" and count > 1 then
        count = count - 1
    end

    return math.max(count, 1)
end

--- Normalize a directory path: collapse double slashes, strip trailing slashes.
-- @param path string|nil
-- @return string  Normalized path without trailing slash
function Utils.normalizeDirPath(path)
    if not path then return "." end
    path = path:gsub("//+", "/")
    path = path:gsub("/+$", "")
    if path == "" then return "." end
    return path
end

--- Detect the number of CPU cores (same logic as piperqueue.lua).
-- @return number  Core count (1 when undetectable)
function Utils.getCpuCores()
    local f = io.open("/sys/devices/system/cpu/possible", "r")
    if f then
        -- Format: "0-N" → N+1 cores, or "0" → 1 core
        local s = f:read("*l") or "0"
        f:close()
        local hi = s:match("%-(%d+)")
        if hi then return tonumber(hi) + 1 end
        return 1
    end
    return 1  -- conservative fallback
end

--- Read total system memory in kB from /proc/meminfo.
-- @return number|nil  MemTotal in kB, or nil when unreadable
function Utils.getMemTotalKb()
    local f = io.open("/proc/meminfo", "r")
    if not f then return nil end
    for line in f:lines() do
        local kb = line:match("MemTotal:%s+(%d+)%s+kB")
        if kb then
            f:close()
            return tonumber(kb)
        end
    end
    f:close()
    return nil
end

return Utils
