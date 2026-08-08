## Summary

Fixes EPUB3 Media Overlay parsing for **Storyteller read-aloud EPUBs** on KOReader (Kindle/Kobo/etc.).

Storyteller books failed with:

`No Media Overlays found: no timing data extracted`

Two independent bugs caused this:

### 1. Multiline SMIL/OPF (Lua regex)

Storyteller pretty-prints SMIL/OPF. The parser used `(.-)`, but in Lua/LuaJIT `.` **does not match newlines**, so zero `<par>` blocks matched.

### 2. `unzip` wildcard characters in Storyteller filenames (Kindle blocker)

Storyteller encodes series tags in filenames, e.g.:

`MediaOverlays/Druon,Maurice-[Rois Maudits-1]Le Roi de fer(1955)...split_003.smil`

Info-ZIP `unzip` treats `[]` as **wildcards** in member names. `unzip -l` still lists `.smil` files (so overlay detection passes), but `unzip -p` with the raw path returns **empty content** for every bracketed SMIL/HTML file → zero timing entries.

Fix: escape literal `[` as `[[]` and `]` as `[]]` before calling `unzip -p` / `unzip -o`.

This is a follow-up to overlay work from #32 / DroidThug's PW5 merge (manifest href fixes, LuaJIT compile fixes). Those did not cover multiline XML or bracketed Storyteller paths.

Readest/foliate readers use ZIP + DOM parsing and are unaffected ([readest/readest#5562](https://github.com/readest/readest/pull/5562)).

## Changes

- `RE_ANY_LAZY = "([%z\1-\255]-)"` for cross-line XML captures
- `_escapeUnzipMember()` for Info-ZIP literal bracket escaping
- `_compactXml()` collapses `>\s+<` before parsing (extra safety)
- `dev/test_epubmediaoverlay_multiline.lua` smoke test

## Test plan

- [ ] `luajit dev/test_epubmediaoverlay_multiline.lua` → `ok`
- [ ] Storyteller EPUB with bracketed filenames (*Le Roi de fer*, 27 SMIL / 4648 `<par>` entries)
- [ ] Storyteller EPUB without brackets (`1984 - Readaloud.epub`, 25 SMIL / 6967 entries)
- [ ] **Tools → Audiobook Read-Along → Play aligned/enriched audiobook** on Kindle PW5 + KOReader
- [ ] Sentence highlight sync regression on a book that already worked

## Verification

| Book | Issue | Before | After |
|------|-------|--------|-------|
| Le Roi de fer | multiline SMIL + `[Series-1]` paths | 0 timing | 4648 timing |
| 1984 Readaloud | multiline SMIL only | 0 timing | 6967 timing |

Related: #32
