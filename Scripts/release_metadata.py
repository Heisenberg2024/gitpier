#!/usr/bin/env python3
"""The checked-in ReleaseConfiguration.json is the only production version source."""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import re
from urllib.parse import urlparse

if not __debug__:
    raise RuntimeError('Release validation must run without Python optimization.')

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'Sources/GitPier/Resources/ReleaseConfiguration.json'
FEED = 'https://github.com/Heisenberg2024/gitpier/releases/latest/download/appcast.xml'
BUNDLE = 'com.heisenberg2024.gitpier'

def load(path=CONFIG):
    config = json.loads(Path(path).read_text())
    assert re.fullmatch(r'\d+\.\d+\.\d+', config['version']), 'Invalid display version'
    assert re.fullmatch(r'[1-9]\d*', config['build']), 'Invalid build number'
    assert config['minimumSystemVersion'] == '14.0', 'Unexpected system requirement'
    key = config['publicEDKey']
    assert not key or len(base64.b64decode(key, validate=True)) == 32, 'Invalid EdDSA public key'
    testing = Path(path).resolve() != CONFIG.resolve()
    if testing:
        assert config['bundleIdentifier'].startswith(BUNDLE + '.update-test.'), 'Test builds must have isolated identity'
        url = urlparse(config['feedURL'])
        assert url.scheme == 'http' and url.hostname == '127.0.0.1' and url.port and url.path == '/appcast.xml', 'Tests require a loopback feed'
        assert key, 'Test builds require an explicit test key'
        workspace = Path(config['testWorkspacePath']).resolve()
        assert (workspace.is_relative_to(ROOT / '.cache/update-acceptance') or
                str(workspace).startswith('/private/tmp/GitPier-update-acceptance-')), 'Tests require isolated persistent workspace'
    else:
        assert config['bundleIdentifier'] == BUNDLE and config['feedURL'] == FEED, 'Unexpected production identity/feed'
    return config, testing

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', default=CONFIG, type=Path)
    parser.add_argument('--field')
    parser.add_argument('--plist', type=Path)
    parser.add_argument('--icon', default='GitPier.icns')
    args = parser.parse_args()
    config, testing = load(args.config)
    if args.field:
        print(config[args.field])
    if args.plist:
        identity = os.environ.get('BUNDLE_IDENTIFIER', config['bundleIdentifier'])
        assert re.fullmatch(r'[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z][A-Za-z0-9-]*)+', identity), 'Invalid bundle identifier'
        # Non-production development IDs do not join the production trust chain.
        trusted = identity == config['bundleIdentifier']
        info = dict(CFBundleName='GitPier', CFBundleDisplayName='GitPier', CFBundleExecutable='GitPier',
                    CFBundleIdentifier=identity, CFBundlePackageType='APPL',
                    CFBundleShortVersionString=config['version'], CFBundleVersion=config['build'],
                    CFBundleIconFile=args.icon, LSMinimumSystemVersion=config['minimumSystemVersion'],
                    NSHighResolutionCapable=True, CFBundleDevelopmentRegion='en', CFBundleLocalizations=['en', 'zh-Hans'],
                    NSHumanReadableCopyright='Copyright (c) 2026 Heisenberg2024. MIT License.',
                    SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False,
                    SUSendProfileInfo=False, SUScheduledCheckInterval=86400,
                    SUVerifyUpdateBeforeExtraction=True, SURequireSignedFeed=True,
                    SUSignedFeedFailureExpirationInterval=0)
        info['CFBundleURLTypes'] = [dict(CFBundleURLName='GitPier OAuth', CFBundleURLSchemes=['gitpier'], CFBundleTypeRole='Viewer')]
        if trusted:
            info['SUFeedURL'] = config['feedURL']
            if config['publicEDKey']:
                info['SUPublicEDKey'] = config['publicEDKey']
        if testing and trusted:
            info['GitPierTestingUpdates'] = True
            info['GitPierTestWorkspacePath'] = config['testWorkspacePath']
            info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
        args.plist.write_bytes(plistlib.dumps(info))

if __name__ == '__main__':
    main()
