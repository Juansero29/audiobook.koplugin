#!/usr/bin/env bash
# Inject the local ElevenLabs API key into KOReader on the connected Android device.
# Never prints the key. Requires: adb, python3, KOReader F-Droid package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_FILE="${ELEVENLABS_KEY_FILE:-$ROOT/tools/elevenlabs_api_key.txt}"
ADB="${ADB:-/opt/homebrew/bin/adb}"
PKG="${KOREADER_PKG:-org.koreader.launcher.fdroid}"
ACTIVITY="${KOREADER_ACTIVITY:-org.koreader.launcher.MainActivity}"
REMOTE_SETTINGS="/sdcard/koreader/settings.reader.lua"
TMP_DIR="$(mktemp -d /tmp/koreader-el-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ ! -x "$ADB" ]]; then
  ADB="$(command -v adb || true)"
fi
if [[ -z "$ADB" ]]; then
  echo "adb not found" >&2
  exit 1
fi

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Key file not found: $KEY_FILE" >&2
  exit 1
fi

KEY="$(python3 - "$KEY_FILE" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(encoding="utf-8")
key = ""
for line in text.splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    key = line
    break
if not key:
    sys.stderr.write("No API key found. Paste it on its own line (not a comment) and save.\n")
    sys.exit(1)
if "\x00" in key or len(key) < 8:
    sys.stderr.write("That does not look like an API key.\n")
    sys.exit(1)
print(key, end="")
PY
)"

echo "Stopping KOReader so settings are not overwritten in memory..."
"$ADB" shell am force-stop "$PKG" >/dev/null
sleep 1

LOCAL_SETTINGS="$TMP_DIR/settings.reader.lua"
"$ADB" pull "$REMOTE_SETTINGS" "$LOCAL_SETTINGS" >/dev/null

python3 - "$LOCAL_SETTINGS" "$KEY" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
text = path.read_text(encoding="utf-8")
marker = '["audiobook_settings"]'
idx = text.find(marker)
if idx < 0:
    sys.stderr.write("Could not find audiobook_settings in settings.reader.lua\n")
    sys.exit(1)

def lua_escape(s: str) -> str:
    return (
        s.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "")
    )

def upsert(block: str, lua_key: str, lua_value: str) -> str:
    pattern = re.compile(
        r'^[ \t]*\["' + re.escape(lua_key) + r'"\] = .*,\s*$',
        re.MULTILINE,
    )
    line = f'        ["{lua_key}"] = {lua_value},'
    if pattern.search(block):
        return pattern.sub(line, block, count=1)
    brace = block.find("{")
    if brace < 0:
        raise SystemExit(f"Malformed audiobook_settings for {lua_key}")
    insert_at = block.find("\n", brace)
    if insert_at < 0:
        raise SystemExit(f"Malformed audiobook_settings for {lua_key}")
    return block[: insert_at + 1] + line + "\n" + block[insert_at + 1 :]

# Isolate the audiobook_settings table (4-space indent close).
rest = text[idx:]
close = re.search(r"\n    \},", rest)
if not close:
    sys.stderr.write("Could not find end of audiobook_settings table\n")
    sys.exit(1)
end = idx + close.end()
block = text[idx:end]
quoted = '"' + lua_escape(key) + '"'
block = upsert(block, "elevenlabs_api_key", quoted)
block = upsert(block, "tts_backend", '"elevenlabs"')
path.write_text(text[:idx] + block + text[end:], encoding="utf-8")
print(f"Patched settings: key length {len(key)}, tts_backend=elevenlabs")
PY

"$ADB" push "$LOCAL_SETTINGS" "$REMOTE_SETTINGS" >/dev/null
echo "Wrote key into $REMOTE_SETTINGS"

echo "Starting KOReader..."
"$ADB" shell am start -n "$PKG/$ACTIVITY" >/dev/null
echo "Done. In KOReader: Tools → Audiobook → TTS settings → ElevenLabs → pick a voice, then read aloud (Wi-Fi required)."
