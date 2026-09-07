#!/usr/bin/env python3
"""Stage-16 localization sweep support: regenerates App/Sources/Localizable.xcstrings
(English base) from all NSLocalizedString literals under App/Sources.
Key == English source text per project convention."""
import json, os, re, sys

ROOT = os.path.join(os.path.dirname(__file__), "..", "App", "Sources")
OUT = os.path.join(ROOT, "Localizable.xcstrings")
pattern = re.compile(r'NSLocalizedString\(\s*"((?:[^"\\]|\\.)*)"')

keys = set()
for dirpath, _, files in os.walk(ROOT):
    if os.path.abspath(dirpath).startswith(os.path.abspath(os.path.join(ROOT, "Localizable.xcstrings"))):
        continue
    for name in files:
        if not name.endswith(".swift"):
            continue
        text = open(os.path.join(dirpath, name), encoding="utf-8").read()
        keys.update(pattern.findall(text))

strings = {}
for key in sorted(keys):
    strings[key] = {"localizations": {"en": {"stringUnit": {"state": "translated", "value": key}}}}

catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
with open(OUT, "w", encoding="utf-8") as f:
    json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=False)
    f.write("\n")
print(f"wrote {OUT}: {len(keys)} keys")
