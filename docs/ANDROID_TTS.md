# Android TTS: Feasibility Analysis and Implementation

**Date:** March 2026
**Status:** Implemented

---

## 1. Problem Statement

The audiobook plugin's TTS pipeline shells out to CLI binaries (espeak-ng,
Piper) compiled for Linux/glibc. Android uses Bionic libc with an incompatible
dynamic linker, so the bundled ARM binaries cannot execute. The plugin currently
shows a "not yet supported" error on Android.

The goal is to synthesize speech on Android KOReader by using the Android
TextToSpeech Java API through the JNI bridge that KOReader's Android launcher
already exposes to Lua.

---

## 2. KOReader Android Architecture

### 2.1 android-luajit-launcher

KOReader on Android runs inside `android-luajit-launcher`, a Kotlin/C host that
embeds LuaJIT. The Kotlin layer (`LuaInterface.kt`) exposes ~60 JNI methods to
Lua for file I/O, device features, and shell access. However, none of these
methods cover TTS.

### 2.2 android.lua JNI Primitives

The file `frontend/device/android/android.lua` provides low-level JNI
primitives accessible from Lua:

- `JNI:context()` -- retrieve the Android application Context
- `JNI:callVoidMethod()`, `JNI:callIntMethod()`, `JNI:callBooleanMethod()`
- `JNI:callObjectMethod()`, `JNI:callStaticVoidMethod()`
- `JNI:env()` -- raw JNI environment pointer
- `android.execute(cmd)` -- shell out via Runtime.exec()
- `android.stdout(cmd)` -- shell out and capture stdout

The JNI environment functions (FindClass, GetMethodID, NewStringUTF,
CallVoidMethod, etc.) are all available through the FFI-wrapped JNI pointer,
meaning Lua code can instantiate arbitrary Java objects and call their methods
without any upstream KOReader changes.

### 2.3 os.execute() on Android

On Android, `os.execute()` is overridden to use `JNI Runtime.exec()` instead of
the POSIX `system()` call. This means shell-based CLI tools work the same way
they would on Linux, but native Bionic binaries must be used (not glibc-linked
ones).

---

## 3. Approaches Evaluated

### 3.1 Upstream KOReader Pull Request

**Concept:** Add TTS methods to `LuaInterface.kt` in android-luajit-launcher,
exposing `synthesizeToFile()` and `setLanguage()` as first-class Lua functions.

**Pros:**
- Clean API, no raw JNI juggling in Lua
- Benefits the entire KOReader ecosystem

**Cons:**
- Requires changes to android-luajit-launcher (separate repo, separate
  maintainers, separate release cycle)
- Plugin cannot ship independently; users must wait for a KOReader release
  that includes the new launcher

**Verdict:** Best long-term solution. Not viable as an immediate fix since this
plugin ships independently.

### 3.2 Termux:API (termux-tts-speak)

**Concept:** Shell out to `termux-tts-speak` instead of espeak-ng.

**Pros:**
- Simple drop-in; same os.execute() pattern as other backends

**Cons:**
- Speaks directly through the device speaker; does NOT synthesize to a WAV file
- The underlying Java code (`TextToSpeechAPI.java`) calls `mTts.speak()`, not
  `mTts.synthesizeToFile()`
- Without a WAV file, the plugin cannot compute word-level highlight timing
  (the core feature of this plugin)
- Requires users to install Termux and Termux:API -- heavy dependency

**Verdict:** Non-starter. No WAV output means no word-highlight sync.

### 3.3 Cross-compile espeak-ng for Android/Bionic

**Concept:** Cross-compile espeak-ng with the Android NDK (targeting Bionic
libc) and bundle it in the plugin, exactly like the Kobo/glibc build.

**Pros:**
- Same pipeline, same WAV output, same timing data
- No Java/JNI complexity

**Cons:**
- espeak-ng has POSIX dependencies (mmap, iconv, optional PulseAudio) that need
  Android-specific patches or stubs
- Android file system restrictions: the plugin directory under KOReader's assets
  may not have execute permission; /data/local/tmp does but requires setup
- Must target multiple ABIs (armeabi-v7a, arm64-v8a, x86_64 for emulators)
- Separate build and packaging pipeline per ABI

**Verdict:** Feasible but high build-engineering cost. Appropriate for a second
phase after the JNI approach validates the concept.

### 3.4 Raw JNI TTS from Lua (Chosen Approach)

**Concept:** Use the JNI primitives already available in `android.lua` to
instantiate `android.speech.tts.TextToSpeech` directly from Lua, then call
`synthesizeToFile()` to produce a WAV that feeds into the existing pipeline.

**Pros:**
- Zero upstream changes; ships entirely within this plugin
- Produces a real WAV file with standard headers
- Reuses the existing timing estimation, playback, and highlight sync code
- Uses whatever TTS engine the user has installed on their device (Google,
  Samsung, etc.)

**Cons:**
- TextToSpeech requires async initialization (OnInitListener callback) and
  async synthesis completion (UtteranceProgressListener)
- Java callbacks into Lua require either polling or a proxy mechanism
- Managing Java object lifecycles (GC prevent via GlobalRef) from Lua/FFI
- Complexity of driving the JNI env pointer correctly for each method signature

**Verdict:** Chosen. Self-contained, no external dependencies, produces WAV
files compatible with the full plugin pipeline.

---

## 4. Implementation

### 4.1 Java Layer: android/TtsHelper.java

A minimal Java class (`org.koreader.plugin.audiobook.TtsHelper`) that wraps
Android's `TextToSpeech` and `MediaPlayer` APIs with a polling-friendly
interface. Compiled to a `.dex` file via `android/build-dex.sh`.

**Polling design:** Android TTS uses `OnInitListener` and
`UtteranceProgressListener` callbacks. Since LuaJIT cannot implement Java
interfaces, the callbacks set volatile status fields that Lua polls:
- `getInitStatus()`: returns -1 (pending), 0 (success), >0 (error)
- `getSynthStatus()`: returns -1 (idle), 0 (in-progress), 1 (done), 2 (error)

**Synthesis:** `synthesizeToFile(text, path)` wraps
`TextToSpeech.synthesizeToFile(CharSequence, Bundle, File, String)` to produce
WAV files compatible with the plugin's existing pipeline.

**Playback:** `playFile(path)` wraps Android's `MediaPlayer` for WAV playback,
returning the audio duration in ms. Supports `pausePlayback()`,
`resumePlayback()`, `stopPlayback()`, `isPlaying()`, and `isPlaybackDone()`.

### 4.2 Lua Layer: androidtts.lua

A Lua module that manages the JNI lifecycle for TtsHelper.

**Init sequence:**
1. Verify `Device:isAndroid()` and load `android.lua`.
2. Check that `android/tts_helper.dex` exists in the plugin directory.
3. Resolve the app's cache directory via JNI (`Context.getCacheDir()`).
4. Enter a JNI context via `android.jni:context(vm, function(jni) ... end)`.
5. Get the activity's ClassLoader, create a `DexClassLoader` pointing to the
   `.dex` file, and load the `TtsHelper` class.
6. Instantiate `TtsHelper(Context)` passing the activity as Context.
7. Cache all `jmethodID` values for subsequent calls.
8. Promote the helper object and class to JNI GlobalRefs so they survive
   beyond the init JNI context.

**Method forwarding:** Each Lua method (`synthesizeToFile`, `setRate`,
`setPitch`, `playFile`, etc.) enters a JNI context, constructs Java
arguments, calls the cached method ID, checks for exceptions via
`ExceptionCheck`/`ExceptionDescribe`/`ExceptionClear`, and returns the result.

**Temp directory:** `getTempDir()` returns `<cache_dir>/audiobook/` on Android
instead of `/tmp` (which does not exist on Android).

### 4.3 Integration in ttsengine.lua

1. **detectBackend():** On Android, bundled binaries are skipped. After the
   system PATH search fails, the engine creates an `AndroidTts` instance, loads
   the `.dex`, waits up to 3 seconds for TTS init, and sets
   `self.backend = BACKENDS.ANDROID`. If init fails or the `.dex` is missing, a
   descriptive error message is shown.

2. **synthesizeCommand():** The `ANDROID` branch calls `synthesizeAndroid()`
   instead of building a shell command.

3. **synthesizeAndroid():** Forwards rate/pitch settings to the Android engine,
   dispatches `atts:synthesizeToFile(text, audio_file)`, then polls
   `atts:getSynthStatus()` via `UIManager:scheduleIn()` at 0.5s intervals
   (same async pattern as the Piper backend). Returns `nil` to signal
   async operation to the caller.

4. **Temp directory:** `synthesizeCommand()` and `espeakSynthesizeFallback()`
   use `self._android_tts:getTempDir()` when the Android backend is active,
   falling back to `/tmp` on other platforms.

5. **Audio playback:** `findAudioPlayer()` detects the Android backend and
   sets `audio_player_type = "android"`. The `play()` method dispatches to
   `playAndroid()` which calls `atts:playFile(path)` and polls for completion.
   Pause/resume calls `atts:pausePlayback()` / `atts:resumePlayback()` instead
   of SIGSTOP/SIGCONT.

### 4.4 Building the .dex

Prerequisites: Android SDK with build-tools (34.0.0+), platform (android-34+),
`ANDROID_HOME` environment variable, and Java 8+ (`javac`).

```bash
cd android/
./build-dex.sh
# Output: android/tts_helper.dex (~4KB)
```

### 4.5 Files

| File | Purpose |
|------|---------|
| `androidtts.lua` | Lua JNI bridge to TtsHelper |
| `android/TtsHelper.java` | Java helper: TextToSpeech + MediaPlayer |
| `android/build-dex.sh` | Build script producing tts_helper.dex |
| `ttsengine.lua` | Integration: detectBackend, synthesizeAndroid, play |

---

## 5. Limitations and Future Work

### 5.1 Limitations

- **Word-level timing:** Android TTS does not provide word-boundary callbacks
  in the `synthesizeToFile()` path. Timing is estimated using the same
  character-proportional heuristic as other backends, scaled to the real WAV
  duration.

- **Voice/language selection:** The plugin resolves the TTS language per
  chunk: an explicit override from Voice settings → "Android TTS language"
  wins; otherwise CJK text is detected by script (Han/kana/hangul byte
  ranges) and everything else falls back to the book's language metadata,
  then en-US. `setLanguage()` is only called when the language changes.
  There is still no UI for browsing installed TTS voices or engines; this
  can be added through `TextToSpeech.getVoices()`.

- **Init latency:** The Android TTS engine takes 100-500ms to initialize on
  first use. `detectBackend()` waits up to 3 seconds. Subsequent sentences
  have no init overhead.

- **No Piper/espeak-ng on Android:** The bundled Linux ARM binaries are
  incompatible with Bionic libc. Android TTS is the only backend unless CLI
  tools are installed via Termux.

### 5.2 Future Work

- **Upstream PR:** Contribute TTS JNI methods to android-luajit-launcher for a
  cleaner API that other KOReader plugins could use.

- **NDK espeak-ng:** Cross-compile espeak-ng for Android/Bionic, providing an
  alternative backend with phoneme-level timing accuracy.

- **Voice picker UI:** Query installed TTS engines and voices, present them in
  the plugin's settings menu.

---

## 6. References

- KOReader android-luajit-launcher: `LuaInterface.kt`, `android.lua`
- Android TextToSpeech API: `android.speech.tts.TextToSpeech`
- Android synthesizeToFile: `TextToSpeech.synthesizeToFile(CharSequence, Bundle, File, String)`
- Termux:API TextToSpeechAPI.java: calls `speak()` not `synthesizeToFile()`
- Plugin TTS pipeline: `ttsengine.lua` (synthesizeCommand, play, findAudioPlayer)
