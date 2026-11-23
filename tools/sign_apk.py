#!/usr/bin/env python3
"""Align and sign an unsigned release APK with the keystore in keys/release.properties.

Godot passes keystore passwords through a shell when it signs, so passwords with shell
characters (` $ ! | \\ " ...) break its export. This signs outside Godot instead: the
passwords reach apksigner through environment variables and are never printed.

usage: sign_apk.py <unsigned.apk> <signed.apk> [keys/release.properties]

release.properties follows Java Properties rules (a literal backslash is written \\\\):
  storeFile=release.jks   (relative to the properties file)
  storePassword=...
  keyAlias=key0
  keyPassword=...
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def fail(message: str) -> None:
    sys.exit(f"sign_apk: {message}")


def read_properties(path: Path) -> dict:
    """Parse a .properties file the way java.util.Properties.load does."""
    escapes = {"t": "\t", "n": "\n", "r": "\r", "f": "\f"}
    result = {}
    logical = ""
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.lstrip(" \t\f")
        if not logical and (not line or line[0] in "#!"):
            continue
        trailing = len(line) - len(line.rstrip("\\"))
        if trailing % 2 == 1:  # odd backslashes: the line continues
            logical += line[:-1]
            continue
        logical += line
        key, value, i = "", "", 0
        chars = logical
        # Key ends at the first unescaped '=', ':' or whitespace.
        while i < len(chars):
            c = chars[i]
            if c == "\\" and i + 1 < len(chars):
                i += 1
                key += chars[i] if chars[i] not in escapes else escapes[chars[i]]
            elif c in "=: \t\f":
                break
            else:
                key += c
            i += 1
        while i < len(chars) and chars[i] in " \t\f":
            i += 1
        if i < len(chars) and chars[i] in "=:":
            i += 1
        while i < len(chars) and chars[i] in " \t\f":
            i += 1
        while i < len(chars):
            c = chars[i]
            if c == "\\" and i + 1 < len(chars):
                i += 1
                n = chars[i]
                if n == "u" and re.fullmatch(r"[0-9a-fA-F]{4}", chars[i + 1:i + 5]):
                    value += chr(int(chars[i + 1:i + 5], 16))
                    i += 4
                else:
                    value += escapes.get(n, n)
            else:
                value += c
            i += 1
        result[key] = value
        logical = ""
    return result


def build_tools() -> Path:
    """Newest Android build-tools that has both zipalign and apksigner."""
    for env in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        if os.environ.get(env):
            sdk = Path(os.environ[env])
            break
    else:
        sdk = Path.home() / "Library/Android/sdk"
    versions = sorted(
        (d for d in (sdk / "build-tools").glob("*") if (d / "apksigner").exists() and (d / "zipalign").exists()),
        key=lambda d: [int(p) if p.isdigit() else 0 for p in re.split(r"[.-]", d.name)],
    )
    if not versions:
        fail(f"no build-tools with apksigner and zipalign under {sdk}; set ANDROID_HOME")
    return versions[-1]


def main() -> None:
    if len(sys.argv) not in (3, 4):
        fail("usage: sign_apk.py <unsigned.apk> <signed.apk> [keys/release.properties]")
    unsigned, signed = Path(sys.argv[1]), Path(sys.argv[2])
    props_path = Path(sys.argv[3] if len(sys.argv) == 4 else "keys/release.properties")
    if not unsigned.is_file():
        fail(f"{unsigned} not found")
    if not props_path.is_file():
        fail(f"{props_path} not found; copy keys/release.properties.example and fill it in")
    props = read_properties(props_path)
    missing = [k for k in ("storeFile", "storePassword", "keyAlias", "keyPassword") if not props.get(k)]
    if missing:
        fail(f"{props_path} is missing {', '.join(missing)}")
    store = (props_path.parent / props["storeFile"]).resolve()
    if not store.is_file():
        fail(f"keystore {store} not found")

    tools = build_tools()
    # 16 KB alignment for native libraries (Android 15+ page size) needs build-tools 35+.
    page = ["-P", "16"] if int(tools.name.split(".")[0]) >= 35 else ["-p"]
    env = dict(os.environ, KS_PASS=props["storePassword"], KEY_PASS=props["keyPassword"])
    with tempfile.TemporaryDirectory() as tmp:
        aligned = Path(tmp) / "aligned.apk"
        subprocess.run([tools / "zipalign", *page, "-f", "4", unsigned, aligned], check=True)
        signed.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(
            [tools / "apksigner", "sign", "--ks", store, "--ks-key-alias", props["keyAlias"],
             "--ks-pass", "env:KS_PASS", "--key-pass", "env:KEY_PASS", "--out", signed, aligned],
            check=True, env=env,
        )
    subprocess.run([tools / "apksigner", "verify", signed], check=True)
    print(f"signed {signed}")


if __name__ == "__main__":
    main()
