/*
 * wav-play: Minimal WAV file player using ALSA.
 * Bundled with audiobook.koplugin for devices that have an ALSA soundcard
 * and libasound but no aplay binary (e.g. PocketBook).
 *
 * Saves hw:0 playback switch state, unmutes all playback switches, and
 * raises volume to 50% if at zero before playback.  Restores the original
 * switch state after snd_pcm_drain().  On PocketBook, active switches trigger
 * the audio daemon to drain the tts_sm -> Loopback ring buffer; with them
 * muted the daemon stops consuming, the buffer fills, and snd_pcm_writei()
 * blocks, freezing KOReader.  The unmuting MUST happen before snd_pcm_open()
 * so the daemon is already draining by the time data reaches the Loopback.
 * Saving and restoring avoids persistent ALSA state corruption on devices
 * like PB700C where the firmware intentionally leaves amplifier paths
 * disabled.
 *
 * Supports -q (quiet), -D <device> (ALSA PCM device name),
 * --no-mixer (skip hw:0 mixer setup/restore).
 * --rate <Hz> / --channels <N>: convert 16-bit PCM in software before
 * playback (linear resample, mono<->stereo).  Used as a fallback on
 * devices whose ALSA chain is fixed to one configuration and crashes
 * during plug negotiation (PocketBook tts_sm -> softvol -> plug -> dmix
 * chains can die on "Assertion `!snd_interval_empty(i)' failed" when the
 * nested plug wrappers try to refine an unsupported rate).
 * Uses only ALSA 0.9.x-era functions for maximum compatibility.
 *
 * Build: $CC -O2 -o wav-play wav-play.c -lasound
 * Cross: armv7l-unknown-linux-gnueabihf-gcc -O2 -o wav-play wav-play.c -lasound
 */
#include <alsa/asoundlib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* Saved playback switch + volume states -- restored after snd_pcm_drain() */
#define MAX_SWITCH_SAVES 32
#define NAME_BUF 64
struct switch_save {
    char name[NAME_BUF];
    int  val;          /* playback switch state (0=muted, 1=unmuted) */
    long volume;       /* playback volume level */
    int  had_volume;   /* 1 if element has a volume control */
    int  changed_vol;  /* 1 if we raised volume from zero */
};
static struct switch_save g_saved_sw[MAX_SWITCH_SAVES];
static int                g_saved_sw_count = 0;
static char               g_mixer_card[32] = "";

/*
 * Saves playback switch state, unmutes all playback switches, and nudges
 * volume to 50% if at zero.  Call restore_mixer_switches() after
 * snd_pcm_drain() to put switches back to their original state.
 *
 * On PocketBook, playback switches must be active for the audio daemon to
 * drain the tts_sm -> Loopback pipeline.  With switches muted the daemon
 * stops consuming the ring buffer, snd_pcm_writei() blocks indefinitely,
 * and KOReader freezes.  Saving and restoring the original state prevents
 * persistent ALSA corruption on devices like PB700C where the firmware
 * intentionally leaves amplifier paths disabled.
 */
static void setup_mixer(const char *card, int quiet)
{
    g_saved_sw_count = 0;
    strncpy(g_mixer_card, card, sizeof(g_mixer_card) - 1);
    g_mixer_card[sizeof(g_mixer_card) - 1] = '\0';

    snd_mixer_t *mixer = NULL;
    if (snd_mixer_open(&mixer, 0) < 0)
        return;
    if (snd_mixer_attach(mixer, card) < 0) {
        snd_mixer_close(mixer);
        return;
    }
    snd_mixer_selem_register(mixer, NULL, NULL);
    snd_mixer_load(mixer);

    snd_mixer_elem_t *elem;
    for (elem = snd_mixer_first_elem(mixer); elem;
         elem = snd_mixer_elem_next(elem)) {
        if (!snd_mixer_selem_is_active(elem))
            continue;

        /* Save and unmute playback switches so the PocketBook audio daemon
         * will drain the Loopback ring buffer.  We only save elements that
         * are currently muted (those are the ones we change). */
        if (snd_mixer_selem_has_playback_switch(elem)
                && g_saved_sw_count < MAX_SWITCH_SAVES) {
            int idx = g_saved_sw_count;
            const char *ename = snd_mixer_selem_get_name(elem);
            strncpy(g_saved_sw[idx].name, ename, NAME_BUF - 1);
            g_saved_sw[idx].name[NAME_BUF - 1] = '\0';

            int curval = 1;
            snd_mixer_selem_get_playback_switch(elem,
                    SND_MIXER_SCHN_FRONT_LEFT, &curval);
            g_saved_sw[idx].val = curval;

            /* Save volume level so we can restore it exactly. */
            g_saved_sw[idx].had_volume = 0;
            g_saved_sw[idx].changed_vol = 0;
            if (snd_mixer_selem_has_playback_volume(elem)) {
                long vmin, vmax, cur;
                snd_mixer_selem_get_playback_volume_range(elem, &vmin, &vmax);
                snd_mixer_selem_get_playback_volume(elem,
                        SND_MIXER_SCHN_FRONT_LEFT, &cur);
                g_saved_sw[idx].had_volume = 1;
                g_saved_sw[idx].volume = cur;
                /* Raise volume only when at zero; cap at 50%. */
                if (cur <= vmin) {
                    long target = vmin + (vmax - vmin) / 2;
                    snd_mixer_selem_set_playback_volume_all(elem, target);
                    g_saved_sw[idx].changed_vol = 1;
                }
            }

            /* Unmute if muted. */
            if (!curval)
                snd_mixer_selem_set_playback_switch_all(elem, 1);

            g_saved_sw_count++;
        }
    }

    snd_mixer_close(mixer);
    if (!quiet)
        fprintf(stderr, "wav-play: mixer initialized on %s\n", card);
}

/*
 * Restore playback switch states saved by setup_mixer().  Call this after
 * snd_pcm_drain() so the audio daemon has fully consumed the ring buffer
 * before we re-mute the amplifier paths.
 */
static void restore_mixer_switches(int quiet)
{
    if (g_saved_sw_count == 0 || g_mixer_card[0] == '\0')
        return;
    snd_mixer_t *mixer = NULL;
    if (snd_mixer_open(&mixer, 0) < 0)
        return;
    if (snd_mixer_attach(mixer, g_mixer_card) < 0) {
        snd_mixer_close(mixer);
        return;
    }
    snd_mixer_selem_register(mixer, NULL, NULL);
    snd_mixer_load(mixer);

    for (int i = 0; i < g_saved_sw_count; i++) {
        snd_mixer_elem_t *elem;
        for (elem = snd_mixer_first_elem(mixer); elem;
             elem = snd_mixer_elem_next(elem)) {
            if (!snd_mixer_selem_has_playback_switch(elem))
                continue;
            if (strcmp(snd_mixer_selem_get_name(elem),
                       g_saved_sw[i].name) == 0) {
                snd_mixer_selem_set_playback_switch_all(elem,
                        g_saved_sw[i].val);
                /* Restore volume if we changed it. */
                if (g_saved_sw[i].had_volume && g_saved_sw[i].changed_vol)
                    snd_mixer_selem_set_playback_volume_all(elem,
                            g_saved_sw[i].volume);
                break;
            }
        }
    }
    snd_mixer_close(mixer);
    if (!quiet)
        fprintf(stderr, "wav-play: mixer switches restored on %s\n",
                g_mixer_card);
}

/* Minimal WAV header (PCM format only) */
struct wav_header {
    char     riff_id[4];      /* "RIFF" */
    uint32_t file_size;
    char     wave_id[4];      /* "WAVE" */
    char     fmt_id[4];       /* "fmt " */
    uint32_t fmt_size;
    uint16_t audio_format;    /* 1 = PCM */
    uint16_t channels;
    uint32_t sample_rate;
    uint32_t byte_rate;
    uint16_t block_align;
    uint16_t bits_per_sample;
};

int main(int argc, char **argv)
{
    const char *device   = "default";
    const char *filename = NULL;
    int quiet = 0;
    int no_mixer = 0;
    unsigned force_rate = 0;     /* --rate: software-resample target */
    unsigned force_channels = 0; /* --channels: software-convert target */

    /* Parse arguments (aplay-compatible subset) */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-D") == 0 && i + 1 < argc)
            device = argv[++i];
        else if (strcmp(argv[i], "-q") == 0)
            quiet = 1;
        else if (strcmp(argv[i], "--no-mixer") == 0)
            no_mixer = 1;
        else if (strcmp(argv[i], "--rate") == 0 && i + 1 < argc)
            force_rate = (unsigned)atoi(argv[++i]);
        else if (strcmp(argv[i], "--channels") == 0 && i + 1 < argc)
            force_channels = (unsigned)atoi(argv[++i]);
        else if (argv[i][0] != '-')
            filename = argv[i];
    }

    if (!filename) {
        fprintf(stderr, "Usage: wav-play [-q] [--no-mixer] [-D device] file.wav\n");
        return 1;
    }

    FILE *f = fopen(filename, "rb");
    if (!f) {
        if (!quiet) fprintf(stderr, "wav-play: cannot open %s\n", filename);
        return 1;
    }

    /* Read and validate WAV header */
    struct wav_header hdr;
    if (fread(&hdr, sizeof(hdr), 1, f) != 1
        || memcmp(hdr.riff_id, "RIFF", 4) != 0
        || memcmp(hdr.wave_id, "WAVE", 4) != 0) {
        if (!quiet) fprintf(stderr, "wav-play: not a valid WAV file\n");
        fclose(f);
        return 1;
    }

    if (hdr.audio_format != 1) {
        if (!quiet) fprintf(stderr, "wav-play: only PCM format supported\n");
        fclose(f);
        return 1;
    }

    /* Skip past fmt chunk and any extra chunks to find "data" */
    long data_offset = 12 + 8 + hdr.fmt_size;  /* RIFF header + fmt chunk */
    fseek(f, data_offset, SEEK_SET);

    char     chunk_id[4];
    uint32_t chunk_size = 0;
    while (fread(chunk_id, 4, 1, f) == 1 && fread(&chunk_size, 4, 1, f) == 1) {
        if (memcmp(chunk_id, "data", 4) == 0)
            break;
        fseek(f, chunk_size, SEEK_CUR);
        chunk_size = 0;
    }
    if (chunk_size == 0) {
        if (!quiet) fprintf(stderr, "wav-play: no data chunk found\n");
        fclose(f);
        return 1;
    }

    /* Map bit depth to ALSA format */
    snd_pcm_format_t format;
    switch (hdr.bits_per_sample) {
    case 8:  format = SND_PCM_FORMAT_U8;     break;
    case 16: format = SND_PCM_FORMAT_S16_LE; break;
    case 24: format = SND_PCM_FORMAT_S24_3LE; break;
    case 32: format = SND_PCM_FORMAT_S32_LE; break;
    default:
        if (!quiet) fprintf(stderr, "wav-play: unsupported bit depth %d\n",
                            hdr.bits_per_sample);
        fclose(f);
        return 1;
    }

    /* Effective stream parameters: normally the WAV's own, but --rate /
     * --channels force software conversion (see header comment).  Converting
     * to the chain's native config lets us request exactly the supported
     * parameters, which avoids the nested-plug refinement crash on
     * PocketBook's tts_sm chain (alsa-lib assertion on empty interval). */
    unsigned eff_rate = hdr.sample_rate;
    unsigned eff_channels = hdr.channels;
    unsigned eff_bits = hdr.bits_per_sample;
    snd_pcm_format_t eff_format = format;
    int16_t *conv_buf = NULL;   /* converted PCM, when converting */
    uint32_t conv_frames = 0;

    int need_convert = (force_rate > 0 && force_rate != hdr.sample_rate)
                    || (force_channels > 0 && force_channels != hdr.channels);
    if (need_convert) {
        if (hdr.bits_per_sample != 16) {
            if (!quiet)
                fprintf(stderr, "wav-play: --rate/--channels conversion supports only 16-bit PCM\n");
            fclose(f);
            return 3;
        }
        eff_rate = force_rate > 0 ? force_rate : hdr.sample_rate;
        eff_channels = force_channels > 0 ? force_channels : hdr.channels;
        eff_format = SND_PCM_FORMAT_S16_LE;
        eff_bits = 16;

        uint32_t in_frames = chunk_size / (hdr.channels * 2);
        int16_t *in = malloc(chunk_size > 0 ? chunk_size : 2);
        if (!in) { fclose(f); return 1; }
        if (fread(in, 2, (size_t)in_frames * hdr.channels, f)
                != (size_t)in_frames * hdr.channels) {
            if (!quiet) fprintf(stderr, "wav-play: short read for conversion\n");
            free(in);
            fclose(f);
            return 1;
        }

        /* Channel conversion first (mono<->stereo, generic N->M fallback) */
        const int16_t *ch_src = in;
        int16_t *ch_buf = NULL;
        if (eff_channels != hdr.channels) {
            ch_buf = malloc((size_t)in_frames * eff_channels * 2);
            if (!ch_buf) { free(in); fclose(f); return 1; }
            for (uint32_t i = 0; i < in_frames; i++) {
                if (hdr.channels == 1 && eff_channels == 2) {
                    ch_buf[2*i] = ch_buf[2*i+1] = in[i];
                } else if (hdr.channels == 2 && eff_channels == 1) {
                    ch_buf[i] = (int16_t)(((int)in[2*i] + (int)in[2*i+1]) / 2);
                } else {
                    for (unsigned c = 0; c < eff_channels; c++)
                        ch_buf[i*eff_channels+c] =
                            c < hdr.channels ? in[i*hdr.channels+c] : 0;
                }
            }
            ch_src = ch_buf;
        }

        /* Linear resample (per channel, fixed-point position) */
        if (eff_rate != hdr.sample_rate) {
            conv_frames = (uint32_t)(((uint64_t)in_frames * eff_rate) / hdr.sample_rate);
            conv_buf = malloc((size_t)conv_frames * eff_channels * 2);
            if (!conv_buf) { free(ch_buf); free(in); fclose(f); return 1; }
            for (uint32_t i = 0; i < conv_frames; i++) {
                uint64_t pos = (uint64_t)i * hdr.sample_rate;
                uint32_t i0 = (uint32_t)(pos / eff_rate);
                uint32_t frac = (uint32_t)(pos % eff_rate);
                uint32_t i1 = (i0 + 1 < in_frames) ? i0 + 1 : in_frames - 1;
                for (unsigned c = 0; c < eff_channels; c++) {
                    int a = ch_src[i0*eff_channels + c];
                    int b = ch_src[i1*eff_channels + c];
                    conv_buf[i*eff_channels + c] =
                        (int16_t)(a + (int)(((int64_t)(b - a) * frac) / (int)eff_rate));
                }
            }
            free(ch_buf);
            free(in);
        } else {
            /* Rate unchanged: channel conversion only (or straight copy) */
            conv_frames = in_frames;
            conv_buf = ch_buf ? ch_buf : in;
        }
        if (!quiet)
            fprintf(stderr, "wav-play: software conversion: %u Hz/%uch -> %u Hz/%uch\n",
                    hdr.sample_rate, hdr.channels, eff_rate, eff_channels);
    }

    /* Save hw:0 switch state, unmute switches, raise volume from zero.
     * This MUST run before snd_pcm_open(): on PocketBook the audio daemon
     * only starts draining the tts_sm -> Loopback ring buffer when hw:0
     * switches are already unmuted at the time the PCM device is opened.
     * restore_mixer_switches() is called after snd_pcm_drain().
     *
     * --no-mixer skips this entirely.  When routing through tts_sm the
     * PocketBook audio daemon manages hw:0 natively.  Touching the mixer
     * corrupts the amplifier state on PB700c, killing the speaker
     * system-wide until reboot. */
    if (!no_mixer) {
        setup_mixer("hw:0", quiet);
        usleep(50000);  /* 50 ms -- let audio daemon react to switch change */
    }

    /*
     * Device selection strategy:
     *
     * When a specific device is given via -D (not "default"), use ONLY
     * that device: try plug:<device> first (for automatic sample rate
     * and format conversion), then the raw device.  Never fall through
     * to other devices.  This prevents bypassing the PocketBook audio
     * pipeline (tts_sm -> softvol -> dmix -> Loopback) by accidentally
     * falling through to plughw:0 or hw:0 which write directly to the
     * hardware CODEC, causing clicking, inaudible audio, and persistent
     * audio state corruption.
     *
     * When device is "default", use a fallback chain:
     * default -> tts_sm -> plughw:0.  hw:0 is intentionally excluded
     * because direct hardware access bypasses PocketBook audio routing.
     */
    int strict_device = (strcmp(device, "default") != 0);
    snd_pcm_t *pcm = NULL;
    int err = -1;
    const char *opened_device = device;
    /* Static buffer for plug:<device> name (device is at most ~64 chars) */
    static char plug_buf[128];

    if (strict_device) {
        /* Try plug:<device> first for automatic rate/format conversion. */
        snprintf(plug_buf, sizeof(plug_buf), "plug:%s", device);
        err = snd_pcm_open(&pcm, plug_buf, SND_PCM_STREAM_PLAYBACK, 0);
        if (err >= 0) {
            opened_device = plug_buf;
            if (!quiet)
                fprintf(stderr, "wav-play: opened '%s' (plug wrapper)\n",
                        opened_device);
        } else {
            if (!quiet)
                fprintf(stderr, "wav-play: plug wrapper '%s' failed: %s\n",
                        plug_buf, snd_strerror(err));
            /* Fall back to raw device (no format conversion). */
            err = snd_pcm_open(&pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
            if (err >= 0) {
                opened_device = device;
            } else {
                if (!quiet)
                    fprintf(stderr, "wav-play: cannot open '%s': %s\n",
                            device, snd_strerror(err));
            }
        }
    } else {
        /* Fallback chain for "default".  hw:0 is excluded to prevent
         * bypassing PocketBook audio routing. */
        const char *try_devices[] = { device, "tts_sm", "plughw:0", NULL };
        for (int i = 0; try_devices[i]; i++) {
            if (i > 0 && strcmp(try_devices[i], device) == 0)
                continue;   /* skip duplicate */
            err = snd_pcm_open(&pcm, try_devices[i], SND_PCM_STREAM_PLAYBACK, 0);
            if (err >= 0) {
                opened_device = try_devices[i];
                if (i > 0 && !quiet)
                    fprintf(stderr, "wav-play: '%s' failed, using fallback '%s'\n",
                            device, opened_device);
                break;
            }
            if (!quiet)
                fprintf(stderr, "wav-play: cannot open '%s': %s (trying next)\n",
                        try_devices[i], snd_strerror(err));
        }
    }
    if (err < 0) {
        if (!quiet) fprintf(stderr, "wav-play: all devices failed\n");
        restore_mixer_switches(quiet);
        fclose(f);
        return 1;
    }

    /* If we fell back to a different device, log it for diagnostics */
    if (strcmp(opened_device, device) != 0 && !quiet)
        fprintf(stderr, "wav-play: using '%s' instead of '%s'\n",
                opened_device, device);

    /* Configure hardware params */
    snd_pcm_hw_params_t *params;
    snd_pcm_hw_params_alloca(&params);
    snd_pcm_hw_params_any(pcm, params);
    snd_pcm_hw_params_set_access(pcm, params, SND_PCM_ACCESS_RW_INTERLEAVED);
    snd_pcm_hw_params_set_format(pcm, params, eff_format);
    snd_pcm_hw_params_set_channels(pcm, params, eff_channels);

    unsigned int rate = eff_rate;
    snd_pcm_hw_params_set_rate_near(pcm, params, &rate, NULL);

    if (rate != eff_rate) {
        fprintf(stderr, "wav-play: rate mismatch on '%s': requested %u Hz, got %u Hz\n",
                opened_device, eff_rate, rate);

        if (strict_device) {
            /* In strict mode, the raw device does not support the WAV's
             * sample rate.  If we opened the raw device (plug: wrapper
             * failed earlier), try plug: one more time on the currently
             * opened device.  The first plug: attempt may have targeted
             * a different device name variation.
             *
             * If plug: is unavailable or also mismatches, proceed with
             * the nearest rate and warn.  Audio will play at the wrong
             * speed but this is better than falling through to hw:0
             * which corrupts PocketBook audio state. */
            if (strncmp(opened_device, "plug:", 5) != 0) {
                /* The plug: wrapper was not used; retry with plug: */
                snd_pcm_close(pcm);
                pcm = NULL;
                snprintf(plug_buf, sizeof(plug_buf), "plug:%s", device);
                err = snd_pcm_open(&pcm, plug_buf, SND_PCM_STREAM_PLAYBACK, 0);
                if (err >= 0) {
                    snd_pcm_hw_params_any(pcm, params);
                    snd_pcm_hw_params_set_access(pcm, params, SND_PCM_ACCESS_RW_INTERLEAVED);
                    snd_pcm_hw_params_set_format(pcm, params, eff_format);
                    snd_pcm_hw_params_set_channels(pcm, params, eff_channels);
                    unsigned int plug_rate = eff_rate;
                    snd_pcm_hw_params_set_rate_near(pcm, params, &plug_rate, NULL);
                    if (plug_rate == eff_rate) {
                        opened_device = plug_buf;
                        rate = plug_rate;
                        fprintf(stderr, "wav-play: plug: retry succeeded at %u Hz\n", rate);
                    } else {
                        /* plug: also mismatched; fall back to raw device */
                        fprintf(stderr, "wav-play: plug: retry still mismatches (%u Hz)\n", plug_rate);
                        snd_pcm_close(pcm);
                        pcm = NULL;
                    }
                } else {
                    fprintf(stderr, "wav-play: plug: retry open failed: %s\n", snd_strerror(err));
                }
                if (!pcm) {
                    /* Rate conversion is not available on this device for
                     * the requested PCM.  Refuse rather than play the
                     * audio at the wrong speed (e.g. 22050 Hz espeak
                     * output played at 48000 Hz on a fixed-rate codec
                     * yields ~2.18x speed which is unintelligible).
                     * The user can pick a different ALSA device
                     * (e.g. tts_sm) which routes through the system
                     * resampler. */
                    fprintf(stderr,
                        "wav-play: refusing to play %u Hz audio on '%s' (no rate conversion available, would play at %.1fx speed). Try a different ALSA device.\n",
                        eff_rate, device,
                        (double)rate / eff_rate);
                    restore_mixer_switches(quiet);
                    fclose(f);
                    return 2;
                }
            } else {
                fprintf(stderr,
                    "wav-play: refusing to play %u Hz audio on '%s' (plug device returned %u Hz, would play at %.1fx speed). Try a different ALSA device.\n",
                    eff_rate, opened_device, rate,
                    (double)rate / eff_rate);
                snd_pcm_close(pcm);
                restore_mixer_switches(quiet);
                fclose(f);
                return 2;
            }
        } else {
            /* Fallback chain: try remaining devices for one that accepts
             * the requested rate.  Only try devices from the fallback
             * chain (tts_sm, plughw:0) - never hw:0. */
            const char *try_devices[] = { device, "tts_sm", "plughw:0", NULL };
            snd_pcm_close(pcm);
            pcm = NULL;
            int found_current = 0;
            for (int j = 0; try_devices[j]; j++) {
                if (strcmp(try_devices[j], opened_device) == 0) {
                    found_current = 1;
                    continue;
                }
                if (!found_current)
                    continue;
                err = snd_pcm_open(&pcm, try_devices[j], SND_PCM_STREAM_PLAYBACK, 0);
                if (err < 0)
                    continue;
                /* Reconfigure on the new device */
                snd_pcm_hw_params_any(pcm, params);
                snd_pcm_hw_params_set_access(pcm, params, SND_PCM_ACCESS_RW_INTERLEAVED);
                snd_pcm_hw_params_set_format(pcm, params, eff_format);
                snd_pcm_hw_params_set_channels(pcm, params, eff_channels);
                unsigned int retry_rate = eff_rate;
                snd_pcm_hw_params_set_rate_near(pcm, params, &retry_rate, NULL);
                if (retry_rate != eff_rate) {
                    fprintf(stderr, "wav-play: rate mismatch persists on '%s' (%u Hz)\n",
                            try_devices[j], retry_rate);
                    snd_pcm_close(pcm);
                    pcm = NULL;
                    continue;
                }
                opened_device = try_devices[j];
                rate = retry_rate;
                fprintf(stderr, "wav-play: rate OK on fallback '%s' (%u Hz)\n",
                        opened_device, rate);
                break;
            }
            if (!pcm) {
                fprintf(stderr, "wav-play: no device supports %u Hz, proceeding anyway\n",
                        eff_rate);
                /* Re-open the original device as last resort */
                err = snd_pcm_open(&pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
                if (err < 0) {
                    restore_mixer_switches(quiet);
                    fclose(f);
                    return 1;
                }
                snd_pcm_hw_params_any(pcm, params);
                snd_pcm_hw_params_set_access(pcm, params, SND_PCM_ACCESS_RW_INTERLEAVED);
                snd_pcm_hw_params_set_format(pcm, params, eff_format);
                snd_pcm_hw_params_set_channels(pcm, params, eff_channels);
                rate = eff_rate;
                snd_pcm_hw_params_set_rate_near(pcm, params, &rate, NULL);
                opened_device = device;
            }
        }
    }

    err = snd_pcm_hw_params(pcm, params);
    if (err < 0) {
        if (!quiet) fprintf(stderr, "wav-play: cannot set params: %s\n",
                            snd_strerror(err));
        snd_pcm_close(pcm);
        restore_mixer_switches(quiet);
        fclose(f);
        return 1;
    }

    /* Post-commit rate verification.  On some PocketBook ALSA stacks
     * (PB631 with plughw:0) the plug: container accepts the requested
     * rate via set_rate_near without actually loading the rate plugin,
     * so audio plays at the hardware's native rate (typically 48000 Hz)
     * regardless of the WAV file's sample rate.  Re-read the actual
     * negotiated rate after hw_params commit and refuse if it does not
     * match the source rate.  Without this, 22050 Hz espeak audio plays
     * at ~2.18x speed and the user has no audible error. */
    if (strict_device) {
        unsigned int actual_rate = 0;
        if (snd_pcm_hw_params_get_rate(params, &actual_rate, NULL) == 0
            && actual_rate != eff_rate) {
            fprintf(stderr,
                "wav-play: post-commit rate mismatch on '%s': WAV=%u Hz, device=%u Hz (would play at %.2fx speed). Refusing.\n",
                opened_device, eff_rate, actual_rate,
                (double)actual_rate / eff_rate);
            snd_pcm_close(pcm);
            restore_mixer_switches(quiet);
            fclose(f);
            return 2;
        }
    }
    /* Signal that audio is about to flow.  The SyncController reads stderr
     * (redirected to /tmp/.gst_status) looking for "PLAYING" to anchor
     * word-highlight timing.  Without this, it falls back to a 5s timeout
     * per sentence. */
    fprintf(stderr, "PLAYING\n");
    fflush(stderr);

    /* Play PCM data (streamed from file, or from the converted buffer) */
    size_t frame_size  = eff_channels * (eff_bits / 8);
    size_t buf_frames  = 1024;
    unsigned char *buf = malloc(buf_frames * frame_size);
    if (!buf) {
        snd_pcm_close(pcm);
        restore_mixer_switches(quiet);
        fclose(f);
        free(conv_buf);
        return 1;
    }

    if (conv_buf) {
        /* Software-converted path: play the whole in-memory buffer. */
        uint32_t frames_left = conv_frames;
        const unsigned char *p = (const unsigned char *)conv_buf;
        while (frames_left > 0) {
            snd_pcm_sframes_t chunk = frames_left > buf_frames
                ? (snd_pcm_sframes_t)buf_frames : (snd_pcm_sframes_t)frames_left;
            snd_pcm_sframes_t written = snd_pcm_writei(pcm, p, chunk);
            if (written == -EPIPE) {
                /* Underrun - recover and retry */
                snd_pcm_prepare(pcm);
                written = snd_pcm_writei(pcm, p, chunk);
            }
            if (written < 0) {
                if (!quiet) fprintf(stderr, "wav-play: write error: %s\n",
                                    snd_strerror(written));
                break;
            }
            p += (size_t)written * frame_size;
            frames_left -= written;
        }
        free(conv_buf);
    } else {
        uint32_t remaining = chunk_size;
        while (remaining > 0) {
            size_t to_read = buf_frames * frame_size;
            if (to_read > remaining)
                to_read = remaining;

            size_t n = fread(buf, 1, to_read, f);
            if (n == 0)
                break;
            remaining -= n;

            snd_pcm_sframes_t frames = n / frame_size;
            snd_pcm_sframes_t written = snd_pcm_writei(pcm, buf, frames);
            if (written == -EPIPE) {
                /* Underrun - recover and retry */
                snd_pcm_prepare(pcm);
                written = snd_pcm_writei(pcm, buf, frames);
            }
            if (written < 0) {
                if (!quiet) fprintf(stderr, "wav-play: write error: %s\n",
                                    snd_strerror(written));
                break;
            }
        }
    }

    snd_pcm_drain(pcm);
    snd_pcm_close(pcm);
    /* Restore switch state now that all audio has been consumed from the
     * ring buffer.  This undoes the unmuting done by setup_mixer() and
     * leaves hw:0 exactly as the firmware/OS configured it. */
    if (!no_mixer)
        restore_mixer_switches(quiet);
    free(buf);
    fclose(f);
    return 0;
}
