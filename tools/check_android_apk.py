#!/usr/bin/env python3
"""Fail if an Android APK holds anything but the engine.

The APK may contain the manifest, the compiled Java classes, the launcher icon, the signature and the
native library. It must never contain Minecraft's assets or data, prepared resources, game jars or
sounds: those are prepared on the player's computer from their own copy and copied to the phone.
"""

import argparse
from pathlib import PurePosixPath
import sys
import zipfile

# Exactly these top-level names, and these places for the rest.
TOP_LEVEL_FILES = {"AndroidManifest.xml", "classes.dex", "resources.arsc"}
ALLOWED_DIRECTORIES = {"res", "lib", "META-INF"}
# Anything that looks like game content, wherever it sits.
FORBIDDEN_NAMES = ("horizon-resources.json", "level.dat", "options.txt")
FORBIDDEN_PARTS = {"assets", "minecraft", "sounds", "resources", "data", ".local", "decompiled"}
FORBIDDEN_SUFFIXES = {".jar", ".class", ".ogg", ".mcmeta", ".nbt", ".mca", ".json", ".lang", ".zip"}
# A generous bound: the engine is a few tens of megabytes; game content would dwarf it.
MAX_BYTES = 250 * 1024 * 1024


def problems(names, size):
    found = []
    if size > MAX_BYTES:
        found.append(f"the APK is {size >> 20} MiB, more than the {MAX_BYTES >> 20} MiB an engine-only APK needs")
    for name in names:
        path = PurePosixPath(name)
        if name.endswith("/"):
            continue
        parts = path.parts
        if len(parts) == 1:
            if name not in TOP_LEVEL_FILES:
                found.append(f"{name}: not an engine file")
            continue
        if parts[0] not in ALLOWED_DIRECTORIES:
            found.append(f"{name}: outside the places an engine-only APK uses ({', '.join(sorted(ALLOWED_DIRECTORIES))})")
            continue
        if parts[0] == "lib" and not (len(parts) == 3 and parts[1] == "arm64-v8a" and path.suffix == ".so"):
            found.append(f"{name}: only lib/arm64-v8a/*.so belongs in lib/")
        if parts[0] == "res" and path.suffix not in {".png", ".xml", ".webp"}:
            found.append(f"{name}: unexpected resource type")
        if (
            path.name.lower() in FORBIDDEN_NAMES
            or path.suffix.lower() in FORBIDDEN_SUFFIXES
            or any(part.lower() in FORBIDDEN_PARTS for part in parts[:-1])
        ):
            found.append(f"{name}: looks like game content")
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk")
    args = parser.parse_args()
    with zipfile.ZipFile(args.apk) as apk:
        names = apk.namelist()
        size = sum(info.file_size for info in apk.infolist())
    errors = problems(names, size)
    if errors:
        print(f"{args.apk} holds more than the engine:", file=sys.stderr)
        for error in sorted(set(errors)):
            print(f"  {error}", file=sys.stderr)
        return 1
    print(f"{args.apk}: {len(names)} entries, engine only.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
