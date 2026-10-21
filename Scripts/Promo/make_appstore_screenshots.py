#!/usr/bin/env python3
"""Mac App Store screenshots in every language: a headline and sub-line above the real window.

  Scripts/Promo/make_appstore_screenshots.py <headlines.json> <out-folder> [--langs en de …] [--compose-only]

The headlines file lists the scenes in store order, the App Store locale folder for each app
language, and one headline and sub-line per scene and language:

  {"scenes": ["03-smart-clean", …],
   "store_locales": {"en": "en-US", "es": ["es-ES", "es-MX"], …},
   "headlines": {"en": [{"headline": "…", "subline": "…"}, …], …}}

Windows are captured with make_screenshots.sh (demo mode, needs Screen Recording permission;
PureMac windows open in front for about 12 seconds per scene and language) into
--windows (default: a "screenshot-captures" folder next to <out-folder>; kept outside it because
fastlane deliver reads every folder there as a language), then composed by appstore_frame.swift
into <out-folder>/<locale>/NN-<scene>.png at 1440×900. --compose-only reuses existing captures.
"""
import argparse, json, os, pathlib, re, subprocess, sys, tempfile

here = pathlib.Path(__file__).resolve().parent
repo = here.parent.parent
ap = argparse.ArgumentParser()
ap.add_argument("headlines"); ap.add_argument("out")
ap.add_argument("--langs", nargs="*"); ap.add_argument("--compose-only", action="store_true")
ap.add_argument("--windows")
a = ap.parse_args()
spec = json.load(open(a.headlines))
scenes, locales, headlines = spec["scenes"], spec["store_locales"], spec["headlines"]
langs = a.langs or list(headlines)
unknown = [l for l in langs if l not in headlines]
if unknown: sys.exit(f"no headlines for {unknown}")
out = pathlib.Path(a.out).resolve()
windows = pathlib.Path(a.windows).resolve() if a.windows else out.parent / "screenshot-captures"

if not a.compose_only:
    only = "^(" + "|".join(re.escape(s) for s in scenes) + ")$"
    subprocess.run([str(here / "make_screenshots.sh"), str(windows), *langs], cwd=repo, check=True, env={**os.environ, "ONLY": only})

tool = pathlib.Path(tempfile.mkdtemp()) / "appstore_frame"
subprocess.run(["swiftc", "-O", str(here / "appstore_frame.swift"), "-o", str(tool)], check=True)
for lang in langs:
    targets = locales[lang] if isinstance(locales[lang], list) else [locales[lang]]
    for folder in targets:
        dest = out / folder; dest.mkdir(parents=True, exist_ok=True)
        for old in dest.glob("*.png"): old.unlink()
        for number, (scene, text) in enumerate(zip(scenes, headlines[lang]), start=1):
            window = windows / lang / "window" / f"{scene}.png"
            if not window.exists(): sys.exit(f"missing capture {window}")
            name = re.sub(r"^\d+-", "", scene)
            appearance = "light" if scene.endswith("-light") else "dark"
            subprocess.run([str(tool), str(window), str(dest / f"{number:02d}-{name}.png"), appearance, text["headline"], text["subline"]],
                           check=True, stdout=subprocess.DEVNULL)
    print(f"{lang}: {len(scenes)} screenshots → {', '.join(targets)}")
