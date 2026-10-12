#!/usr/bin/env python3
"""Switch a running isolated test feed to deterministic failure cases; no production state."""
import argparse
import base64
import json
from pathlib import Path
import re
import shutil
import subprocess
from release_metadata import ROOT

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('scenario', choices=['restore', 'invalid-feed', 'invalid-signature', 'tampered-dmg', 'download-failure'])
args = parser.parse_args()
root = args.directory.resolve()
assert root.is_relative_to(ROOT / '.cache/update-acceptance')
server = root / 'server'
backup = root / 'original-server'
archive = 'GitPier-1.1.0-macos-universal.dmg'
if not backup.exists():
    backup.mkdir()
    for name in ['appcast.xml', archive]:
        shutil.copy(server / name, backup / name)
for name in ['appcast.xml', archive]:
    shutil.copy(backup / name, server / name)
if args.scenario != 'restore':
    feed = (server / 'appcast.xml').read_text().replace('<sparkle:version>21</sparkle:version>', '<sparkle:version>22</sparkle:version>')
    if args.scenario == 'invalid-signature':
        # Change only the archive enclosure signature, then genuinely re-sign the feed.
        feed, count = re.subn(r'(<enclosure\b[^>]*sparkle:edSignature=")[^"]+', r'\g<1>' + base64.b64encode(bytes(64)).decode(), feed)
        assert count == 1
    if args.scenario == 'download-failure':
        feed = feed.replace('/' + archive, '/missing-update.dmg')
    (server / 'appcast.xml').write_text(feed)
    if args.scenario != 'invalid-feed':
        subprocess.run([str(ROOT / '.build/artifacts/sparkle/Sparkle/bin/sign_update'), '--ed-key-file', str(root / 'keys/test-private-key.secret'), str(server / 'appcast.xml')], check=True)
    if args.scenario == 'tampered-dmg':
        file = server / archive
        with file.open('r+b') as stream:
            stream.seek(4096)
            original = stream.read(1)
            stream.seek(4096)
            stream.write(bytes([original[0] ^ 1]))
print('Isolated update scenario:', args.scenario)
