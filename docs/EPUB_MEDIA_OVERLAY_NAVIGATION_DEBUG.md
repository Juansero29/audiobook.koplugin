# EPUB Media Overlay navigation debugging notes

Date: 2026-07-10 through 2026-07-16
Plugin version: 0.1.17.0

This log traces the debugging of EPUB Media Overlay navigation in audiobook.koplugin. The central problem was that the book view would not jump to a sentence that lived in a different EPUB content document than the one currently on screen. Same-document navigation worked, but resume, refocus, and "Play aligned audiobook from here" all failed or behaved erratically when the target was in another document.

## The symptoms we started with

When Media Overlays were enabled, several navigation actions misbehaved. "Play aligned audiobook from here" started from a stale cached location instead of the selected text. The refocus button did not visibly jump back to the currently narrated sentence. Random page turns happened when the current page was not the one being read aloud. The main menu Play item showed a bare resume prompt at the wrong moment.

Version 0.1.16.13 addressed these in `main.lua`, `mediasync.lua`, `audiobookplayer.lua`, `highlightmanager.lua`, and `_meta.lua`. The SMIL parser and timing cache were made document-aware so switching books would not reuse old timing data. "Play from here" was routed around the resume prompt. The continue-listening prompt moved into `_startSmilPlayback` so it could offer Resume, From start, or Cancel with book, chapter, and last-played info. `_findCurrentPageSmilEntry` was rewritten to use the current `DocFragment[N]` index and spine hrefs instead of cross-document xpointer resolution. Page-turn-follow guards were hardened with a counter and longer suppression windows, and `navigateToSentenceAtTime` was called directly after resuming from a saved position. In `mediasync.lua`, the timestamp-based auto-follow guard was replaced by a counter, and `navigateToSentenceAtTime(seconds)` was added. The refocus button was made conditional on overlay mode, and `highlightmanager.lua` was fixed to clear pending highlight boxes before searching for a new sentence.

Even after those changes, the cross-document jump remained the hardest issue.

## Early attempts to cross documents

The first implementation of `MediaSync:_gotoSmilFragment` built a raw EPUB internal link such as `text/part0007.html#id12-s32` and called `ui.document:gotoLink(raw_xp)`. The call returned success and the log showed `gotoLink succeeded`, but the current xpointer never changed and the screen did not move. The lesson was that `CreDocument:gotoLink` only follows links that are actually present in the current document's link map; passing an arbitrary path is silently ignored.

When the target fragment was already in the current content document, `ui.rolling:onGotoXPointer("#id...")` worked well, so same-document jumps started behaving. Resume and refocus began to move when the target sentence was already on screen. "Play from here" regressed to the title page whenever the selected text was in a different document, because the `gotoLink` fallback still did nothing. The lesson was clear: same-document navigation works, but cross-document navigation is the real blocker.

We then tried relative hrefs for `gotoLink`, computing candidates like `part0007.html#id...` and `../text/part0007.html#id...` based on the currently loaded HTML file. Every candidate reported success, yet the xpointer remained unchanged. Without knowing the exact current content-document path, relative-link guessing was not enough, and `gotoLink` still ignored paths that were not real links in the current document.

Next we derived candidate DocFragment numbers from the spine order and called `ui.document:gotoXPointer("/body/DocFragment[N]/body")`, hoping to switch to the target content document before scrolling to the fragment. `gotoXPointer` returned success for every `N`, but the current xpointer never changed, so the function apparently only operates within the already-loaded content document.

We also tried `ui.document:getNormalizedXPointer("/body/DocFragment[N]/body//*[@id='...']")` to resolve a full internal xpointer that included both the target DocFragment and the element id. Every probe returned `false`. `getNormalizedXPointer` only resolves ids in the currently loaded document.

By this point the situation was stable but limited. "Play from here" worked when the selected text was in the current content document. Resume from the main menu did not jump when the saved sentence was in a different content document. Refocus was reported to not react in the latest test, although earlier logs showed the tap reaching the callback, so this looked like a separate UI or wiring issue.

## Text search and a page index

The next plan was to use crengine's text search API as the cross-document fallback. The SMIL parser already extracts the plain sentence text for each fragment, so when the target document was not currently loaded we could search the whole rendered book for the sentence text, use the returned xpointer to obtain the page number, load that page, verify that the fragment id now resolved, and scroll to it. To avoid running a text search on every auto-follow tick, `_startSmilPlayback` was supposed to build a small page index in the background, mapping each content document referenced by the overlays to a page number using a representative sentence as the search key. Auto-follow would then use the index to jump directly to a new content document, while resume and refocus would use the index first and fall back to `findText` if needed.

Testing on 2026-07-12 revealed several problems. The "Continue listening from" prompt was unrelated to "Play from here", because the saved aligned position was only written when playback stopped, so "Play from here" did not update it. "Play from here" worked once, then started skipping pages when narration moved to a different content document; auto-follow passed `allow_scan=false`, so it could not use the text-search fallback or the page index, and it fell back to `GotoViewRel(1)`, turning one page per sentence. Refocus did not appear to react because the page index pointed at the wrong page, for example `jumping to indexed page 30 for text/part0007.html` followed by `fragment id12-s0 not reachable`. The index had been built from an unvalidated `findText` result, so it mapped the document to a page in the wrong occurrence. Most documents could not be indexed at all, with `Audiobook: could not index SMIL content document ...` appearing for roughly 80% of documents, probably because of punctuation and whitespace differences between the extracted sentence text and the rendered text.

Fixes applied on 2026-07-12 included saving the selected entry as the aligned position when "Play from here" starts, adding `_normalizeSearchText` to match HighlightManager's normalization, and making `_ensureSmilPageIndexEntry` try several sample sentences and validate every `findText` result by loading the candidate page and checking that the sample fragment resolved there.

## Giving up on the DocFragment scan

On 2026-07-13 testing showed that the DocFragment scan failed for every document (`MediaSync: DocFragment scan failed for ...`). The background page-index builder therefore ran thousands of useless `getNormalizedXPointer` probes, which made playback laggy and unresponsive. The scan also failed on demand for resume and refocus, so those actions did nothing visible.

We disabled `_scheduleSmilPageIndexBuild` so no background scanning was performed, simplified `_ensureSmilPageIndexEntry` to return only a previously cached page entry, and removed the DocFragment scan fallback from `_gotoSmilFragment`. In its place we added a fast cross-document probe using `ui.document:getPageFromXPointer("#id")`. If crengine resolved the fragment id to a global page number, the code loaded that page, verified the fragment was reachable, and scrolled to it. Auto-follow with `allow_scan=false` now returned false immediately when the fragment was not in the current document, relying on the existing `GotoViewRel(1)` page-advance retry instead of scanning.

## The `getPageFromXPointer` dead end

Testing on 2026-07-14 showed that `getPageFromXPointer("#id...")` returned page 1 for every fragment, even fragments that were not in the title content document. Loading page 1 and verifying the fragment failed, so resume, refocus, and "Play from here" all left the view at the title page. A typical log excerpt looked like this:

```text
MediaSync: navigating to sentence 216 text/part0007.html id12-s215
MediaSync: getPageFromXPointer page 1 for #id12-s215
MediaSync: fragment id12-s215 not reachable in text/part0007.html
MediaSync: navigateToSentenceAtTime failed for text/part0007.html id12-s215
```

This confirmed that crengine could not resolve a plain fragment id to a global page number in this EPUB and device configuration.

The next idea was to persist the full internal xpointer cache across KOReader sessions. During normal playback, whenever a fragment was highlighted successfully, `MediaSync:_cacheResolvedXPointer` would resolve `#id` with `getNormalizedXPointer` and store the full internal xpointer. The cache was saved to `audiobook_settings.smil_xpointer_cache` keyed by EPUB path and fragment id. On the next resume, refocus, or "Play from here", `_gotoSmilFragment` would check the persisted cache first and use `ReaderRolling:_gotoXPointer(cached)` to jump directly, dropping stale entries if the cached xpointer failed.

That cache, however, never got populated. The log showed `Audiobook: loaded 0 SMIL xpointer entries ...` and the same `getPageFromXPointer page 1` failures. The cache only filled when a fragment was successfully highlighted, but cross-document fragments could never be highlighted because the view could not jump to them. We had a deadlock: we needed the cache to navigate, but we could not navigate to build the cache.

To break the deadlock, `_gotoSmilFragment` gained a `findText` fallback for user-initiated navigation. It took the sentence text from the SMIL timing entry, normalized whitespace and common Unicode punctuation, called `CreDocument:findText`, and used the returned full internal xpointer to move crengine's internal position. If the target fragment id became resolvable in the current content document, the full xpointer was cached. Auto-follow still did not use text search, so normal playback stayed responsive.

## The TOC fallback and the real root cause

On 2026-07-15 the `findText` fallback executed but returned no matches. Later that day it returned `ok=true` with zero results, which suggested `findText` might only search the currently loaded content document. As a countermeasure we added a TOC fallback. The SMIL parser already loaded a `basename -> chapter_title` map from the NCX, and `ui.document:getToc()` returned entries with `title`, `page`, and `xpointer`. We matched the chapter title for the target content document against the TOC, jumped to the entry's page or xpointer, verified the fragment id was resolvable, and scrolled to it.

The next test showed the TOC fallback finding the right chapter but the view still ending up at the title screen:

```text
MediaSync: TOC title match 7. Bob – July 25, 2133 page= 83 xpointer= /body/DocFragment[15]/body.0 for text/part0013.html
MediaSync: TOC fallback failed for text/part0013.html id18-s1
```

The TOC entry was correct and pointed at `DocFragment[15]`, but both `gotoPage(83)` and `gotoXPointer(/body/DocFragment[15]/body.0)` failed the `isXPointerInDocument("#id18-s1")` check, so the code restored the original page. The `findText` fallback fared slightly better: it found occurrences of the sentence text, such as `Landers looked uncharacteristically angry.`, but it discarded them because `#id18-s3` was still not resolvable after moving to the occurrence.

The real root cause was now obvious. Plain `#id` xpointers are only resolvable when the target content document is already the current document. After any cross-document jump, `isXPointerInDocument("#id")` stays false, so every verification step fails and the code rolls back to the title page. The problem was not locating the right chapter or even the right sentence; the problem was the verification mechanism itself.

The fix was to stop verifying with `#id` and instead navigate using the full internal xpointer that includes the `DocFragment` index, for example `/body/DocFragment[15]/body/p[@id='id18-s1']`. `getNormalizedXPointer()` can build that full xpointer from a probe, and `onGotoXPointer(full_xp)` can follow it.

We added `MediaSync:_tryGotoDocFragment(text_doc, fragment_id, docfrag_n, start_page)`, which builds several full-xpointer probes for a known DocFragment index, normalizes the first valid one, and jumps with `onGotoXPointer`. We added `MediaSync:_gotoViaSpineDocFragment(...)` to derive the DocFragment index directly from the EPUB spine order in `parser._spine_hrefs`. We also added `MediaSync:_getExpectedDocFragmentIndex(text_doc)` so the text-search fallback could compare the DocFragment index of each `findText` occurrence with the target document. `_gotoViaToc` was updated to extract `DocFragment[N]` from the matched TOC entry's xpointer and use the new full-xpointer jump instead of relying on `#id` verification. The text-search fallback now accepts an occurrence whose DocFragment index matches the target content document and navigates with the occurrence's full `start` xpointer, regardless of whether `#id` is currently resolvable. After a successful full-xpointer jump, the code caches the normalized xpointer and only calls `scroll_to_fragment()` if `#id` happens to be resolvable in the new document.

After deploying this change, resume, refocus, and "Play from here" finally jumped to the target sentence instead of the title screen.

## What to improve

The main remaining concern is rendering changes. If the user changes font size, margins, or other layout settings, cached xpointers may become stale. The code detects a failed cached jump and removes the stale entry, so the worst case is a one-time fallback to the full-xpointer navigation path. Auto-follow still avoids text search and scanning, so normal playback remains responsive. The cross-document navigation problem is now solved for user-initiated actions, and the cache makes repeated visits cheap.
