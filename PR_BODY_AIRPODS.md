## Summary

Hardens Kindle A2DP playback for **Apple AirPods Pro 3** (Paperwhite 11th gen field tests).

Fixes the “hear a blip, then permanent silence” failure and the later **pause → play = silent until BT reconnect** failure by keeping the A2DP datapath alive and re-arming the route when needed.

### Changes
- Skip redundant `seek-by-restart` / stop orphan-killing on PID-capture miss; recover PID via `pgrep`
- AirPods-aware `adelay`/`apad`, Music-focus reclaim, A2DP watchdog
- **Pause keepalive** (silence on `mixersink`, same idea as TTS) + resume with optional **Disconnect/Connect** cycle when `audioOutputConnected` stays down
- Bug report: Apple headset detection, `btfd` lists, input devices, `btui` probe
- Field doc: [`docs/AIRPODS_PRO3_KINDLE.md`](../blob/pr/airpods-pro3-a2dp/docs/AIRPODS_PRO3_KINDLE.md)

### Known limitation
**AirPods stem Play/Pause does not work on Kindle PW11.** No AVRCP input device / no `btui` on this firmware. Stem volume and ANC still work. Use on-screen / Kindle controls. Details and future research notes are in the doc. Kobo Libra Colour is a better candidate for stem AVRCP (existing `mtkbtd` path).

## Manual tests (Kindle Paperwhite 11 + AirPods Pro 3)

- [x] First play after connect — audio continues past 1–2 s
- [x] Pause (UI) several seconds → Play — audio returns
- [x] Longer pause (~2 min) → Play — audio returns (keepalive)
- [x] Seek / chapter jump while playing
- [x] Plugin BT Disconnect/Connect restores stale A2DP route
- [x] Bug report shows `kindle_apple_headset` / connected lists
- [x] Stem volume ± and ANC — work (system / headset)
- [ ] Stem Play/Pause — **not available** on this Kindle firmware (documented)

## Related
- Storyteller EPUB3 overlay PR (separate): multiline SMIL / UX — tested on same Kindle with Bose QC Ultra Gen1 and AirPods
- Platform overview: `docs/PLATFORM_AUDIO.md`
