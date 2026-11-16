#!/usr/bin/env python3
"""Refresh the entrypoint's pinned doctor digest after changing the doctor.

Run python3 bin/fm-remote-doctor-digest.py from any working directory.
"""

import hashlib
import re
from pathlib import Path


directory = Path(__file__).resolve().parent
digest = hashlib.sha256((directory / "fm-remote-doctor.sh").read_bytes()).hexdigest()
entrypoint = directory / "fm-remote-entrypoint.sh"
original = entrypoint.read_text()
updated, count = re.subn(
    r"^DOCTOR_SHA256=[0-9a-f]{64}$",
    f"DOCTOR_SHA256={digest}",
    original,
    flags=re.MULTILINE,
)
if count != 1:
    raise SystemExit("expected exactly one pinned doctor digest")
if updated != original:
    entrypoint.write_text(updated)
print(digest)
