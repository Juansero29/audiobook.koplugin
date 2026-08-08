#!/usr/bin/env luajit
--[[--
Smoke test: multiline Storyteller SMIL/OPF must parse under Lua patterns.

Run from repo root:
  luajit dev/test_epubmediaoverlay_multiline.lua

No KOReader install required.
--]]

local RE_ANY_LAZY = "([%z\1-\255]-)"

local function count(pattern, text)
    local n = 0
    for _ in text:gmatch(pattern) do
        n = n + 1
    end
    return n
end

local multiline_smil = [[
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <seq epub:textref="chapter.xhtml">
      <par id="s0">
        <text src="../chapter.xhtml#s0"/>
        <audio src="../Audio/00001.mp4" clipBegin="0.000s" clipEnd="12.340s"/>
      </par>
      <par id="s1">
        <text src="../chapter.xhtml#s1"/>
        <audio src="../Audio/00001.mp4" clipBegin="12.340s" clipEnd="25.180s"/>
      </par>
    </seq>
  </body>
</smil>
]]

local multiline_opf = [[
<package>
  <manifest>
    <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml" media-overlay="mo1"/>
    <item id="mo1" href="MediaOverlays/ch1.smil" media-type="application/smil+xml"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
  </spine>
</package>
]]

local multiline_html = [[
<p>
  <span id="s0">Première phrase.</span>
  <span id="s1">Deuxième phrase.</span>
</p>
]]

local broken_par = count("<par([^>]*)>(.-)</par>", multiline_smil)
local fixed_par = count("<par([^>]*)>" .. RE_ANY_LAZY .. "</par>", multiline_smil)

local broken_manifest = multiline_opf:match("<manifest[^>]*>(.-)</manifest>") or ""
local fixed_manifest = multiline_opf:match("<manifest[^>]*>" .. RE_ANY_LAZY .. "</manifest>") or ""

local broken_spine = multiline_opf:match("<spine[^>]*>(.-)</spine>") or ""
local fixed_spine = multiline_opf:match("<spine[^>]*>" .. RE_ANY_LAZY .. "</spine>") or ""

local broken_span = count('<span[^>]-id="([^"]+)"[^>]*>(.-)</span>', multiline_html)
local fixed_span = count('<span[^>]-id="([^"]+)"[^>]*>' .. RE_ANY_LAZY .. '</span>', multiline_html)

local failures = {}

if broken_par ~= 0 then
    table.insert(failures, "expected broken par pattern to miss multiline SMIL, got " .. broken_par)
end
if fixed_par ~= 2 then
    table.insert(failures, "expected 2 par blocks, got " .. fixed_par)
end
if broken_manifest ~= "" then
    table.insert(failures, "expected broken manifest pattern to miss multiline OPF")
end
if fixed_manifest == "" or not fixed_manifest:find("media-overlay") then
    table.insert(failures, "expected fixed manifest pattern to capture overlay items")
end
if broken_spine ~= "" then
    table.insert(failures, "expected broken spine pattern to miss multiline OPF")
end
if fixed_spine == "" or not fixed_spine:find("itemref") then
    table.insert(failures, "expected fixed spine pattern to capture itemref")
end
if broken_span ~= 0 then
    table.insert(failures, "expected broken span pattern to miss (if spans were multiline)")
end
if fixed_span ~= 2 then
    table.insert(failures, "expected 2 sentence spans, got " .. fixed_span)
end

if #failures > 0 then
    io.stderr:write("FAIL\n")
    for _, msg in ipairs(failures) do
        io.stderr:write("  - " .. msg .. "\n")
    end
    os.exit(1)
end

print("ok: multiline Storyteller SMIL/OPF patterns parse correctly")
