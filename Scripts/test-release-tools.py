#!/usr/bin/env python3
"""Offline validation of metadata, release gates and controlled installer resources."""
import base64
import copy
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from release_metadata import load, CONFIG, ROOT

class DiskImageRetryTests(unittest.TestCase):
    def run_create(self, failures):
        temporary = tempfile.TemporaryDirectory(prefix='GitPier-dmg-retry-')
        self.addCleanup(temporary.cleanup)
        folder = Path(temporary.name)
        fake = folder / 'hdiutil'
        fake.write_text(f'''#!{sys.executable}
import json, os, pathlib, sys
root = pathlib.Path(os.environ['GITPIER_DMG_TEST_ROOT'])
counter = root / 'count'
count = int(counter.read_text()) if counter.exists() else 0
counter.write_text(str(count + 1))
with (root / 'arguments').open('a') as log:
    log.write(json.dumps(sys.argv[1:]) + '\\n')
failures = json.loads(os.environ['GITPIER_DMG_TEST_FAILURES'])
if count < len(failures):
    print(failures[count], file=sys.stderr)
    pathlib.Path(sys.argv[-1]).write_text('incomplete image')
    sys.exit(1)
pathlib.Path(sys.argv[-1]).write_text('completed image')
''')
        fake.chmod(0o700)
        sleeper = folder / 'sleep'
        sleeper.write_text('#!/bin/bash\nprintf "%s\\n" "$1" >> "$GITPIER_DMG_TEST_ROOT/delays"\n')
        sleeper.chmod(0o700)
        environment = dict(os.environ, PATH=str(folder) + ':' + os.environ['PATH'],
                           GITPIER_DMG_TEST_ROOT=str(folder),
                           GITPIER_DMG_TEST_FAILURES=json.dumps(failures))
        result = subprocess.run(['/bin/bash', '-c',
            'set -euo pipefail; source "$1"; gitpier_create_temporary_dmg "$2" "$3" "$4"',
            'dmg-test', str(ROOT / 'Scripts/disk-image-helpers.sh'), str(folder),
            str(folder / 'fixture.dmg'), 'Unique Test Volume'],
            env=environment, capture_output=True, text=True)
        return folder, result

    def test_busy_creation_retries_with_unique_images_and_preserves_diagnostics(self):
        folder, result = self.run_create(['hdiutil: create failed - Resource busy'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((folder / 'count').read_text(), '2')
        self.assertEqual((folder / 'delays').read_text(), '1\n')
        self.assertEqual((folder / 'fixture.dmg').read_text(), 'completed image')
        arguments = [json.loads(line) for line in (folder / 'arguments').read_text().splitlines()]
        self.assertNotEqual(arguments[0][-1], arguments[1][-1])
        self.assertIn('Unique Test Volume', arguments[0])
        self.assertIn('Resource busy', result.stderr)
        self.assertEqual(len(list(folder.glob('*.log'))), 2)

    def test_busy_exhaustion_stops_after_three_attempts(self):
        folder, result = self.run_create(['hdiutil: create failed - Resource busy'] * 4)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((folder / 'count').read_text(), '3')
        self.assertEqual((folder / 'delays').read_text(), '1\n2\n')
        self.assertFalse((folder / 'fixture.dmg').exists())
        self.assertEqual(result.stderr.count('hdiutil: create failed - Resource busy'), 3)

    def test_other_failures_are_not_retried(self):
        for message in ['hdiutil: create failed - Permission denied', 'unrelated Resource busy']:
            with self.subTest(message=message):
                folder, result = self.run_create([message])
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((folder / 'count').read_text(), '1')
                self.assertFalse((folder / 'delays').exists())

    def test_nonbusy_failure_after_retry_stops(self):
        folder, result = self.run_create(['hdiutil: create failed - Resource busy',
                                          'hdiutil: create failed - No space left on device'])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((folder / 'count').read_text(), '2')
        self.assertIn('No space left on device', result.stderr)

class ReleaseToolsTests(unittest.TestCase):
    def test_production_configuration(self):
        config, testing = load()
        self.assertFalse(testing)
        self.assertGreater(int(config['build']), 16)
        self.assertEqual(config['bundleIdentifier'], 'com.heisenberg2024.gitpier')

    def test_generated_plist_matches_single_source_and_secure_defaults(self):
        with tempfile.TemporaryDirectory(prefix='GitPier-release-tests-') as folder:
            path = Path(folder) / 'Info.plist'
            subprocess.run(['python3', 'Scripts/release_metadata.py', '--plist', str(path)], check=True)
            info = plistlib.loads(path.read_bytes())
            config, _ = load()
            self.assertEqual(info['CFBundleVersion'], config['build'])
            self.assertEqual(info['CFBundleShortVersionString'], config['version'])
            for key in ['SUEnableAutomaticChecks', 'SUAllowsAutomaticUpdates', 'SUAutomaticallyUpdate', 'SUSendProfileInfo']:
                self.assertFalse(info[key])
            self.assertTrue(info['SURequireSignedFeed'])
            self.assertTrue(info['SUVerifyUpdateBeforeExtraction'])
            self.assertEqual(info['SUSignedFeedFailureExpirationInterval'], 0)
            self.assertNotIn('GitPierTestWorkspacePath', info)
            if not config['publicEDKey']:
                self.assertNotIn('SUPublicEDKey', info)
            else:
                self.assertEqual(info['SUPublicEDKey'], config['publicEDKey'])
                self.assertEqual(len(base64.b64decode(info['SUPublicEDKey'], validate=True)), 32)

    def test_invalid_metadata_and_unisolated_test_overrides_are_rejected(self):
        config, _ = load()
        with tempfile.TemporaryDirectory(prefix='GitPier-release-tests-') as folder:
            file = Path(folder) / 'invalid.json'
            for field, value in [('build', '0'), ('build', '17;bad'), ('version', '1.1.0-beta'), ('publicEDKey', 'bad'), ('feedURL', 'http://example.invalid/feed')]:
                invalid = copy.deepcopy(config)
                invalid[field] = value
                file.write_text(json.dumps(invalid))
                with self.assertRaises((AssertionError, ValueError)):
                    load(file)
            file.write_text(json.dumps(config))
            with self.assertRaises(AssertionError):
                load(file)

    def test_installer_background_dimensions(self):
        data = (ROOT / 'Resources/Installer/background@2x.png').read_bytes()
        self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
        self.assertEqual(struct.unpack('>II', data[16:24]), (1440, 840))
        self.assertTrue((ROOT / 'Resources/Installer/background.tiff').stat().st_size > 0)

    def test_unsigned_production_release_gate(self):
        config, _ = load()
        result = subprocess.run(['Scripts/package-release.sh'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        if config['publicEDKey']:
            self.assertIn('Usage:', result.stderr)
        else:
            self.assertIn('production key', result.stderr)
        result = subprocess.run(['Scripts/sign-release.sh', '/tmp/no-such.dmg', '/tmp/no-such.md'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        if config['publicEDKey']:
            self.assertIn('Unexpected release filename', result.stderr)
        else:
            self.assertIn('publicEDKey is missing', result.stderr)

    def test_optimized_python_cannot_disable_release_validation(self):
        result = subprocess.run(['python3', '-O', 'Scripts/release_metadata.py', '--field', 'version'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('without Python optimization', result.stderr)

if __name__ == '__main__':
    unittest.main()
