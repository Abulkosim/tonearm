#!/usr/bin/env python3
"""Checks the fake Spotify's dictionary against the real one.

Usage: check-sdef.py <real.sdef> <fake.sdef>

<real.sdef> is the output of `sdef /Applications/Spotify.app`. For every term Tonearm
sends (USED below, taken from SpotifyBridge.swift) and every term the fake declares, the
name must exist in both with the same four-char code, and properties must have the same
type. Exits 1 on any mismatch.
"""
import sys
import xml.etree.ElementTree as ET

# What SpotifyBridge.swift sends. Keep in step with readSource and Command.appleScript.
USED = [
    ("command", "play"),
    ("command", "playpause"),
    ("command", "next track"),
    ("command", "previous track"),
    ("class", "track"),
    ("property", "application", "current track"),
    ("property", "application", "player state"),
    ("property", "application", "player position"),
    ("property", "application", "sound volume"),
    ("property", "application", "shuffling"),
    ("property", "application", "repeating"),
    ("property", "track", "id"),
    ("property", "track", "name"),
    ("property", "track", "artist"),
    ("property", "track", "album"),
    ("property", "track", "artwork url"),
    ("property", "track", "duration"),
    ("enumerator", "player state", "stopped"),
    ("enumerator", "player state", "playing"),
    ("enumerator", "player state", "paused"),
]

PRIMITIVES = {"text", "integer", "real", "boolean", "number", "date", "file", "any", "record"}


def load(path):
    """Returns {key: (code, type)} for every class, property, command and enumerator."""
    root = ET.parse(path).getroot()
    terms = {}
    enums = {}
    for enum in root.iter("enumeration"):
        enums[enum.get("name")] = {e.get("name"): e.get("code") for e in enum.iter("enumerator")}
    for cls in list(root.iter("class")) + list(root.iter("class-extension")):
        name = cls.get("name") or cls.get("extends")
        if cls.tag == "class":
            terms[("class", name)] = (cls.get("code"), None)
        for prop in cls.findall("property"):
            ptype = prop.get("type")
            if ptype is None:
                t = prop.find("type")
                ptype = t.get("type") if t is not None else None
            terms[("property", name, prop.get("name"))] = (prop.get("code"), ptype)
            if ptype in enums:
                for ename, ecode in enums[ptype].items():
                    terms[("enumerator", prop.get("name"), ename)] = (ecode, None)
    for cmd in root.iter("command"):
        terms[("command", cmd.get("name"))] = (cmd.get("code"), None)
    return terms


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    real = load(sys.argv[1])
    fake = load(sys.argv[2])
    keys = list(USED) + [k for k in fake if k not in USED]
    bad = 0
    for key in keys:
        label = " / ".join(key)
        r, f = real.get(key), fake.get(key)
        if r is None or f is None:
            where = "real Spotify" if r is None else "fake"
            print(f"MISSING  {label}: not in {where}")
            bad += 1
            continue
        (rcode, rtype), (fcode, ftype) = r, f
        if rcode != fcode:
            print(f"CODE     {label}: real '{rcode}', fake '{fcode}'")
            bad += 1
        elif key[0] == "property" and (rtype in PRIMITIVES or ftype in PRIMITIVES) and rtype != ftype:
            print(f"TYPE     {label}: real {rtype}, fake {ftype}")
            bad += 1
        else:
            print(f"ok       {label}: '{rcode}'" + (f" {rtype}" if rtype else ""))
    print(f"{len(keys)} terms checked, {bad} mismatches")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
