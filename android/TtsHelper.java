package org.koreader.plugin.audiobook;

import android.content.Context;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;

import java.io.File;
import java.util.Locale;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * Minimal TTS helper for the KOReader audiobook plugin.
 *
 * Provides a polling-friendly API so Lua (via JNI) does not need to
 * implement Java callback interfaces.  All callbacks update volatile
 * status fields that Lua reads via getInitStatus() / getSynthStatus().
 *
 * Threading: ALL TextToSpeech and MediaPlayer calls run on a single
 * dedicated HandlerThread.  Neither the Android main thread (Lua JNI
 * calls) nor the TTS utterance callback thread ever touches the engine
 * or the media server directly:
 *
 *   - Binder calls into the TTS service (synthesizeToFile, stop,
 *     setLanguage, ...) block the caller when the engine process is
 *     wedged; on the main thread that hard-freezes KOReader (issue #44).
 *   - MediaPlayer create/prepare/start/stop block on the media server;
 *     running them inside the TTS callback can deadlock against the
 *     engine's own audio output (the original #44 freeze).
 *
 * JNI-facing methods therefore only post work to the worker thread and
 * update volatile status fields synchronously, so Lua's polling semantics
 * do not change.  The single worker also serializes engine operations,
 * which keeps stop-before-next-synthesis ordering for free.
 *
 * The one bounded exception is setLanguage(): its result code drives a
 * user-facing warning, so it waits on a latch with a 3 s cap.  A wedged
 * engine turns that into a 3 s stall plus a warning, never a freeze.
 */
public class TtsHelper implements TextToSpeech.OnInitListener {

    private TextToSpeech tts;
    private AudioManager audioManager;
    private final HandlerThread workerThread;
    private final Handler worker;

    /** -1 = pending, 0 = SUCCESS, non-zero = error */
    private volatile int initStatus = -1;

    /** -1 = idle, 0 = in progress, 1 = done OK, 2 = error */
    private volatile int synthStatus = -1;

    // --- Synth-then-play pipeline state ---
    /** Pipeline status: -1=idle, 0=synthesizing, 1=playing, 2=done OK, 3=error */
    private volatile int pipelineStatus = -1;
    private volatile int pipelineDurationMs = 0;
    private volatile boolean pipelineActive = false;
    private volatile String pendingPlayFile = null;
    /** File of the currently active pipeline; stale posted starts compare
     *  against it so a stop or a newer pipeline cancels them. */
    private volatile String pipelineFile = null;
    /** Monotonic generation; posted work captured under an older
     *  generation is dropped (a stop or a newer pipeline superseded it). */
    private volatile int pipelineGeneration = 0;
    /** Result of the most recent setLanguage() (TextToSpeech result code). */
    private volatile int lastLangResult = 0;
    /** Package name of the active TTS engine (e.g. com.google.android.tts).
     *  Filled on the worker thread after init; never queried from the main
     *  thread because getDefaultEngine() is a binder call. */
    private volatile String defaultEnginePackage = null;

    public TtsHelper(Context context) {
        workerThread = new HandlerThread("audiobook-tts");
        workerThread.start();
        worker = new Handler(workerThread.getLooper());
        tts = new TextToSpeech(context, this);
        audioManager = (AudioManager) context.getSystemService(Context.AUDIO_SERVICE);
    }

    @Override
    public void onInit(int status) {
        initStatus = status;
        if (status == TextToSpeech.SUCCESS) {
            tts.setLanguage(Locale.US);
            tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {                @Override
                public void onStart(String utteranceId) {}

                @Override
                public void onDone(String utteranceId) {
                    synthStatus = 1;
                    // Pipeline mode: auto-start playback when synthesis finishes.
                    // This callback runs on a TTS engine thread; never do
                    // media work here, just hand the file to the worker.
                    if (pipelineActive && pendingPlayFile != null) {
                        final String path = pendingPlayFile;
                        pendingPlayFile = null;
                        worker.post(new Runnable() {
                            @Override
                            public void run() {
                                // A stopPipeline() or a newer pipeline may
                                // have been dispatched after this was posted.
                                if (!pipelineActive || !path.equals(pipelineFile)) {
                                    return;
                                }
                                int dur = startPlayback(path, speechAttributes());
                                if (dur >= 0) {
                                    pipelineDurationMs = dur;
                                    pipelineStatus = 1;  // playing
                                } else {
                                    pipelineStatus = 3;  // error
                                    pipelineActive = false;
                                }
                            }
                        });
                    }
                }

                @Override
                public void onError(String utteranceId) {
                    synthStatus = 2;
                    if (pipelineActive) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                        pendingPlayFile = null;
                    }
                }
            });
            // Identify the active engine on the worker thread: getDefaultEngine()
            // is a binder call and must not run on the main thread.
            worker.post(new Runnable() {
                @Override
                public void run() {
                    try {
                        String pkg = tts.getDefaultEngine();
                        defaultEnginePackage = (pkg != null) ? pkg : "unknown";
                    } catch (Exception e) {
                        defaultEnginePackage = "unknown";
                    }
                }
            });
        }
    }

    /** Returns -1 while TTS engine is loading, 0 on success, >0 on error. */
    public int getInitStatus() {
        return initStatus;
    }

    /**
     * Package name of the active TTS engine (e.g. "com.google.android.tts").
     * Main-thread safe: returns a cached value, never calls into the TTS
     * service.  "pending" until the worker thread fills it after init,
     * "not_ready" if the engine never initialized.
     */
    public String getDefaultEngine() {
        if (defaultEnginePackage != null) {
            return defaultEnginePackage;
        }
        return (initStatus == TextToSpeech.SUCCESS) ? "pending" : "not_ready";
    }

    /**
     * Start async synthesis to a WAV file.
     * The engine call happens on the worker thread; returns 0 when the
     * request was dispatched, -1 if TTS not ready.  Completion is reported
     * through getSynthStatus().
     */
    public int synthesizeToFile(final String text, final String filePath) {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) {
            return -1;
        }
        synthStatus = 0;
        worker.post(new Runnable() {
            @Override
            public void run() {
                File file = new File(filePath);
                File parent = file.getParentFile();
                if (parent != null && !parent.exists()) {
                    parent.mkdirs();
                }
                try {
                    // Unique utterance ID per call so the engine treats each
                    // request as distinct (some engines ignore onDone for
                    // reused IDs).
                    String uttId = "audiobook_" + System.currentTimeMillis();
                    int result = tts.synthesizeToFile(text, new Bundle(), file, uttId);
                    if (result != TextToSpeech.SUCCESS) {
                        synthStatus = 2;
                    }
                } catch (Exception e) {
                    synthStatus = 2;
                }
            }
        });
        return 0;
    }

    /** Returns -1 idle, 0 in-progress, 1 done, 2 error. */
    public int getSynthStatus() {
        return synthStatus;
    }

    /** Set speech rate (1.0 = normal). */
    public void setRate(final float rate) {
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (tts != null) {
                    try { tts.setSpeechRate(rate); } catch (Exception ignored) {}
                }
            }
        });
    }

    /** Set pitch (1.0 = normal). */
    public void setPitch(final float pitch) {
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (tts != null) {
                    try { tts.setPitch(pitch); } catch (Exception ignored) {}
                }
            }
        });
    }

    /**
     * Set language by BCP-47 tag (e.g. "en-US").
     * Runs on the worker thread; the caller waits on a latch with a 3 s
     * cap because the result code drives a user-facing warning.  Returns
     * the TextToSpeech result code, or -1 on error/timeout.
     */
    public int setLanguage(String bcp47) {
        if (tts == null) return -1;
        final Locale locale = Locale.forLanguageTag(bcp47);
        final CountDownLatch latch = new CountDownLatch(1);
        worker.post(new Runnable() {
            @Override
            public void run() {
                int result = -1;
                try {
                    if (tts != null) {
                        result = tts.setLanguage(locale);
                    }
                } catch (Exception ignored) {}
                lastLangResult = result;
                latch.countDown();
            }
        });
        try {
            if (latch.await(3, TimeUnit.SECONDS)) {
                return lastLangResult;
            }
        } catch (InterruptedException ignored) {}
        return -1;
    }

    /** Release the TTS engine (posted; the caller never blocks). */
    public void shutdown() {
        stopPipeline();
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (tts != null) {
                    try { tts.stop(); } catch (Exception ignored) {}
                    try { tts.shutdown(); } catch (Exception ignored) {}
                    tts = null;
                }
                // Drain pending work, then stop the thread.
                workerThread.quitSafely();
            }
        });
    }

    // --- Audio focus ---

    /** Speech attributes for short TTS clips (synth-then-play pipeline). */
    private static AudioAttributes speechAttributes() {
        return new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_ACCESSIBILITY)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build();
    }

    /** Music/media attributes for pre-recorded audiobook chapters (EPUB overlay). */
    private static AudioAttributes mediaAttributes() {
        return new AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build();
    }

    /** Kept as Object so the class still loads on API < 26 where
     *  AudioFocusRequest does not exist. */
    private Object audioFocusRequest = null;

    @SuppressWarnings("deprecation")
    private void requestAudioFocus(AudioAttributes attrs) {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                AudioFocusRequest req = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs != null ? attrs : speechAttributes())
                    .build();
                audioFocusRequest = req;
                audioManager.requestAudioFocus(req);
            } else {
                audioManager.requestAudioFocus(null,
                    AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN);
            }
        } catch (Exception ignored) {}
    }

    @SuppressWarnings("deprecation")
    private void abandonAudioFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26 && audioFocusRequest != null) {
                audioManager.abandonAudioFocusRequest((AudioFocusRequest) audioFocusRequest);
                audioFocusRequest = null;
            } else {
                audioManager.abandonAudioFocus(null);
            }
        } catch (Exception ignored) {}
    }

    // --- Synth-then-play pipeline ---

    /**
     * Start a combined synthesize-then-play pipeline.
     * All engine work happens on the worker thread; this method only
     * updates volatile state and posts.  Returns 0 when dispatched, -1 if
     * TTS not ready.  Progress is reported through getPipelineStatus().
     */
    public int synthesizeAndPlay(final String text, final String filePath) {
        if (tts == null || initStatus != TextToSpeech.SUCCESS) return -1;

        // Cancel the current pipeline (state only; engine stop is posted).
        stopPipeline();

        final int gen = ++pipelineGeneration;
        pipelineActive = true;
        pipelineStatus = 0;  // synthesizing
        pipelineDurationMs = 0;
        pendingPlayFile = filePath;
        pipelineFile = filePath;
        synthStatus = 0;

        worker.post(new Runnable() {
            @Override
            public void run() {
                if (gen != pipelineGeneration) return;  // superseded by stop/newer
                // Engine-side stop of whatever the previous pipeline was
                // doing, then dispatch this synthesis.
                try { if (tts != null) tts.stop(); } catch (Exception ignored) {}

                File file = new File(filePath);
                File parent = file.getParentFile();
                if (parent != null && !parent.exists()) parent.mkdirs();

                try {
                    String uttId = "pipeline_" + System.currentTimeMillis();
                    int result = tts.synthesizeToFile(text, new Bundle(), file, uttId);
                    if (result != TextToSpeech.SUCCESS && gen == pipelineGeneration) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                        pendingPlayFile = null;
                        pipelineFile = null;
                    }
                } catch (Exception e) {
                    if (gen == pipelineGeneration) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                        pendingPlayFile = null;
                        pipelineFile = null;
                    }
                }
            }
        });
        return 0;
    }

    /** Pipeline status: -1=idle, 0=synthesizing, 1=playing, 2=done OK, 3=error. */
    public int getPipelineStatus() {
        return pipelineStatus;
    }

    /** Playback duration in ms (available once pipeline reaches status 1). */
    public int getPipelineDurationMs() {
        return pipelineDurationMs;
    }

    /** Cancel the pipeline (synthesis and/or playback) and release audio focus. */
    public void stopPipeline() {
        pipelineGeneration++;
        pendingPlayFile = null;
        pipelineFile = null;
        boolean wasSynthesizing = pipelineActive && pipelineStatus == 0;
        pipelineActive = false;
        pipelineStatus = -1;
        pipelineDurationMs = 0;
        if (wasSynthesizing && tts != null) {
            worker.post(new Runnable() {
                @Override
                public void run() {
                    try { if (tts != null) tts.stop(); } catch (Exception ignored) {}
                }
            });
        }
        stopPlayback();
    }

    // --- Audio playback via MediaPlayer ---

    private final Object mpLock = new Object();
    private MediaPlayer mediaPlayer;
    private volatile boolean playbackDone = false;
    /** Set after start() succeeds, cleared on completion/error/stop.  Read
     *  by isPlaying() on the JNI calling thread; keeps that path free of
     *  locks and binder calls (issue #44). */
    private volatile boolean playbackActive = false;

    /**
     * Play a WAV file through the speech audio output.
     * If a pipeline is active, it is cancelled first (direct playFile
     * implies the caller is bypassing the pipeline).
     * Returns 0 when dispatched, or -1 if playback is impossible.
     *
     * NOTE: legacy direct API, not used by the synth-then-play pipeline.
     * startPlayback() runs on the worker thread so the caller (Lua main
     * thread via JNI) never blocks in media-server binder calls (issue #44).
     */
    public int playFile(final String path) {
        return playFileWithAttributes(path, speechAttributes());
    }

    /**
     * Play a pre-recorded audiobook file (mp3/m4b/…) through the media stream.
     * Use this for EPUB Media Overlay chapters; short TTS clips use playFile().
     */
    public int playMediaFile(final String path) {
        return playFileWithAttributes(path, mediaAttributes());
    }

    private int playFileWithAttributes(final String path, final AudioAttributes attrs) {
        if (pipelineActive) {
            pipelineActive = false;
            pipelineStatus = -1;
            pipelineDurationMs = 0;
            pendingPlayFile = null;
        }
        worker.post(new Runnable() {
            @Override
            public void run() {
                startPlayback(path, attrs);
            }
        });
        return 0;
    }

    /**
     * Internal: start MediaPlayer on a file.  Runs on the worker thread.
     */
    private int startPlayback(String path, AudioAttributes attrs) {
        stopPlaybackInternal();
        playbackDone = false;
        playbackActive = false;
        if (attrs == null) attrs = speechAttributes();
        requestAudioFocus(attrs);
        synchronized (mpLock) {
            try {
                mediaPlayer = new MediaPlayer();
                mediaPlayer.setAudioAttributes(attrs);
                mediaPlayer.setDataSource(path);
                mediaPlayer.setOnCompletionListener(mp -> {
                    playbackDone = true;
                    playbackActive = false;
                    if (pipelineActive) {
                        pipelineStatus = 2;
                        pipelineActive = false;
                    }
                    abandonAudioFocus();
                });
                mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                    playbackDone = true;
                    playbackActive = false;
                    if (pipelineActive) {
                        pipelineStatus = 3;
                        pipelineActive = false;
                    }
                    abandonAudioFocus();
                    return true;
                });
                mediaPlayer.prepare();
                mediaPlayer.start();
                playbackActive = true;
                return mediaPlayer.getDuration();
            } catch (Exception e) {
                playbackDone = true;
                playbackActive = false;
                if (pipelineActive) {
                    pipelineStatus = 3;
                    pipelineActive = false;
                }
                abandonAudioFocus();
                if (mediaPlayer != null) {
                    try { mediaPlayer.release(); } catch (Exception ignored) {}
                    mediaPlayer = null;
                }
                return -1;
            }
        }
    }

    /**
     * Check if audio is still playing.  Volatile flag only: never lock and
     * never call MediaPlayer.isPlaying() here -- this runs on the Lua main
     * thread via JNI, and both the lock (held by the worker across blocking
     * media-server calls in startPlayback) and the binder call itself can
     * freeze the whole app when the media server wedges (issue #44).
     */
    public boolean isPlaying() {
        return playbackActive;
    }

    /** Check if playback finished (completed or error). */
    public boolean isPlaybackDone() {
        return playbackDone;
    }

    /**
     * Stop and release the MediaPlayer (JNI entry point).
     * Only posts to the worker thread; the main thread must never block
     * in MediaPlayer calls (issue #44).
     */
    public void stopPlayback() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                stopPlaybackInternal();
            }
        });
    }

    /** Stop and release the MediaPlayer.  Runs on the worker thread. */
    private void stopPlaybackInternal() {
        synchronized (mpLock) {
            if (mediaPlayer != null) {
                // Clear listeners BEFORE release to prevent callbacks from
                // firing on the internal thread after the native object is
                // destroyed (causes pthread_mutex_lock on destroyed mutex).
                mediaPlayer.setOnCompletionListener(null);
                mediaPlayer.setOnErrorListener(null);
                try {
                    if (mediaPlayer.isPlaying()) {
                        mediaPlayer.stop();
                    }
                } catch (IllegalStateException ignored) {}
                try {
                    mediaPlayer.release();
                } catch (Exception ignored) {}
                mediaPlayer = null;
            }
            playbackDone = false;
            playbackActive = false;
        }
        abandonAudioFocus();
    }

    /** Pause audio playback (JNI entry point: posted, never blocks). */
    public void pausePlayback() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                synchronized (mpLock) {
                    try {
                        if (mediaPlayer != null && playbackActive) {
                            mediaPlayer.pause();
                            playbackActive = false;
                        }
                    } catch (IllegalStateException ignored) {}
                }
            }
        });
    }

    /** Resume audio playback after pause (JNI entry point: posted). */
    public void resumePlayback() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                synchronized (mpLock) {
                    try {
                        if (mediaPlayer != null && !playbackActive) {
                            mediaPlayer.start();
                            playbackActive = true;
                        }
                    } catch (IllegalStateException ignored) {}
                }
            }
        });
    }

    /**
     * Seek the active MediaPlayer (JNI entry point: posted, never blocks).
     * Used by EPUB Media Overlay read-aloud on Android (Boox, etc.).
     */
    public void seekToMs(final int msec) {
        worker.post(new Runnable() {
            @Override
            public void run() {
                synchronized (mpLock) {
                    try {
                        if (mediaPlayer != null) {
                            mediaPlayer.seekTo(Math.max(0, msec));
                        }
                    } catch (Exception ignored) {}
                }
            }
        });
    }
}
