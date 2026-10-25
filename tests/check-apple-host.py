#!/usr/bin/env python3
"""Compile and execute the no-library, no-listener native host self-test."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
if sys.platform != "darwin":
    print("SKIP: Apple native host requires macOS")
    raise SystemExit(0)
# Resolve /tmp to /private/tmp: Swift's PCM cache cannot mix aliases.
with tempfile.TemporaryDirectory(prefix="moments-host-") as directory:
    path = Path(directory).resolve()
    executable = path / "host"
    subprocess.run([
        "swiftc", "-module-cache-path", str(path / "modules"),
        "-swift-version", "6", "-warnings-as-errors", "-DMOMENTS_HOST",
        "-parse-as-library", str(root / "scripts/apple_photos_bridge.swift"),
        str(root / "scripts/apple_photos_host.swift"), "-o", str(executable)
    ], check=True)
    subprocess.run([str(executable), "--self-test"], check=True)
