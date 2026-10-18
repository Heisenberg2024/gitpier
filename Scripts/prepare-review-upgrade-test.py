#!/usr/bin/env python3
"""Prepare a real 1.6.0 -> 1.6.1 Sparkle fixture; never launch or install it.

Requires two already-built Universal apps and an existing serve-update-test.py
server. This invokes the normal DMG packager (including its temporary Finder
layout). The installed old app and workspace live in a private runtime outside
Documents, so the installer does not need Documents-folder privacy access. The
new app, disposable keys and served artifacts stay in the ignored fixture.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import tempfile
import uuid

from release_metadata import BUNDLE, FEED, ROOT


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def fixture_directory(path, repository=None):
    root = Path(path).resolve()
    allowed = (Path(repository or ROOT) / '.cache/update-acceptance').resolve()
    require(root != allowed and root.is_relative_to(allowed),
            'Fixture must be a child of the ignored .cache/update-acceptance directory')
    return root


def code_sections(binary):
    """Hash each Mach-O __TEXT,__text section, excluding mutable signatures."""
    data = Path(binary).read_bytes()
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        require(0 < count <= 16, 'Invalid Universal architecture count')
        size, fmt = (32, '>iiQQII') if wide else (20, '>iiIII')
        slices = []
        for index in range(count):
            entry = struct.unpack_from(fmt, data, 8 + index * size)
            slices.append((entry[2], entry[3]))
    else:
        slices = [(0, len(data))]
    result = {}
    for offset, length in slices:
        require(offset >= 0 and length >= 32 and offset + length <= len(data), 'Invalid Mach-O slice')
        part = data[offset:offset + length]
        require(part[:4] == b'\xcf\xfa\xed\xfe', 'Only little-endian 64-bit Mach-O apps are accepted')
        header = struct.unpack_from('<IiiIIIII', part)
        architecture, commands, command_bytes = header[1], header[4], header[5]
        require(0 < commands <= 4096 and 32 + command_bytes <= len(part), 'Invalid Mach-O load commands')
        cursor, found = 32, None
        for _ in range(commands):
            command, size = struct.unpack_from('<II', part, cursor)
            require(size >= 8 and cursor + size <= 32 + command_bytes, 'Invalid Mach-O command size')
            if command == 0x19:  # LC_SEGMENT_64
                require(size >= 72, 'Invalid 64-bit segment')
                section_count = struct.unpack_from('<I', part, cursor + 64)[0]
                require(72 + section_count * 80 <= size, 'Invalid Mach-O sections')
                for index in range(section_count):
                    section = cursor + 72 + index * 80
                    name = part[section:section + 16].rstrip(b'\0')
                    segment = part[section + 16:section + 32].rstrip(b'\0')
                    if (segment, name) == (b'__TEXT', b'__text'):
                        count = struct.unpack_from('<Q', part, section + 40)[0]
                        start = struct.unpack_from('<I', part, section + 48)[0]
                        require(found is None and count > 0 and start + count <= len(part), 'Invalid code section')
                        found = hashlib.sha256(part[start:start + count]).hexdigest()
            cursor += size
        require(found is not None and architecture not in result, 'Missing or duplicate code architecture')
        result[architecture] = found
    return {str(key): value for key, value in sorted(result.items())}


def source_record(app, version, build):
    app = Path(app).resolve(strict=True)
    require(app.name.endswith('.app') and app.is_dir(), 'Source must be an existing app bundle')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    config = json.loads((app / 'Contents/Resources/GitPier_GitPier.bundle/ReleaseConfiguration.json').read_text())
    require(info.get('CFBundleIdentifier') == BUNDLE and config.get('bundleIdentifier') == BUNDLE,
            'Use original production-identity source apps, not previously modified test copies')
    require(info.get('CFBundleShortVersionString') == version and config.get('version') == version,
            f'Source app must really be version {version}')
    require(info.get('CFBundleVersion') == build and config.get('build') == build,
            f'Source app must really be build {build}')
    require(info.get('LSMinimumSystemVersion') == config.get('minimumSystemVersion') == '14.0',
            'Unexpected source minimum system version')
    require(info.get('SUFeedURL') == config.get('feedURL') == FEED, 'Unexpected source update feed')
    public = config.get('publicEDKey', '')
    require(len(base64.b64decode(public, validate=True)) == 32 and info.get('SUPublicEDKey') == public,
            'Source signing configuration is inconsistent')
    binary = app / 'Contents/MacOS/GitPier'
    sections = code_sections(binary)
    require(set(sections) == {'16777223', '16777228'}, 'Source app must contain x86_64 and arm64 code')
    return config, {
        'path': str(app), 'version': version, 'build': build,
        'infoSHA256': sha256(app / 'Contents/Info.plist'),
        'binarySHA256': sha256(binary), 'codeSectionSHA256': sections,
    }


def test_configuration(source, identity, public, port, workspace):
    require(identity.startswith(BUNDLE + '.update-test.'), 'Test identity is required')
    require(isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535, 'Invalid loopback port')
    require(len(base64.b64decode(public, validate=True)) == 32, 'Invalid disposable public key')
    workspace = Path(workspace).resolve()
    require(str(workspace).startswith('/private/tmp/GitPier-update-acceptance-'), 'Runtime must be isolated in /private/tmp')
    value = dict(source)
    value.update(bundleIdentifier=identity, publicEDKey=public,
                 feedURL=f'http://127.0.0.1:{port}/appcast.xml', testWorkspacePath=str(workspace))
    return value


def isolate_callback(info, scheme):
    require(re.fullmatch(r'gitpier-update-test-[a-f0-9]{32}', scheme) is not None, 'Invalid test callback scheme')
    value = dict(info)
    value['CFBundleURLTypes'] = [{
        'CFBundleURLName': 'GitPier isolated update fixture',
        'CFBundleURLSchemes': [scheme], 'CFBundleTypeRole': 'Viewer',
    }]
    return value


def prepare(directory, old_app, new_app):
    root = fixture_directory(directory)
    server = root / 'server'
    require(server.is_dir() and server.resolve() == server, 'Server must be a real directory inside this fixture')
    server_state = server / 'server.json'
    require(server_state.is_file() and not server_state.is_symlink(), 'Server state must be a regular fixture file')
    require({path.name for path in server.iterdir()} == {'server.json'}, 'Use a fresh fixture server directory')
    port = json.loads(server_state.read_text())['port']
    require(isinstance(port, int) and not isinstance(port, bool) and 1 <= port <= 65535, 'Invalid server port')
    old_config, old = source_record(old_app, '1.6.0', '27')
    new_config, new = source_record(new_app, '1.6.1', '28')
    require(old['binarySHA256'] != new['binarySHA256'], 'Old and new apps must have different real binaries')
    require(old_config['publicEDKey'] == new_config['publicEDKey'], 'Production public key must remain unchanged')
    for name in ['installed', 'new', 'keys', 'manifest.json', 'runtime-root.txt']:
        require(not (root / name).exists() and not (root / name).is_symlink(), f'Refusing to overwrite fixture {name}')
    archive_name = f'GitPier-{new_config["version"]}-macos-universal.dmg'
    for name in [archive_name, 'appcast.xml']:
        require(not (server / name).exists(), f'Refusing to overwrite served {name}')
    identity_suffix = uuid.uuid4().hex
    identity = BUNDLE + '.update-test.review-' + identity_suffix
    scheme = 'gitpier-update-test-' + identity_suffix
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(ROOT / '.cache/clang'))
    runtime = Path(tempfile.mkdtemp(prefix='GitPier-update-acceptance-', dir='/private/tmp'))
    (root / 'runtime-root.txt').write_text(str(runtime) + '\n')
    workspace = runtime / 'workspace.json'
    shell = runtime / 'fixture-shell.sh'
    shell.write_text('#!/bin/sh\nexec /bin/bash --noprofile --norc -i\n')
    shell.chmod(0o700)
    workspace.write_text(json.dumps({'version': 2, 'settings': {
        'shellPath': str(shell), 'loginShell': False, 'language': 'english'}}))
    workspace.chmod(0o600)
    manifest = {'status': 'preparing', 'bundleIdentifier': identity, 'callbackScheme': scheme,
                'feedURL': f'http://127.0.0.1:{port}/appcast.xml', 'runtime': str(runtime),
                'workspace': str(workspace), 'oldSource': old, 'newSource': new,
                'appsLaunched': False, 'productionKeychainUsed': False, 'fixtures': {}}

    def checkpoint():
        (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')

    checkpoint()
    subprocess.run(['swift', 'Scripts/make-update-test-key.swift', str(root / 'keys')], cwd=ROOT, env=env, check=True)
    public = (root / 'keys/test-public-key.txt').read_text().strip()
    for folder, config, source in [('installed', old_config, old), ('new', new_config, new)]:
        app = (runtime if folder == 'installed' else root) / folder / 'GitPier.app'
        app.parent.mkdir(mode=0o700)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', source['path']], check=True)
        subprocess.run(['ditto', source['path'], str(app)], check=True)
        binary = app / 'Contents/MacOS/GitPier'
        copied_hash = sha256(binary)
        require(copied_hash == source['binarySHA256'], 'ditto changed the source binary')
        metadata = root / (folder + '.json')
        metadata.write_text(json.dumps(test_configuration(config, identity, public, port, workspace), indent=2))
        icon = plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleIconFile']
        subprocess.run(['python3', 'Scripts/release_metadata.py', '--config', str(metadata),
                        '--plist', str(app / 'Contents/Info.plist'), '--icon', icon], cwd=ROOT, check=True)
        info_file = app / 'Contents/Info.plist'
        info_file.write_bytes(plistlib.dumps(isolate_callback(plistlib.loads(info_file.read_bytes()), scheme)))
        (app / 'Contents/Resources/GitPier_GitPier.bundle/ReleaseConfiguration.json').write_bytes(metadata.read_bytes())
        subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
        require(code_sections(binary) == source['codeSectionSHA256'], 'Fixture code differs from its real source app')
        subprocess.run(['python3', 'Scripts/verify-bundle.py', str(app), '--config', str(metadata), '1'], cwd=ROOT, check=True)
        manifest['fixtures'][folder] = {'app': str(app), 'config': str(metadata),
            'copiedBinarySHA256BeforeSigning': copied_hash, 'signedBinarySHA256': sha256(binary),
            'codeSectionSHA256': code_sections(binary), 'infoSHA256': sha256(info_file)}
        checkpoint()
    env['GITPIER_TEST_RELEASE_CONFIG'] = str(root / 'new.json')
    archive = server / archive_name
    subprocess.run(['Scripts/package-dmg.sh', str(root / 'new/GitPier.app'), str(archive)], cwd=ROOT, env=env, check=True)
    (server / (archive.stem + '.md')).write_text('Isolated GitPier 1.6.0 (27) to 1.6.1 (28) upgrade acceptance.\n')
    tools = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
    private = root / 'keys/test-private-key.secret'
    subprocess.run([str(tools / 'generate_appcast'), '--ed-key-file', str(private), '--maximum-deltas', '0',
                    '--embed-release-notes', '--download-url-prefix', f'http://127.0.0.1:{port}/', str(server)], check=True)
    subprocess.run([str(tools / 'sign_update'), '--ed-key-file', str(private), '--verify', str(server / 'appcast.xml')], check=True)
    manifest.update(status='prepared', archive=str(archive), archiveSHA256=sha256(archive),
                    feedSHA256=sha256(server / 'appcast.xml'))
    checkpoint()
    print(f'Prepared isolated 1.6.0 (27) -> 1.6.1 (28): {manifest["fixtures"]["installed"]["app"]}')
    print('No app was launched. Installation, post-relaunch data checks and exact fixture cleanup remain separate acceptance steps.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--old-app', required=True, type=Path)
    parser.add_argument('--new-app', required=True, type=Path)
    args = parser.parse_args()
    prepare(args.directory, args.old_app, args.new_app)


if __name__ == '__main__':
    main()
