#!/usr/bin/env python3
"""Prepare two isolated adhoc apps and a genuinely signed DMG/appcast using a disposable key."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid
from release_metadata import CONFIG, ROOT

parser = argparse.ArgumentParser()
parser.add_argument('directory', type=Path)
parser.add_argument('--app', type=Path, default=ROOT / 'dist/GitPier.app')
args = parser.parse_args()
root = args.directory.resolve()
assert root.is_relative_to(ROOT / '.cache/update-acceptance'), 'Fixture must be ignored and isolated'
server = root / 'server'
port = json.loads((server / 'server.json').read_text())['port']
identity = 'com.heisenberg2024.gitpier.update-test.run-' + uuid.uuid4().hex
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / '.cache/clang'))
subprocess.run(['swift', 'Scripts/make-update-test-key.swift', str(root / 'keys')], env=env, check=True)
public = (root / 'keys/test-public-key.txt').read_text()
runtime = Path(tempfile.mkdtemp(prefix='GitPier-update-acceptance-', dir='/private/tmp'))
(root / 'runtime-root.txt').write_text(str(runtime))
shell = runtime / 'fixture-shell.sh'
shell.write_text('#!/bin/sh\nexec /bin/bash --noprofile --norc -i\n')
shell.chmod(0o700)
workspace = runtime / 'workspace.json'
assert not workspace.exists(), 'Refusing to replace an existing test workspace'
workspace.write_text(json.dumps({'version': 2, 'settings': {'shellPath': str(shell), 'loginShell': False, 'language': 'english'}}))
workspace.chmod(0o600)
for build, folder in [('20', 'installed'), ('21', 'new')]:
    app = root / folder / 'GitPier.app'
    assert not app.exists(), 'Refusing to replace an existing test app'
    app.parent.mkdir(parents=True)
    subprocess.run(['ditto', str(args.app), str(app)], check=True)
    config = json.loads(CONFIG.read_text())
    config.update(build=build, bundleIdentifier=identity, publicEDKey=public,
                  feedURL=f'http://127.0.0.1:{port}/appcast.xml', testWorkspacePath=str(workspace))
    metadata = root / (folder + '.json')
    metadata.write_text(json.dumps(config, indent=2))
    subprocess.run(['python3', 'Scripts/release_metadata.py', '--config', str(metadata), '--plist', str(app / 'Contents/Info.plist'), '--icon', next((app / 'Contents/Resources').glob('GitPier-*.icns')).name], check=True)
    shutil.copy(metadata, app / 'Contents/Resources/GitPier_GitPier.bundle/ReleaseConfiguration.json')
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['python3', 'Scripts/verify-bundle.py', str(app), '--config', str(metadata), '1'], check=True)
env['GITPIER_TEST_RELEASE_CONFIG'] = str(root / 'new.json')
dmg = server / 'GitPier-1.1.0-macos-universal.dmg'
subprocess.run(['Scripts/package-dmg.sh', str(root / 'new/GitPier.app'), str(dmg)], env=env, check=True)
(server / 'GitPier-1.1.0-macos-universal.md').write_text('GitPier isolated update acceptance: Build 20 → Build 21.\n')
tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
subprocess.run([str(tools / 'generate_appcast'), '--ed-key-file', str(root / 'keys/test-private-key.secret'), '--maximum-deltas', '0', '--embed-release-notes', '--download-url-prefix', f'http://127.0.0.1:{port}/', str(server)], check=True)
subprocess.run([str(tools / 'sign_update'), '--ed-key-file', str(root / 'keys/test-private-key.secret'), '--verify', str(server / 'appcast.xml')], check=True)
print(f'Fixture ready: {root / "installed/GitPier.app"}; isolated identity {identity}')
