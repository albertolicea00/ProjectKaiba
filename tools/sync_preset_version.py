#!/usr/bin/env python3
"""Write the versioned version name and code into the gitignored export_presets.cfg.

usage: sync_preset_version.py <export_presets.cfg> <version name> <version code>

Android presets get version/name and version/code; iOS and macOS presets get
application/short_version and application/version. Other presets and every other line are left as they are.
"""

import re
import sys
from pathlib import Path

KEYS = {
    "Android": {"version/name": '"{name}"', "version/code": "{code}"},
    "iOS": {"application/short_version": '"{name}"', "application/version": '"{code}"'},
    "macOS": {"application/short_version": '"{name}"', "application/version": '"{code}"'},
}


def main() -> None:
    path, name, code = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    lines = path.read_text().splitlines()
    platforms = {}  # preset index -> platform
    for i, line in enumerate(lines):
        m = re.fullmatch(r"\[preset\.(\d+)\]", line)
        if m:
            for following in lines[i + 1:]:
                if following.startswith("["):
                    break
                p = re.fullmatch(r'platform="([^"]+)"', following)
                if p:
                    platforms[m.group(1)] = p.group(1)

    out, keys = [], None
    for line in lines:
        m = re.fullmatch(r"\[preset\.(\d+)\.options\]", line)
        if m:
            out.append(line)
            keys = KEYS.get(platforms.get(m.group(1), ""))
            if keys:
                out.extend(f"{k}={v.format(name=name, code=code)}" for k, v in keys.items())
            continue
        if line.startswith("["):
            keys = None
        if keys and line.split("=", 1)[0] in keys:
            continue
        out.append(line)
    path.write_text("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
