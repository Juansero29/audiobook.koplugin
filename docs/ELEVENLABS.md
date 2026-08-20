# ElevenLabs cloud TTS

ElevenLabs is an optional **connected** TTS backend: each sentence is sent to
`https://api.elevenlabs.io` over Wi-Fi and played as MP3 through the same
Android `MediaPlayer` path as Storyteller overlay. Quality is much closer to a
studio narrator than on-device Google TTS or SherpaTTS.

The API key is stored only in KOReader settings (`audiobook_settings`). It is
never written into plugin files, git, `debug.log`, or bug reports.

**What you need**

- An [ElevenLabs](https://elevenlabs.io/) account and an API key
- Wi-Fi on the device while reading (every sentence is an HTTPS request)
- KOReader on Android (the current playback path uses the JNI MediaPlayer)

Offline reading still uses **System TTS** (SherpaTTS, Google, …) or Piper /
espeak-ng on Kobo and Kindle.

---

## Create an API key (permissions)

In the ElevenLabs dashboard: **Developers → API keys → Create key**
(*Développeurs → Clés API → Créer une clé*).

You then choose how wide the key is. **Prefer a restricted key.** An unrestricted
key that leaks can empty the quota, clone/add voices on the account, and call
every other product API.

### Option A — Restricted key (recommended)

Keep **Restrict key** / **Restreindre la clé** enabled, then grant only:

| Dashboard (English) | Dashboard (French) | Access | Why the plugin needs it |
|---------------------|--------------------|--------|-------------------------|
| **Text to Speech** | **Text To Speech** | enabled | Synthesize each sentence (`POST /v1/text-to-speech/{voice_id}`). |
| **Voices** | **Voix** | **Write** (*Écriture*) | List account voices and **add a public-library voice** to the account (`GET /v1/voices`, `POST /v1/voices/add/…`). Read-only is not enough to pick a library voice. |
| **Voice generation** | **Génération de voix** | enabled | Required so the voice library / shared-voice list works in the picker. |
| **Forced alignment** | **Alignement forcé** | enabled | Required by the same voice-library path; without it the picker or add-voice call fails. |
| **Models** | **Modèles** | enabled | Resolve the selected model (`eleven_multilingual_v2`, Flash, Turbo, …). |

Leave everything else off (Speech to Text, Dubbing, Agents, …).

If a menu still returns `missing_permissions` / `401`, re-open the key and
confirm **Voices** is **Write**, not Read.

### Option B — Unrestricted key (not recommended)

Uncheck **Restrict key** / **Restreindre la clé** so the key has every
permission. That is the fastest way to test, but **dangerous if the key
leaks** (KOReader settings, a shared screenshot, a backup of
`settings.reader.lua`). Use option A for a key that lives on a device.

---

## Plugin setup

1. Copy the key (it looks like `sk_…` / `xi-…`). Do not commit it; the repo
   gitignores `tools/elevenlabs_api_key.txt`.
2. In KOReader, open a book → **Tools → Audiobook → TTS settings** (or
   **Voice settings**).
3. Choose engine **ElevenLabs (cloud, high quality)**.
4. Paste the API key. The menu only shows a masked suffix (`••••abcd`).
5. Set **language** (auto = book metadata, else UI language) and pick a
   **voice**. Account voices appear first; public-library voices are added to
   the account on first use (that is why Voices **Write** is required).
6. Optional: play **Preview** (a few sentences from the current chapter).
7. Long-press a word → **Read aloud from here**.

Wi-Fi must stay up for the whole session. Switching to **System TTS** works
offline again.

---

## Privacy

- Book text is sent in the HTTPS body of each TTS request. It is **not**
  written to `debug.log` or bug reports.
- The API key is never logged. Bug reports only say `elevenlabs_configured: yes`
  and the model / voice **label**.
- Treat `settings.reader.lua` like a password file if you enabled ElevenLabs.

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| “API key is not set” | Paste the key under TTS settings; fully quit KOReader if you edited `settings.reader.lua` by hand. |
| `missing_permissions` when listing or adding a voice | Restricted key: enable **Voices → Write**, **Voice generation**, **Forced alignment**, **Models**. |
| `missing_permissions` when speech starts | Enable **Text to Speech**. |
| Preview / read-aloud is silent, System TTS works | Needs the current plugin build (JNI MediaPlayer + audio focus). Generate a bug report. |
| No Wi-Fi / timeout | Connect to a network, or switch the engine to System TTS. |

Full walkthrough from the main README: [ElevenLabs cloud TTS](../README.md#elevenlabs-cloud-tts-wifi).
