--[[--
Plugin metadata for KOReader.

@module _meta
--]]

local _ = require("gettext")

return {
    name = "audiobook",
    version = "0.1.15.6",
    fullname = _("Audiobook Read-Along"),
    description = _([[Text-to-Speech with synchronized word highlighting. Also plays pre-recorded audiobooks (mp3, m4b, m4a) with a seekable scrubber and EPUB 3 Media Overlays (Storyteller format).

Features:
• Word-by-word highlighting as text is read
• Sentence highlighting option
• Multiple TTS engine support (espeak-ng, Piper neural, Pico, Flite, Festival, Android)
• Adjustable speech rate (0.25x to 2.0x), pitch, and volume
• Auto-advance pages
• Multiple highlight styles (background, underline, box, invert)
• Bluetooth audio and headset media button support
• Audio file playback with scrubber seek, chapter navigation, and time display
• EPUB 3 Media Overlay support for pre-synchronized ebook/audiobook playback
• Local sentence/word alignment generation from EPUB + audiobook

Usage:
1. Long-press a word to open dictionary
2. Tap "Read aloud from here"
3. Or use Tools menu → Audiobook Read-Along
4. For audio files: Tools menu → Open audio file...]]),
}
