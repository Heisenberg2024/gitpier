#!/usr/bin/env python3
import argparse
from pathlib import Path
import plistlib
import subprocess
from release_metadata import load, CONFIG

parser = argparse.ArgumentParser()
parser.add_argument('app', type=Path)
parser.add_argument('--config', type=Path, default=CONFIG)
parser.add_argument('universal', nargs='?', default='0')
args = parser.parse_args()
config, testing = load(args.config)
app = args.app.resolve()
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
for field, key in [('version', 'CFBundleShortVersionString'), ('build', 'CFBundleVersion'), ('minimumSystemVersion', 'LSMinimumSystemVersion')]:
    assert info[key] == config[field], f'{key} mismatch'
assert (app / 'Contents/Resources/GitPier_GitPier.bundle').is_dir(), 'Missing resources'
framework = app / 'Contents/Frameworks/Sparkle.framework'
for component in ['Sparkle', 'Autoupdate', 'Updater.app', 'XPCServices/Installer.xpc', 'XPCServices/Downloader.xpc']:
    assert (framework / 'Versions/B' / component).exists(), f'Missing Sparkle {component}'
for executable in ['Autoupdate', 'Updater.app/Contents/MacOS/Updater', 'XPCServices/Installer.xpc/Contents/MacOS/Installer', 'XPCServices/Downloader.xpc/Contents/MacOS/Downloader']:
    path = framework / 'Versions/B' / executable
    assert path.stat().st_mode & 0o111, f'Non-executable Sparkle helper: {executable}'
    assert set(subprocess.check_output(['lipo', '-archs', str(path)], text=True).split()) == {'arm64', 'x86_64'}, f'Missing helper architecture: {executable}'
assert (framework / 'Versions/Current').is_symlink() and (framework / 'Sparkle').is_symlink(), 'Framework links lost'
launcher = app / 'Contents/Helpers/gitpier'
# Historical upgrade fixtures retain their real pre-CLI bundle contents.
if tuple(map(int, config['version'].split('.'))) >= (1, 7, 0) or launcher.exists():
    assert launcher.is_file() and not launcher.is_symlink() and launcher.stat().st_mode & 0o111, 'Missing CLI launcher'
    launcher_architectures = set(subprocess.check_output(['lipo', '-archs', str(launcher)], text=True).split())
    if args.universal == '1':
        assert launcher_architectures == {'arm64', 'x86_64'}, 'Missing CLI universal slice'
    subprocess.run(['codesign', '--verify', '--strict', str(launcher)], check=True)
binary = app / 'Contents/MacOS/GitPier'
assert binary.stat().st_mode & 0o111, 'App is not executable'
architectures = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
if args.universal == '1':
    assert set(architectures) == {'arm64', 'x86_64'}, 'Missing universal slice'
assert set(subprocess.check_output(['lipo', '-archs', str(framework / 'Sparkle')], text=True).split()) == {'arm64', 'x86_64'}
dependencies = subprocess.check_output(['otool', '-L', str(binary)], text=True)
assert '@rpath/Sparkle.framework/Versions/B/Sparkle' in dependencies, 'Missing Sparkle dependency'
assert '@executable_path/../Frameworks' in subprocess.check_output(['otool', '-l', str(binary)], text=True), 'Missing runtime search path'
assert not any('/.build/' in line for line in dependencies.splitlines()), 'Build path leaked into runtime links'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
if config['publicEDKey'] and info['CFBundleIdentifier'] == config['bundleIdentifier']:
    assert info['SUPublicEDKey'] == config['publicEDKey'] and info['SUFeedURL'] == config['feedURL']
assert info['SUVerifyUpdateBeforeExtraction'] and info['SURequireSignedFeed']
assert info['SUSignedFeedFailureExpirationInterval'] == 0, 'Signed-feed failures must not expire'
assert not info['SUEnableAutomaticChecks'] and not info['SUAllowsAutomaticUpdates'] and not info['SUSendProfileInfo']
print(f'Bundle verified: {config["version"]} ({config["build"]}), {", ".join(architectures)}')
