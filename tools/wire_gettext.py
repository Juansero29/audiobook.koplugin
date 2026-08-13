#!/usr/bin/env python3
"""Switch plugin modules from core gettext to audiobook_gettext."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SKIP_SUBSTR = (".fix", ".v25")
SKIP_NAMES = {"audiobook_gettext.lua", "debuglog.lua", "wire_gettext.py"}

changed = []
for p in sorted(ROOT.glob("*.lua")):
    if any(s in p.name for s in SKIP_SUBSTR) or p.name in SKIP_NAMES:
        continue
    text = p.read_text(encoding="utf-8")
    new = text.replace('require("gettext")', 'require("audiobook_gettext")')
    new = new.replace("require('gettext')", "require('audiobook_gettext')")
    if new != text:
        p.write_text(new, encoding="utf-8")
        changed.append(p.name)

print(f"updated {len(changed)} files")
for n in changed:
    print(" ", n)
