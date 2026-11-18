#!/usr/bin/env python3
"""Sync Localization/Localizable.xcstrings with the strings used in the code.

    scripts/update_strings.py          # extract keys with Xcode, merge, report missing English
    scripts/update_strings.py --check  # same, but exit 1 if any English translation is missing

Russian is the source language (the keys are the Russian strings); English
translations live in the catalog and are compiled into the app by build_app.sh.
"""
import json
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "Localization", "Localizable.xcstrings")
NS = {"x": "urn:oasis:names:tc:xliff:document:1.2"}


def extract_keys():
    with tempfile.TemporaryDirectory() as tmp:
        cmd = [
            "xcodebuild", "-exportLocalizations",
            "-localizationPath", tmp,
            "-exportLanguage", "en",
            "-scheme", "GiveMyRamBack",
            "-destination", "platform=macOS",
            "-derivedDataPath", os.path.join(tmp, "dd"),
        ]
        result = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            sys.stderr.write(result.stdout[-3000:] + result.stderr[-3000:])
            sys.exit("xcodebuild -exportLocalizations failed")
        keys = {}
        for dirpath, _, files in os.walk(tmp):
            for name in files:
                if not name.endswith(".xliff"):
                    continue
                tree = ET.parse(os.path.join(dirpath, name))
                for unit in tree.getroot().iter("{urn:oasis:names:tc:xliff:document:1.2}trans-unit"):
                    key = unit.get("id")
                    note = unit.find("x:note", NS)
                    comment = note.text if note is not None and note.text else None
                    if key and key != "com.apple.dt.xcode":
                        keys[key] = comment
        return keys


def main():
    check = "--check" in sys.argv
    keys = extract_keys()

    if os.path.exists(CATALOG):
        with open(CATALOG, encoding="utf-8") as f:
            catalog = json.load(f)
    else:
        catalog = {"sourceLanguage": "ru", "strings": {}, "version": "1.0"}

    strings = catalog.setdefault("strings", {})
    added = [k for k in keys if k not in strings]
    for key in added:
        strings[key] = {}
    for key, comment in keys.items():
        if comment and comment != "No comment provided by engineer.":
            strings[key]["comment"] = comment
    stale = [k for k, v in strings.items() if k not in keys and v.get("extractionState") != "stale"]
    for key in stale:
        strings[key]["extractionState"] = "stale"
    for key in keys:
        strings[key].pop("extractionState", None)

    catalog["strings"] = dict(sorted(strings.items()))
    os.makedirs(os.path.dirname(CATALOG), exist_ok=True)
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write("\n")

    missing = [
        k for k in keys
        if not strings[k].get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value")
        and not strings[k].get("shouldTranslate") is False
    ]
    print(f"{len(keys)} keys, {len(added)} new, {len(stale)} newly stale, {len(missing)} missing English")
    for key in missing:
        print("  missing:", key)
    if check and missing:
        sys.exit(1)


if __name__ == "__main__":
    main()
