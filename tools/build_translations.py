#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build translations.py from extracted msgids via MT + glossary post-edit."""

from __future__ import annotations

import json
import re
import time
from pathlib import Path

from deep_translator import GoogleTranslator

ROOT = Path(__file__).resolve().parents[1]
MSGIDS = ROOT / "tools" / "_msgids.json"
CACHE = ROOT / "tools" / "_mt_cache.json"
OUT = ROOT / "tools" / "translations.py"

# Preserve these tokens exactly (case-sensitive whole-word / as-written)
PRESERVE = [
    "KOReader",
    "Storyteller",
    "Piper",
    "espeak-ng",
    "espeak",
    "Audiobookshelf",
    "Bluetooth",
    "AirPods",
    "Media Overlays",
    "Media Overlay",
    "SMIL",
    "EPUB",
    "MP3",
    "M4B",
    "M4A",
    "AAC",
    "WAV",
    "ONNX",
    "ALSA",
    "A2DP",
    "AVRCP",
    "MBROLA",
    "TTS",
    "FIFO",
    "GStreamer",
    "InkView",
    "PocketBook",
    "Kindle",
    "Kobo",
    "Android",
    "Pico",
    "Flite",
    "Festival",
    "Ivona",
    "VoiceView",
    "Nickel",
    "Termux",
    "GitHub",
    "Wi-Fi",
    "USB",
    "SSH",
    "HTTP",
    "URL",
    "FPS",
    "MJPEG",
    "PCM",
    "API",
    "SDK",
    "FFI",
    "MTK",
    "PB631",
    "PB740",
    "ttssrc",
    "audiomgrd",
    "playermgr",
    "wavparse",
    "audioconvert",
    "audioresample",
    "plughw:0",
    "tts_sm",
    "hwout_mix",
    "softvol",
    "dmix",
    "aplay",
    "paplay",
    "mpv",
    "mplayer",
    "ffmpeg",
    "curl",
    "wget",
    "onnx",
    "btui",
    "evdev",
    "Paperwhite",
]

# Exact msgid overrides (quality / branding)
OVERRIDE_FR: dict[str, str] = {
    "Audiobook Read-Along": "Audiolivre synchronisé",
    "Audiobook Read-Along (error)": "Audiolivre synchronisé (erreur)",
    "Plugin: Audiobook Read-Along %1": "Greffon : Audiolivre synchronisé %1",
    "Cancel": "Annuler",
    "Save": "Enregistrer",
    "Delete": "Supprimer",
    "Play": "Lire",
    "Close": "Fermer",
    "Next": "Suivant",
    "Prev": "Préc.",
    "Off": "Désactivé",
    "Set": "Définir",
    "Start": "Démarrer",
    "Resume": "Reprendre",
    "From start": "Depuis le début",
    "Update": "Mettre à jour",
    "Later": "Plus tard",
    "Restart now": "Redémarrer maintenant",
    "Keep": "Conserver",
    "Connect": "Connecter",
    "Disconnect": "Déconnecter",
    "Download": "Télécharger",
    "Log in": "Se connecter",
    "Log out": "Se déconnecter",
    "Log in…": "Se connecter…",
    "Username": "Nom d’utilisateur",
    "Password": "Mot de passe",
    "Libraries": "Bibliothèques",
    "Chapters": "Chapitres",
    "Chapter": "Chapitre",
    "Playlist": "Liste de lecture",
    "Audiobook": "Livre audio",
    "Audiobookshelf": "Audiobookshelf",
    "Bluetooth settings": "Paramètres Bluetooth",
    "General settings": "Paramètres généraux",
    "Voice settings": "Paramètres de voix",
    "Sleep timer": "Minuteur de veille",
    "Custom...": "Personnalisé…",
    "Auto": "Auto",
    "Underline": "Souligné",
    "Box": "Cadre",
    "Background": "Arrière-plan",
    "Invert": "Inverser",
    "English": "Anglais",
    "Spanish": "Espagnol",
    "French": "Français",
    "German": "Allemand",
    "Italian": "Italien",
    "Portuguese": "Portugais",
    "Portuguese (Brazil)": "Portugais (Brésil)",
    "Chinese": "Chinois",
    "Japanese": "Japonais",
    "Korean": "Coréen",
    "Russian": "Russe",
    "Arabic": "Arabe",
    "Hindi": "Hindi",
    "Untitled": "Sans titre",
    "Unknown Title": "Titre inconnu",
    "Unknown book": "Livre inconnu",
    "Item": "Élément",
    "unknown": "inconnu",
    "unknown error": "erreur inconnue",
    "BT": "BT",
    "─": "─",
    " ✓": " ✓",
    " ✓ installed": " ✓ installé",
    "%1": "%1",
    "http://192.168.1.100:13378": "http://192.168.1.100:13378",
}

OVERRIDE_ES: dict[str, str] = {
    "Audiobook Read-Along": "Audiolibro sincronizado",
    "Audiobook Read-Along (error)": "Audiolibro sincronizado (error)",
    "Plugin: Audiobook Read-Along %1": "Complemento: Audiolibro sincronizado %1",
    "Cancel": "Cancelar",
    "Save": "Guardar",
    "Delete": "Eliminar",
    "Play": "Reproducir",
    "Close": "Cerrar",
    "Next": "Siguiente",
    "Prev": "Ant.",
    "Off": "Desactivado",
    "Set": "Establecer",
    "Start": "Iniciar",
    "Resume": "Continuar",
    "From start": "Desde el inicio",
    "Update": "Actualizar",
    "Later": "Más tarde",
    "Restart now": "Reiniciar ahora",
    "Keep": "Conservar",
    "Connect": "Conectar",
    "Disconnect": "Desconectar",
    "Download": "Descargar",
    "Log in": "Iniciar sesión",
    "Log out": "Cerrar sesión",
    "Log in…": "Iniciar sesión…",
    "Username": "Nombre de usuario",
    "Password": "Contraseña",
    "Libraries": "Bibliotecas",
    "Chapters": "Capítulos",
    "Chapter": "Capítulo",
    "Playlist": "Lista de reproducción",
    "Audiobook": "Audiolibro",
    "Audiobookshelf": "Audiobookshelf",
    "Bluetooth settings": "Configuración de Bluetooth",
    "General settings": "Configuración general",
    "Voice settings": "Configuración de voz",
    "Sleep timer": "Temporizador de sueño",
    "Custom...": "Personalizado…",
    "Auto": "Auto",
    "Underline": "Subrayado",
    "Box": "Cuadro",
    "Background": "Fondo",
    "Invert": "Invertir",
    "English": "Inglés",
    "Spanish": "Español",
    "French": "Francés",
    "German": "Alemán",
    "Italian": "Italiano",
    "Portuguese": "Portugués",
    "Portuguese (Brazil)": "Portugués (Brasil)",
    "Chinese": "Chino",
    "Japanese": "Japonés",
    "Korean": "Coreano",
    "Russian": "Ruso",
    "Arabic": "Árabe",
    "Hindi": "Hindi",
    "Untitled": "Sin título",
    "Unknown Title": "Título desconocido",
    "Unknown book": "Libro desconocido",
    "Item": "Elemento",
    "unknown": "desconocido",
    "unknown error": "error desconocido",
    "BT": "BT",
    "─": "─",
    " ✓": " ✓",
    " ✓ installed": " ✓ instalado",
    "%1": "%1",
    "http://192.168.1.100:13378": "http://192.168.1.100:13378",
    # LatAm-neutral preferences
    "folder": "carpeta",
}

# Phrase glossary applied after MT (order matters; longer first)
GLOSSARY_FR: list[tuple[str, str]] = [
    ("Audiobook Read-Along", "Audiolivre synchronisé"),
    ("read-along", "lecture synchronisée"),
    ("Read-Along", "Lecture synchronisée"),
    ("Read aloud from here", "Lire à voix haute à partir d’ici"),
    ("read aloud", "lire à voix haute"),
    ("Text-to-Speech", "Synthèse vocale"),
    ("speech rate", "débit de parole"),
    ("Sleep timer", "Minuteur de veille"),
    ("bug report", "rapport de bogue"),
    ("Bug report", "Rapport de bogue"),
    ("headset", "casque"),
    ("headphones", "écouteurs"),
    ("scrubber", "curseur de position"),
    ("playlist", "liste de lecture"),
    ("chapter", "chapitre"),
    ("Chapter", "Chapitre"),
    ("Settings", "Paramètres"),
    ("settings", "paramètres"),
    ("device", "appareil"),
    ("Device", "Appareil"),
    ("Download", "Télécharger"),
    ("download", "télécharger"),
]

GLOSSARY_ES: list[tuple[str, str]] = [
    ("Audiobook Read-Along", "Audiolibro sincronizado"),
    ("read-along", "lectura sincronizada"),
    ("Read-Along", "Lectura sincronizada"),
    ("Read aloud from here", "Leer en voz alta desde aquí"),
    ("read aloud", "leer en voz alta"),
    ("Text-to-Speech", "Texto a voz"),
    ("speech rate", "velocidad de habla"),
    ("Sleep timer", "Temporizador de sueño"),
    ("bug report", "informe de error"),
    ("Bug report", "Informe de error"),
    ("headset", "auriculares"),
    ("headphones", "auriculares"),
    ("scrubber", "barra de búsqueda"),
    ("playlist", "lista de reproducción"),
    ("chapter", "capítulo"),
    ("Chapter", "Capítulo"),
    ("Settings", "Configuración"),
    ("settings", "configuración"),
    ("device", "dispositivo"),
    ("Device", "Dispositivo"),
    ("folder", "carpeta"),
    ("File", "Archivo"),
    ("file", "archivo"),
    # Avoid Spain-specific if MT produced them
    ("ordenador", "computadora"),
    ("móvil", "teléfono"),
    ("vosotros", "ustedes"),
    ("coger", "tomar"),
    ("celular", "teléfono"),
]


def protect_placeholders(s: str) -> tuple[str, dict[str, str]]:
    """Replace %1/%2 and preserved tokens with placeholders for MT."""
    mapping: dict[str, str] = {}
    out = s
    idx = 0

    def sub(m: re.Match[str]) -> str:
        nonlocal idx
        key = f"⟦PH{idx}⟧"
        mapping[key] = m.group(0)
        idx += 1
        return key

    # Protect %1, %2, %%, numbered
    out = re.sub(r"%\d+|%%", sub, out)
    # Protect preserve tokens (longest first)
    for token in sorted(PRESERVE, key=len, reverse=True):
        if token in out:
            key = f"⟦PH{idx}⟧"
            mapping[key] = token
            out = out.replace(token, key)
            idx += 1
    return out, mapping


def restore_placeholders(s: str, mapping: dict[str, str]) -> str:
    out = s
    for key, val in mapping.items():
        out = out.replace(key, val)
        # MT sometimes alters brackets
        alt = key.replace("⟦", "[").replace("⟧", "]")
        out = out.replace(alt, val)
        out = out.replace(key.replace("⟦", "").replace("⟧", ""), val) if False else out
    # Fix common MT damage to placeholders
    out = re.sub(r"⟦\s*PH\s*(\d+)\s*⟧", lambda m: mapping.get(f"⟦PH{m.group(1)}⟧", m.group(0)), out)
    out = re.sub(r"\[\s*PH\s*(\d+)\s*\]", lambda m: mapping.get(f"⟦PH{m.group(1)}⟧", m.group(0)), out)
    return out


def apply_glossary(s: str, glossary: list[tuple[str, str]]) -> str:
    out = s
    for src, dst in glossary:
        out = out.replace(src, dst)
    return out


def translate_one(text: str, lang: str, cache: dict, translators: dict) -> str:
    if not text.strip():
        return text
    # Identical short tokens / symbols
    if text in ("✓", " ←", "→", "─", "%1", "BT"):
        return text
    key = f"{lang}::" + text
    if key in cache:
        return cache[key]

    overrides = OVERRIDE_FR if lang == "fr" else OVERRIDE_ES
    if text in overrides:
        cache[key] = overrides[text]
        return overrides[text]

    protected, mapping = protect_placeholders(text)
    try:
        translated = translators[lang].translate(protected)
    except Exception as exc:  # noqa: BLE001
        print(f"MT fail ({lang}): {exc!r} :: {text[:60]!r}")
        time.sleep(1.5)
        try:
            translated = translators[lang].translate(protected)
        except Exception as exc2:  # noqa: BLE001
            print(f"MT retry fail ({lang}): {exc2!r}")
            translated = text

    if not translated:
        translated = text
    translated = restore_placeholders(translated, mapping)
    glossary = GLOSSARY_FR if lang == "fr" else GLOSSARY_ES
    translated = apply_glossary(translated, glossary)
    # Ensure placeholders still present
    for ph in re.findall(r"%\d+", text):
        if ph not in translated:
            # append missing? better leave and warn
            print(f"WARN missing {ph} in {lang}: {text[:40]!r} -> {translated[:40]!r}")
    cache[key] = translated
    return translated


def py_str(s: str) -> str:
    return json.dumps(s, ensure_ascii=False)


def main() -> None:
    data = json.loads(MSGIDS.read_text(encoding="utf-8"))
    msgids = [x["msgid"] for x in data]
    cache: dict[str, str] = {}
    if CACHE.exists():
        cache = json.loads(CACHE.read_text(encoding="utf-8"))

    translators = {
        "fr": GoogleTranslator(source="en", target="fr"),
        "es": GoogleTranslator(source="en", target="es"),
    }

    fr: dict[str, str] = {}
    es: dict[str, str] = {}
    total = len(msgids)
    for i, mid in enumerate(msgids, 1):
        fr[mid] = translate_one(mid, "fr", cache, translators)
        es[mid] = translate_one(mid, "es", cache, translators)
        if i % 25 == 0 or i == total:
            print(f"{i}/{total}")
            CACHE.write_text(json.dumps(cache, ensure_ascii=False, indent=1), encoding="utf-8")
            time.sleep(0.05)

    # Force overrides again (post-glossary)
    for mid, val in OVERRIDE_FR.items():
        if mid in fr:
            fr[mid] = val
    for mid, val in OVERRIDE_ES.items():
        if mid in es:
            es[mid] = val

    # Meta description — hand-tuned quality
    meta = next((m for m in msgids if m.startswith("Text-to-Speech with synchronized")), None)
    if meta:
        fr[meta] = (
            "Synthèse vocale avec surlignage synchronisé des mots. Lit aussi des livres audio "
            "préenregistrés (mp3, m4b, m4a) avec un curseur de position et les Media Overlays EPUB 3 "
            "(format Storyteller).\n\n"
            "Fonctionnalités :\n"
            "• Surlignage mot à mot pendant la lecture\n"
            "• Option de surlignage des phrases\n"
            "• Plusieurs moteurs TTS (espeak-ng, Piper neural, Pico, Flite, Festival, Android, "
            "assistant natif de la plateforme)\n"
            "• Débit, hauteur et volume réglables (0,25× à 2,0×)\n"
            "• Avance automatique des pages\n"
            "• Plusieurs styles de surlignage (arrière-plan, souligné, cadre, inversion)\n"
            "• Audio Bluetooth et boutons multimédia du casque\n"
            "• Lecture de fichiers audio avec recherche, navigation par chapitres et affichage du temps\n"
            "• Prise en charge des Media Overlays EPUB 3 pour ebook/livre audio pré-synchronisés\n"
            "• Génération locale d’alignement phrase/mot à partir d’un EPUB + livre audio\n\n"
            "Utilisation :\n"
            "1. Appui long sur un mot pour ouvrir le dictionnaire\n"
            "2. Toucher « Lire à voix haute à partir d’ici »\n"
            "3. Ou menu Outils → Audiolivre synchronisé\n"
            "4. Pour les fichiers audio : menu Outils → Ouvrir un fichier audio…"
        )
        es[meta] = (
            "Texto a voz con resaltado sincronizado de palabras. También reproduce audiolibros "
            "pregrabados (mp3, m4b, m4a) con barra de búsqueda y Media Overlays EPUB 3 "
            "(formato Storyteller).\n\n"
            "Funciones:\n"
            "• Resaltado palabra por palabra mientras se lee el texto\n"
            "• Opción de resaltado de oraciones\n"
            "• Varios motores TTS (espeak-ng, Piper neural, Pico, Flite, Festival, Android, "
            "asistente nativo de la plataforma)\n"
            "• Velocidad de habla ajustable (0,25× a 2,0×), tono y volumen\n"
            "• Avance automático de páginas\n"
            "• Varios estilos de resaltado (fondo, subrayado, cuadro, inversión)\n"
            "• Audio Bluetooth y botones multimedia de auriculares\n"
            "• Reproducción de archivos de audio con búsqueda, navegación por capítulos y visualización del tiempo\n"
            "• Compatibilidad con Media Overlays EPUB 3 para ebook/audiolibro presincronizados\n"
            "• Generación local de alineación de oraciones/palabras a partir de EPUB + audiolibro\n\n"
            "Uso:\n"
            "1. Mantén pulsada una palabra para abrir el diccionario\n"
            "2. Toca «Leer en voz alta desde aquí»\n"
            "3. O menú Herramientas → Audiolibro sincronizado\n"
            "4. Para archivos de audio: menú Herramientas → Abrir archivo de audio…"
        )

    lines = [
        "# -*- coding: utf-8 -*-",
        "# Auto-generated by tools/build_translations.py — review glossary overrides as needed.",
        "TRANSLATIONS_FR = {",
    ]
    for mid in msgids:
        lines.append(f"    {py_str(mid)}: {py_str(fr[mid])},")
    lines.append("}")
    lines.append("")
    lines.append("TRANSLATIONS_ES = {")
    for mid in msgids:
        lines.append(f"    {py_str(mid)}: {py_str(es[mid])},")
    lines.append("}")
    lines.append("")
    OUT.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {OUT} ({len(msgids)} entries each)")


if __name__ == "__main__":
    main()
