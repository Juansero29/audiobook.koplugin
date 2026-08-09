## Summary

Full Storyteller EPUB3 Media Overlay read-aloud support for KOReader (validated on Kindle + Bose QuietComfort Ultra Gen1, later AirPods Pro 3).

Fixes the previous `"no timing data extracted"` failures and later highlight/narration desync after Storyteller re-exports. Follow-up field tests (Aug 2026) also fixed **manual page-turn seeking audio** (must not restart/jump tracks) and status-bar UX.

### Core parsing
- Multiline SMIL/OPF (`RE_ANY_LAZY`) — Lua `.` does not match newlines
- Info-ZIP bracket escape (`[` → `[[]`) for Storyteller paths like `Author-[Series-1]Title...smil`
- `_compactXml()` safety for pretty-printed XML
- Spine-ordered SMIL parse; nested `<span>` text extraction

### Playback / UX
- Live SMIL load progress on e-ink (`forceRePaint`)
- **Play aligned from here** via fragment id + scored text match (no crawl)
- Page-follow without `GotoViewRel` freeze
- **Manual page turns never seek/restart audio** — highlighting pauses, **Return to read-aloud** cue on the mini bar; auto-follow resumes on return or when narration catches up
- Soft track transitions for multi-file Storyteller audio (playlist parts are Storyteller chunks, not Kindle-invented)
- Player title = book title (not first SMIL sentence text)
- ⏭/⏮ in overlay mode = SMIL content-document chapters (not raw ~4 min audio parts)
- Chapter list jumps across audio files without losing the session
- EPUB size+mtime fingerprint → wipe stale `cache/overlays/` when the book is re-exported in place
- Fragment-id highlighting (Readest-style) preferred over fuzzy text match
- Optional **Keep status bars during read-aloud** — mini player sits above KOReader’s bottom status bar

## Manual tests (Kindle + Bose QuietComfort Ultra Gen1 / AirPods Pro 3)

All verified working:

- [x] **Cold start** — KOReader restart, open *Le Roi de fer*, Play aligned/enriched audiobook; SMIL loads with live progress (no `"no timing data"`)
- [x] **Highlight sync** — first sentences highlight correctly; page auto-follow stays on the spoken sentence
- [x] **Play aligned from here** — long-press mid-chapter; audio starts at that sentence
- [x] **Return to read-aloud** — browse away while playing/paused; mini bar shows *Return to read-aloud*; tap / ◎ restores position + highlight; **audio keeps playing** (no seek/restart)
- [x] **Manual page turn mid-chapter** — peek ahead: no audio jump to earlier track; highlight off + return cue
- [x] **Pause + browse** — pause, change page: no stale highlight; return cue works
- [x] **Seek / skip** — sentence/chapter controls stay aligned with text
- [x] **Chapter list** — jump lands on correct text + audio
- [x] **Natural multi-file advance** — Storyteller ~4 min audio parts chain (A2DP bridge covered in companion AirPods PR when needed)
- [x] **Resume after close** — reopen book, resume near last position
- [x] **Re-export / cache** — regenerating the Storyteller EPUB invalidates stale overlay audio cache; highlights match new alignment
- [x] **Bluetooth audio** — Bose QuietComfort Ultra (Gen1) and AirPods Pro 3; sync/highlights track audible narration

## Automated / fixture checks

- [x] `luajit dev/test_epubmediaoverlay_multiline.lua` smoke test
- [x] Storyteller EPUB with bracketed filenames (*Le Roi de fer*)
- [x] Timing extraction non-zero after parse

## Notes

- Deploy: `koreader/plugins/audiobook.koplugin/` — full KOReader restart after update
- First play after EPUB change re-extracts embedded audio (~hundreds of MB); expected
- Storyteller embeds many short audio files inside the EPUB; the plugin plays them as a playlist (Readest presents one continuous timeline)
- Related: #32; companion AirPods A2DP PR for Kindle PW11 idle-route drops; Readest reference: [readest/readest#5562](https://github.com/readest/readest/pull/5562)
