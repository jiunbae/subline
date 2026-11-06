#!/usr/bin/env python3
"""Back up / restore the app's Recently Played list around tests that play synthetic or test videos.
usage: recents.py save FILE | restore FILE"""
import plistlib, subprocess, sys
op, f = sys.argv[1], sys.argv[2]
D = "dev.jiun.subline"
if op == "save":
    d = plistlib.loads(subprocess.run(["defaults", "export", D, "-"], capture_output=True).stdout)
    open(f, "wb").write(d.get("recents", b"[]"))
else:
    data = open(f, "rb").read()
    subprocess.run(["defaults", "write", D, "recents", "-data", data.hex()], check=True)
