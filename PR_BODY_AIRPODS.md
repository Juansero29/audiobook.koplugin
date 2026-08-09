## Summary

Hardens Kindle A2DP playback for **Apple AirPods Pro 3** on a jailbroken **Paperwhite 11th gen** (KOReader field tests, Aug 2026).

Fixes the “blip then permanent silence” failure, **pause → play silence until BT reconnect**, and **EOS / playlist-chunk silence** when Storyteller (or any multi-file) audio advances to the next embedded part.

Root cause: Kindle `audiomgrd` drops the A2DP datapath when `mixersink` goes idle across stop→play gaps (seek-by-restart, pause, track advance). Manual Disconnect/Connect re-arms the route; the plugin now bridges that gap.

### Changes
- Skip redundant `seek-by-restart` / stop orphan-killing on PID-capture miss; recover PID via `pgrep`
- AirPods-aware `adelay`/`apad`, Music-focus reclaim, A2DP watchdog
- **Pause keepalive** (silence on `mixersink`, same idea as TTS) + resume with optional **Disconnect/Connect** when `audioOutputConnected` stays down
- **Track-advance bridge**: soft-stop keeps keepalive + player UI across playlist/Storyteller file changes (hard stop was killing the bridge and leaving Play dead in `STOPPED`)
- Cached headset MAC (`ListConnected` → `ListPaired` → last-seen) so BT cycles don’t skip with “no connected MAC”
- Menu: **Bluetooth settings → Reconnect BT on track change** (`kindle_bt_reconnect_on_track`, **off by default**) — optional forced Disconnect→Connect (~5–10 s) before the next file; keepalive still runs either way
- Overlay **BT** shortcut button removed (v0.1.17.22); use the menu setting / plugin BT menu instead
- Bug report: Apple headset detection, `btfd` lists, input devices, `btui` probe
- Field doc: [`docs/AIRPODS_PRO3_KINDLE.md`](docs/AIRPODS_PRO3_KINDLE.md)

### Known limitation
**AirPods stem Play/Pause does not work on Kindle PW11.** No AVRCP input device / no `btui` on this firmware. Stem volume and ANC still work. Use on-screen / Kindle controls. Details in the doc. Kobo Libra Colour is a better candidate for stem AVRCP (existing `mtkbtd` path).

## Manual tests (Kindle Paperwhite 11 + AirPods Pro 3)

- [x] First play after connect — audio continues past 1–2 s
- [x] Pause (UI) several seconds → Play — audio returns
- [x] Longer pause (~2 min) → Play — audio returns (keepalive)
- [x] Seek / ±30s while playing — audio continues (seek-bridge)
- [x] Natural EOS → next Storyteller audio part (~4 min chunks) — audio resumes with keepalive; optional BT reconnect setting validated when enabled
- [x] Plugin BT Disconnect/Connect restores stale A2DP route
- [x] **Reconnect BT on track change** (menu) — works well across chunk boundaries
- [x] Play from `STOPPED` after a botched transition — restarts current file
- [x] Bug report shows `kindle_apple_headset` / connected lists
- [x] Stem volume ± and ANC — work (system / headset)
- [ ] Stem Play/Pause — **not available** on this Kindle firmware (documented)

## Related
- Storyteller EPUB3 overlay PR (separate): multiline SMIL / read-aloud UX — tested on same Kindle with Bose QC Ultra Gen1 and AirPods Pro 3
- Platform overview: `docs/PLATFORM_AUDIO.md`
