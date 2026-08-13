package org.koreader.plugin.audiobook;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.media.AudioAttributes;
import android.media.AudioFocusRequest;
import android.media.AudioManager;
import android.media.MediaMetadata;
import android.media.session.MediaSession;
import android.media.session.PlaybackState;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.view.KeyEvent;

/**
 * Active MediaSession so Bluetooth headsets (AirPods stem, AVRCP) deliver
 * play/pause/next/prev to KOReader on Android.  Lua polls getPendingCommand()
 * — no JNI callbacks required.
 */
public class MediaSessionHelper {
    public static final int CMD_NONE = 0;
    public static final int CMD_PLAY_PAUSE = 1;
    public static final int CMD_PLAY = 2;
    public static final int CMD_PAUSE = 3;
    public static final int CMD_STOP = 4;
    public static final int CMD_NEXT = 5;
    public static final int CMD_PREV = 6;

    private final Context context;
    private final HandlerThread workerThread;
    private final Handler worker;
    private final Object lock = new Object();

    private MediaSession session;
    private AudioManager audioManager;
    private Object audioFocusRequest; // AudioFocusRequest on API 26+
    private volatile int pendingCommand = CMD_NONE;
    private volatile boolean active;
    private volatile int playbackState = PlaybackState.STATE_NONE;
    private volatile long positionMs;
    private volatile String title = "Audiobook";
    private volatile String artist = "";

    public MediaSessionHelper(Context context) {
        this.context = context.getApplicationContext();
        workerThread = new HandlerThread("abk-mediasession");
        workerThread.start();
        worker = new Handler(workerThread.getLooper());
        audioManager = (AudioManager) this.context.getSystemService(Context.AUDIO_SERVICE);
    }

    /** Activate the session (call when overlay/audiobook playback starts). */
    public void start(final String trackTitle, final String trackArtist) {
        if (trackTitle != null && trackTitle.length() > 0) title = trackTitle;
        if (trackArtist != null) artist = trackArtist;
        worker.post(new Runnable() {
            @Override
            public void run() {
                ensureSessionLocked();
                requestFocus();
                setStateInternal(PlaybackState.STATE_PLAYING, positionMs);
                active = true;
            }
        });
    }

    public void stop() {
        worker.post(new Runnable() {
            @Override
            public void run() {
                active = false;
                setStateInternal(PlaybackState.STATE_STOPPED, positionMs);
                abandonFocus();
                releaseSessionLocked();
            }
        });
    }

    public void setPlaying(final boolean playing, final long posMs) {
        positionMs = Math.max(0, posMs);
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (!active && session == null) return;
                ensureSessionLocked();
                setStateInternal(playing ? PlaybackState.STATE_PLAYING
                                         : PlaybackState.STATE_PAUSED, positionMs);
            }
        });
    }

    public void setMetadata(final String trackTitle, final String trackArtist) {
        if (trackTitle != null && trackTitle.length() > 0) title = trackTitle;
        if (trackArtist != null) artist = trackArtist;
        worker.post(new Runnable() {
            @Override
            public void run() {
                if (session == null) return;
                applyMetadataLocked();
            }
        });
    }

    /**
     * Atomically read-and-clear the next pending media-button command.
     * @return CMD_* constant
     */
    public int getPendingCommand() {
        synchronized (lock) {
            int c = pendingCommand;
            pendingCommand = CMD_NONE;
            return c;
        }
    }

    public void shutdown() {
        stop();
        worker.post(new Runnable() {
            @Override
            public void run() {
                releaseSessionLocked();
                try { workerThread.quitSafely(); } catch (Exception ignored) {}
            }
        });
    }

    private void enqueue(int cmd) {
        synchronized (lock) {
            pendingCommand = cmd;
        }
    }

    private void ensureSessionLocked() {
        if (session != null) return;
        session = new MediaSession(context, "audiobook.koplugin");
        session.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS
                | MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS);
        session.setCallback(new MediaSession.Callback() {
            @Override
            public void onPlay() { enqueue(CMD_PLAY); }

            @Override
            public void onPause() { enqueue(CMD_PAUSE); }

            @Override
            public void onStop() { enqueue(CMD_STOP); }

            @Override
            public void onSkipToNext() { enqueue(CMD_NEXT); }

            @Override
            public void onSkipToPrevious() { enqueue(CMD_PREV); }

            @Override
            public boolean onMediaButtonEvent(Intent intent) {
                if (intent == null) return super.onMediaButtonEvent(intent);
                KeyEvent ke = intent.getParcelableExtra(Intent.EXTRA_KEY_EVENT);
                if (ke == null || ke.getAction() != KeyEvent.ACTION_DOWN) {
                    return super.onMediaButtonEvent(intent);
                }
                switch (ke.getKeyCode()) {
                    case KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE:
                    case KeyEvent.KEYCODE_HEADSETHOOK:
                        enqueue(CMD_PLAY_PAUSE);
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_PLAY:
                        enqueue(CMD_PLAY);
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_PAUSE:
                        enqueue(CMD_PAUSE);
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_STOP:
                        enqueue(CMD_STOP);
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_NEXT:
                        enqueue(CMD_NEXT);
                        return true;
                    case KeyEvent.KEYCODE_MEDIA_PREVIOUS:
                        enqueue(CMD_PREV);
                        return true;
                    default:
                        return super.onMediaButtonEvent(intent);
                }
            }
        }, worker);

        // Media button receiver intent so the system can wake us.
        try {
            Intent mb = new Intent(Intent.ACTION_MEDIA_BUTTON);
            mb.setPackage(context.getPackageName());
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }
            PendingIntent pi = PendingIntent.getBroadcast(context, 0, mb, flags);
            session.setMediaButtonReceiver(pi);
        } catch (Exception ignored) {}

        applyMetadataLocked();
        session.setActive(true);
    }

    private void applyMetadataLocked() {
        if (session == null) return;
        MediaMetadata.Builder b = new MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, title)
            .putString(MediaMetadata.METADATA_KEY_ARTIST,
                (artist != null && artist.length() > 0) ? artist : "Audiobook Read-Along")
            .putString(MediaMetadata.METADATA_KEY_ALBUM, "KOReader");
        session.setMetadata(b.build());
    }

    private void setStateInternal(int state, long posMs) {
        playbackState = state;
        if (session == null) return;
        long actions = PlaybackState.ACTION_PLAY
                | PlaybackState.ACTION_PAUSE
                | PlaybackState.ACTION_PLAY_PAUSE
                | PlaybackState.ACTION_STOP
                | PlaybackState.ACTION_SKIP_TO_NEXT
                | PlaybackState.ACTION_SKIP_TO_PREVIOUS
                | PlaybackState.ACTION_SEEK_TO;
        PlaybackState.Builder b = new PlaybackState.Builder()
            .setActions(actions)
            .setState(state, Math.max(0, posMs),
                state == PlaybackState.STATE_PLAYING ? 1.0f : 0.0f);
        session.setPlaybackState(b.build());
        if (!session.isActive()) session.setActive(true);
    }

    private void releaseSessionLocked() {
        if (session != null) {
            try { session.setActive(false); } catch (Exception ignored) {}
            try { session.release(); } catch (Exception ignored) {}
            session = null;
        }
    }

    private void requestFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26) {
                AudioAttributes attrs = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build();
                AudioFocusRequest req = new AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                    .setAudioAttributes(attrs)
                    .setOnAudioFocusChangeListener(new AudioManager.OnAudioFocusChangeListener() {
                        @Override
                        public void onAudioFocusChange(int focusChange) {
                            if (focusChange == AudioManager.AUDIOFOCUS_LOSS
                                    || focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                                enqueue(CMD_PAUSE);
                            }
                        }
                    })
                    .build();
                audioFocusRequest = req;
                audioManager.requestAudioFocus(req);
            } else {
                audioManager.requestAudioFocus(
                    new AudioManager.OnAudioFocusChangeListener() {
                        @Override
                        public void onAudioFocusChange(int focusChange) {
                            if (focusChange == AudioManager.AUDIOFOCUS_LOSS
                                    || focusChange == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT) {
                                enqueue(CMD_PAUSE);
                            }
                        }
                    },
                    AudioManager.STREAM_MUSIC,
                    AudioManager.AUDIOFOCUS_GAIN);
            }
        } catch (Exception ignored) {}
    }

    private void abandonFocus() {
        if (audioManager == null) return;
        try {
            if (Build.VERSION.SDK_INT >= 26 && audioFocusRequest != null) {
                audioManager.abandonAudioFocusRequest((AudioFocusRequest) audioFocusRequest);
                audioFocusRequest = null;
            }
        } catch (Exception ignored) {}
    }
}
