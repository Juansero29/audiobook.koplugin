#!/usr/bin/env luajit
--[[--
Smoke test for Storyteller EPUB overlay parsing helpers.

  luajit dev/test_epubmediaoverlay_multiline.lua

No KOReader install required.
--]]

local RE_ANY_LAZY = "([%z\1-\255]-)"

local function escape_unzip_member(path)
    return path:gsub("%[", "[[]")
end

local function compact_xml(xml)
    return xml:gsub(">%s+<", "><")
end

local function count_par(smil, pattern)
    local n = 0
    for _ in smil:gmatch(pattern) do
        n = n + 1
    end
    return n
end

local multiline_smil = [[
<smil>
  <body>
    <par id="s0">
      <text src="../Author-[Series-1]Title.html#s0"/>
      <audio src="../Audio/00001.mp4" clipBegin="0.000s" clipEnd="12.340s"/>
    </par>
  </body>
</smil>
]]

local storyteller_member =
    "MediaOverlays/Author-[Series-1]Title_split_003.smil"
local escaped = escape_unzip_member(storyteller_member)

local broken = count_par(multiline_smil, "<par([^>]*)>(.-)</par>")
local fixed = count_par(compact_xml(multiline_smil), "<par([^>]*)>" .. RE_ANY_LAZY .. "</par>")

local failures = {}

if broken ~= 0 then
    table.insert(failures, "broken par pattern should miss multiline SMIL")
end
if fixed ~= 1 then
    table.insert(failures, "expected 1 par after compact+fixed, got " .. fixed)
end
if escaped ~= "MediaOverlays/Author-[[]Series-1]Title_split_003.smil" then
    table.insert(failures, "unexpected unzip escape: " .. escaped)
end

if #failures > 0 then
    io.stderr:write("FAIL\n")
    for _, msg in ipairs(failures) do
        io.stderr:write("  - " .. msg .. "\n")
    end
    os.exit(1)
end

print("ok: multiline SMIL patterns and unzip member escaping")
