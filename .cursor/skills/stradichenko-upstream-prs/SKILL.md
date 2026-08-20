---
name: stradichenko-upstream-prs
description: >-
  How stradichenko (Gary) consumes audiobook.koplugin PRs: cherry-pick/rewrite
  one slice per version tag instead of merging the whole PR. Use when opening,
  updating, rebasing, or splitting PRs to github.com/stradichenko/audiobook.koplugin,
  when the user mentions PR 62/67/68, upstream, master-juan, fork master, or
  contributing overlay/TTS/ElevenLabs slices.
---

# Upstream PRs for stradichenko/audiobook.koplugin

Owner: **Gary** (`stradichenko`). Fork: `Juansero29/audiobook.koplugin`.
Remotes: `origin` = fork, `upstream` = official.

He rarely merges a multi-commit PR as-is. He **rewrites one logical slice**,
commits as himself with `Co-authored-by: Juan Rodríguez`, tags
`v0.1.17.xx`, and leaves the PR open. Adapt to that: small, rebaseable slices.

## Branches (this fork)

| Branch | Role |
|--------|------|
| `origin/master` | Fast-forward only to `upstream/master`. Never rewrite. |
| `master-juan` | Device integration (Boox Go 10.3 + Kindle PW11). Official master **plus** in-flight Juan work. Future official master, not a PR target. |
| Feature branches | One unpicked slice, branched from **latest `upstream/master`**. |

Do not open PRs from `master-juan` onto `stradichenko/master`.
Do not stack ElevenLabs / SherpaTTS pitch / TTS chrome on top of overlay
code he has not picked yet.

```
git fetch --all --prune
git checkout -b feat/short-slice upstream/master
# cherry-pick or copy ONLY the unpicked slice
```

## What he already took from #62 (do not re-PR)

Still-open PR 62 is not "ignored"; he landed rewritten slices:

- `4b56cea` — overlay highlight when CRe misses Storyteller `#id` (**v0.1.17.37**, refs #62)
- `2a31887` — pin bar without live `SetPageMargins`; lock margins **default off** (**v0.1.17.38**, refs #62)
- `62edf76` — Audiobookshelf browse/search/cache (**v0.1.17.36**, refs #65)

His rewrite is the source of truth for those files. After he lands a slice,
drop it from remaining PRs (rebase onto new `upstream/master`).

## Still unpicked (separate PRs, each from latest upstream)

- TTS AudiobookPlayer chrome / SMIL page-follow extras (`ea85ab5` minus overlay he already rewrote)
- Chapter-timeline seek across SMIL audio parts (`dd52692`)
- SherpaTTS natural pitch + TTS contiguous underline (PR 67)
- ElevenLabs cloud TTS + wrap-carry + AndroidPlayer audio focus (PR 68) — **rebase onto upstream only**, do not include overlay/TTS-chrome commits

## PR shape he actually lands

One concern, one commit if possible, sized like one version tag.

Commit subject (he uses this pattern when rewriting):

```
overlay: recover on-page highlight when CRe cannot resolve Storyteller span ids (refs #62, v0.1.17.37)
```

Body: **why** (device, CRe, ANR), not a file list. Mention the issue.

For **upstream** PRs:

- New settings **default off** (opt-in). `master-juan` may keep device defaults on.
- No live `SetPageMargins` on Android after the page is typeset (ANR).
- Do not dump translations / l10n churn unless the slice needs new strings.
- Do not include `.cursor/`, API keys, or `tools/elevenlabs_api_key.txt`.

## After he publishes a new tag

1. Fast-forward fork `master` to `upstream/master` (never force-push).
2. Merge that into `master-juan`; prefer **his** overlay rewrite on conflicts.
3. Rebase or recreate each open upstream PR on the new master, leaving only unpicked code.
4. Do not "help" by merging the whole of #62/#67/#68 into official master.

## Credit

He authors the landed commit. `Co-authored-by: Juan Rodríguez <juansero29@gmail.com>` is enough. Do not fight that.
