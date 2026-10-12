#!/usr/bin/env python3
"""Sign nested Sparkle code from the inside out; the caller signs the app last."""
from pathlib import Path
import subprocess
import sys

app = Path(sys.argv[1]).resolve()
framework = app / 'Contents/Frameworks/Sparkle.framework'
assert framework.is_dir()
magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
for path in sorted(framework.rglob('*'), key=lambda p: len(p.parts), reverse=True):
    if path.is_symlink():
        continue
    is_bundle = path.is_dir() and path.suffix in {'.app', '.xpc', '.framework'}
    is_code = path.is_file() and path.open('rb').read(4) in magic
    if is_bundle or is_code:
        subprocess.run(['codesign', '--force', '--sign', sys.argv[2], '--preserve-metadata=identifier,entitlements', str(path)], check=True)
subprocess.run(['codesign', '--force', '--sign', sys.argv[2], str(framework)], check=True)

