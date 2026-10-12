#!/usr/bin/env python3
"""Offline validation of metadata, release gates and controlled installer resources."""
import base64
import copy
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from release_metadata import load, CONFIG, ROOT

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
