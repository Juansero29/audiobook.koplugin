## Summary

Full Storyteller EPUB3 Media Overlay read-aloud support for KOReader (validated on Kindle + Bose QuietComfort Ultra Gen1).

Fixes the previous `"no timing data extracted"` failures and later highlight/narration desync after Storyteller re-exports.

### Core parsing
- Multiline SMIL/OPF (`RE_ANY_LAZY`) — Lua `.` does not match newlines
- Info-ZIP bracket escape (`[` → `[[]`) for Storyteller paths like `Author-[Series-1]Title...smil`
- `_compactXml()` safety for pretty-printed XML
- Spine-ordered SMIL parse; nested `<span>` text extraction

### Playback / UX
- Live SMIL load progress on e-ink (`forceRePaint`)
- **Play aligned from here** via fragment id + scored text match (no crawl)
- Page-follow without `GotoViewRel` freeze
- Stale highlight cleared when browsing away while paused/playing
- **Return to read-aloud** cue on the mini player bar (tappable / ◎)
- EPUB size+mtime fingerprint → wipe stale `cache/overlays/` when the book is re-exported in place
- Fragment-id highlighting (Readest-style) preferred over fuzzy text match

## Manual tests (Kindle + Bose QuietComfort Ultra Gen1)

All verified working:

- [x] **Cold start** — KOReader restart, open *Le Roi de fer*, Play aligned/enriched audiobook; SMIL loads with live progress (no `"no timing data"`)
- [x] **Highlight sync** — first sentences highlight correctly; page auto-follow stays on the spoken sentence
- [x] **Play aligned from here** — long-press mid-chapter; audio starts at that sentence
- [x] **Return to read-aloud** — browse away while playing/paused; mini bar shows *Return to read-aloud*; tap / ◎ restores position + highlight
- [x] **Pause + browse** — pause, change page: no stale highlight; return cue works
- [x] **Seek / skip** — sentence/chapter controls stay aligned with text
- [x] **Chapter list** — jump lands on correct text + audio
- [x] **Resume after close** — reopen book, resume near last position
- [x] **Re-export / cache** — regenerating the Storyteller EPUB invalidates stale overlay audio cache; highlights match new alignment
- [x] **Bluetooth audio** — Bose QuietComfort Ultra (Gen1) headset; sync/highlights track audible narration

## Automated / fixture checks

- [x] `luajit dev/test_epubmediaoverlay_multiline.lua` smoke test
- [x] Storyteller EPUB with bracketed filenames (*Le Roi de fer*)
- [x] Timing extraction non-zero after parse

## Notes

- Deploy: `koreader/plugins/audiobook.koplugin/` — full KOReader restart after update
- First play after EPUB change re-extracts embedded audio (~hundreds of MB); expected
- Related: #32; Readest reference: [readest/readest#5562](https://github.com/readest/readest/pull/5562)
