#!/usr/bin/env python3
"""Offline contract checks; fake Mach-O apps and subprocesses, no GUI or signing."""
import base64
from contextlib import redirect_stdout
import importlib.util
from io import StringIO
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('review_upgrade_fixture', SCRIPTS / 'prepare-review-upgrade-test.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
PUBLIC = base64.b64encode(bytes(range(32))).decode()


def thin_macho(cpu, text):
    command_size, code_offset = 152, 184
    header = struct.pack('<IiiIIIII', 0xFEEDFACF, cpu, 0, 2, 1, command_size, 0, 0)
    segment = struct.pack('<II16sQQQQiiII', 0x19, command_size, b'__TEXT', 0,
                          code_offset + len(text), 0, code_offset + len(text), 7, 5, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', code_offset, len(text),
                          code_offset, 0, 0, 0, 0, 0, 0, 0)
    return header + segment + section + text


def universal_macho(text):
    first = thin_macho(16777223, text + b'-x86')
    second = thin_macho(16777228, text + b'-arm')
    return (struct.pack('>II', 0xCAFEBABE, 2)
            + struct.pack('>iiIII', 16777223, 0, 48, len(first), 0)
            + struct.pack('>iiIII', 16777228, 0, 48 + len(first), len(second), 0)
            + first + second)


class UpgradeFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='GitPier-review-upgrade-contract-')
        self.root = Path(self.temporary.name).resolve()
        self.fixture_root = self.root / '.cache/update-acceptance/case'
        (self.fixture_root / 'server').mkdir(parents=True)
        (self.fixture_root / 'server/server.json').write_text('{"port":54321}')

    def tearDown(self):
        self.temporary.cleanup()

    def app(self, version, build):
        app = self.root / ('source-' + version) / 'GitPier.app'
        resources = app / 'Contents/Resources/GitPier_GitPier.bundle'
        resources.mkdir(parents=True)
        config = {'version': version, 'build': build, 'bundleIdentifier': fixture.BUNDLE,
                  'minimumSystemVersion': '14.0', 'feedURL': fixture.FEED, 'publicEDKey': PUBLIC}
        info = {'CFBundleIdentifier': fixture.BUNDLE, 'CFBundleShortVersionString': version,
                'CFBundleVersion': build, 'LSMinimumSystemVersion': '14.0',
                'SUFeedURL': fixture.FEED, 'SUPublicEDKey': PUBLIC, 'CFBundleIconFile': 'GitPier-fixture.icns',
                'CFBundleURLTypes': [{'CFBundleURLSchemes': ['gitpier']}]}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        (resources / 'ReleaseConfiguration.json').write_text(json.dumps(config))
        binary = app / 'Contents/MacOS/GitPier'
        binary.parent.mkdir()
        binary.write_bytes(universal_macho(version.encode()))
        binary.chmod(0o755)
        return app

    def testFixtureDirectoryRejectsParentProductionAndSymlinkEscape(self):
        self.assertEqual(fixture.fixture_directory(self.fixture_root, self.root), self.fixture_root)
        for path in [self.root, self.root / 'dist', self.fixture_root.parent]:
            with self.assertRaises(ValueError):
                fixture.fixture_directory(path, self.root)
        (self.fixture_root.parent / 'escape').symlink_to(self.root)
        with self.assertRaises(ValueError):
            fixture.fixture_directory(self.fixture_root.parent / 'escape/run', self.root)

    def testRealSourceVersionsAndArchitecturesAreRequired(self):
        app = self.app('1.6.0', '27')
        _, record = fixture.source_record(app, '1.6.0', '27')
        self.assertEqual(set(record['codeSectionSHA256']), {'16777223', '16777228'})
        with self.assertRaises(ValueError):
            fixture.source_record(app, '1.6.1', '28')
        (app / 'Contents/MacOS/GitPier').write_bytes(thin_macho(16777228, b'arm-only'))
        with self.assertRaises(ValueError):
            fixture.source_record(app, '1.6.0', '27')

    def testModifiedTestIdentityCannotMasqueradeAsOriginalSource(self):
        app = self.app('1.6.0', '27')
        info_file = app / 'Contents/Info.plist'
        info = plistlib.loads(info_file.read_bytes())
        info['CFBundleIdentifier'] = fixture.BUNDLE + '.update-test.synthetic'
        info_file.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError):
            fixture.source_record(app, '1.6.0', '27')

    def testInconsistentSourceFeedAndPublicKeyAreRejected(self):
        app = self.app('1.6.0', '27')
        info_file = app / 'Contents/Info.plist'
        info = plistlib.loads(info_file.read_bytes())
        for key, value in [('SUFeedURL', 'http://127.0.0.1:1/appcast.xml'), ('SUPublicEDKey', '')]:
            changed = dict(info, **{key: value})
            info_file.write_bytes(plistlib.dumps(changed))
            with self.assertRaises(ValueError):
                fixture.source_record(app, '1.6.0', '27')

    def testCodeFingerprintExcludesSignatureButDetectsChangedInstructions(self):
        binary = self.root / 'binary'
        original = universal_macho(b'original-code')
        binary.write_bytes(original)
        before = fixture.code_sections(binary)
        binary.write_bytes(original + b'resigned-metadata')
        self.assertEqual(fixture.code_sections(binary), before)
        binary.write_bytes(universal_macho(b'changed-code'))
        self.assertNotEqual(fixture.code_sections(binary), before)
        binary.write_bytes(b'invalid')
        with self.assertRaises(ValueError):
            fixture.code_sections(binary)

    def testLoopbackConfigurationKeepsVersionAndRequiresPrivateRuntime(self):
        source = {'version': '1.6.1', 'build': '28'}
        identity = fixture.BUNDLE + '.update-test.synthetic'
        value = fixture.test_configuration(source, identity, PUBLIC, 1234,
                    '/private/tmp/GitPier-update-acceptance-synthetic/workspace.json')
        self.assertEqual(value['feedURL'], 'http://127.0.0.1:1234/appcast.xml')
        self.assertEqual((value['version'], value['build']), ('1.6.1', '28'))
        self.assertNotIn('feedURL', source)
        for port in [0, 65536, True, '1234']:
            with self.assertRaises(ValueError):
                fixture.test_configuration(source, identity, PUBLIC, port,
                    '/private/tmp/GitPier-update-acceptance-synthetic/workspace.json')
        with self.assertRaises(ValueError):
            fixture.test_configuration(source, identity, PUBLIC, 1234, '/Users/example/workspace.json')

    def testProductionCallbackSchemeIsCompletelyReplaced(self):
        source = {'CFBundleURLTypes': [{'CFBundleURLSchemes': ['gitpier', 'other']}], 'unchanged': True}
        scheme = 'gitpier-update-test-' + 'a' * 32
        isolated = fixture.isolate_callback(source, scheme)
        self.assertEqual(isolated['CFBundleURLTypes'][0]['CFBundleURLSchemes'], [scheme])
        self.assertEqual(source['CFBundleURLTypes'][0]['CFBundleURLSchemes'], ['gitpier', 'other'])
        with self.assertRaises(ValueError):
            fixture.isolate_callback(source, 'gitpier')

    def prepare_with_fake_tools(self):
        import shutil
        old, new = self.app('1.6.0', '27'), self.app('1.6.1', '28')
        originals = {str(app): fixture.sha256(app / 'Contents/MacOS/GitPier') for app in [old, new]}
        commands = []

        def fake_run(command, **kwargs):
            commands.append(command)
            self.assertNotIn('shell', kwargs)
            if command[0] == 'ditto':
                shutil.copytree(command[1], command[2])
            elif command[:2] == ['swift', 'Scripts/make-update-test-key.swift']:
                keys = Path(command[2]); keys.mkdir()
                (keys / 'test-public-key.txt').write_text(PUBLIC)
                (keys / 'test-private-key.secret').write_text('synthetic-disposable-key')
            elif command[:2] == ['python3', 'Scripts/release_metadata.py']:
                config = json.loads(Path(command[command.index('--config') + 1]).read_text())
                info = {'CFBundleIdentifier': config['bundleIdentifier'], 'CFBundleVersion': config['build'],
                        'CFBundleShortVersionString': config['version'], 'GitPierTestWorkspacePath': config['testWorkspacePath'],
                        'CFBundleURLTypes': [{'CFBundleURLSchemes': ['gitpier']}]}
                Path(command[command.index('--plist') + 1]).write_bytes(plistlib.dumps(info))
            elif command[:2] == ['codesign', '--force']:
                with (Path(command[-1]) / 'Contents/MacOS/GitPier').open('ab') as stream:
                    stream.write(b'synthetic-new-signature')
            elif command[0] == 'Scripts/package-dmg.sh':
                self.assertTrue(command[2].endswith('/server/GitPier-1.6.1-macos-universal.dmg'))
                Path(command[2]).write_bytes(b'synthetic-DMG')
            elif Path(command[0]).name == 'generate_appcast':
                self.assertIn('--ed-key-file', command)
                (Path(command[-1]) / 'appcast.xml').write_text('<synthetic-signed-feed/>')
            elif Path(command[0]).name == 'sign_update':
                self.assertIn('--ed-key-file', command)
            else:
                self.assertTrue(command[0] == 'codesign' or command[:2] == ['python3', 'Scripts/verify-bundle.py'])

        runtime = self.root / 'runtime'
        runtime.mkdir()
        # The real function validates /private/tmp. Only the temporary runtime
        # location is substituted in this offline test; no real process runs.
        real_config = fixture.test_configuration
        def fake_config(source, identity, public, port, workspace):
            value = real_config(source, identity, public, port,
                                '/private/tmp/GitPier-update-acceptance-synthetic/workspace.json')
            value['testWorkspacePath'] = str(workspace)
            return value

        output = StringIO()
        with patch.object(fixture, 'ROOT', self.root), patch.object(fixture.subprocess, 'run', fake_run), \
             patch.object(fixture.tempfile, 'mkdtemp', return_value=str(runtime)) as runtime_factory, \
             patch.object(fixture, 'test_configuration', fake_config), redirect_stdout(output):
            fixture.prepare(self.fixture_root, old, new)
        runtime_factory.assert_called_once_with(prefix='GitPier-update-acceptance-', dir='/private/tmp')
        manifest = json.loads((self.fixture_root / 'manifest.json').read_text())
        return manifest, commands, old, new, originals, runtime, output.getvalue()

    def testPrepareRecordsRealBinariesAndNeverRunsAppOrProductionKeyTools(self):
        manifest, commands, old, new, originals, runtime, _ = self.prepare_with_fake_tools()
        self.assertEqual(manifest['status'], 'prepared')
        self.assertFalse(manifest['appsLaunched'])
        self.assertFalse(manifest['productionKeychainUsed'])
        for folder, app in [('installed', old), ('new', new)]:
            result = manifest['fixtures'][folder]
            self.assertEqual(result['copiedBinarySHA256BeforeSigning'], originals[str(app)])
            self.assertNotEqual(result['signedBinarySHA256'], originals[str(app)])
            self.assertEqual(fixture.sha256(app / 'Contents/MacOS/GitPier'), originals[str(app)])
            info = plistlib.loads((Path(result['app']) / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['CFBundleURLTypes'][0]['CFBundleURLSchemes'], [manifest['callbackScheme']])
            self.assertEqual(info['GitPierTestWorkspacePath'], str(runtime / 'workspace.json'))
        self.assertTrue(commands)
        self.assertFalse(any(Path(command[0]).name in ['open', 'defaults', 'security', 'generate_keys'] for command in commands))

    def testDefaultInstalledAppLivesWithPrivateRuntimeAndPrintedManifestPathMatches(self):
        manifest, commands, old, new, _, runtime, output = self.prepare_with_fake_tools()
        installed = runtime / 'installed/GitPier.app'
        self.assertEqual(manifest['fixtures']['installed']['app'], str(installed))
        self.assertEqual(manifest['fixtures']['new']['app'], str(self.fixture_root / 'new/GitPier.app'))
        self.assertEqual(Path(manifest['workspace']).parent, installed.parent.parent)
        self.assertFalse((self.fixture_root / 'installed').exists())
        self.assertTrue(installed.is_dir())
        self.assertEqual(installed.parent.stat().st_mode & 0o777, 0o700)
        self.assertIn(str(installed), output)
        self.assertNotIn(str(self.fixture_root / 'installed/GitPier.app'), output)
        self.assertIn(['ditto', str(old), str(installed)], commands)
        self.assertIn(['Scripts/package-dmg.sh', str(self.fixture_root / 'new/GitPier.app'),
                       str(self.fixture_root / 'server/GitPier-1.6.1-macos-universal.dmg')], commands)
        self.assertEqual(fixture.sha256(old / 'Contents/Info.plist'), manifest['oldSource']['infoSHA256'])
        self.assertEqual(fixture.sha256(new / 'Contents/Info.plist'), manifest['newSource']['infoSHA256'])
        self.assertEqual((self.fixture_root / 'keys/test-private-key.secret').read_text(), 'synthetic-disposable-key')

    def testExistingFixtureIsPreservedBeforeAnySubprocess(self):
        old, new = self.app('1.6.0', '27'), self.app('1.6.1', '28')
        sentinel = self.fixture_root / 'manifest.json'
        sentinel.write_text('keep-existing-fixture')
        with patch.object(fixture, 'ROOT', self.root), patch.object(fixture.subprocess, 'run') as runner:
            with self.assertRaises(ValueError):
                fixture.prepare(self.fixture_root, old, new)
            runner.assert_not_called()
        self.assertEqual(sentinel.read_text(), 'keep-existing-fixture')

    def testServerSymlinkOrUnrelatedServedFilesAreRejectedBeforeAnySubprocess(self):
        old, new = self.app('1.6.0', '27'), self.app('1.6.1', '28')
        server = self.fixture_root / 'server'
        (server / 'unrelated.txt').write_text('preserve')
        with patch.object(fixture, 'ROOT', self.root), patch.object(fixture.subprocess, 'run') as runner:
            with self.assertRaises(ValueError):
                fixture.prepare(self.fixture_root, old, new)
            runner.assert_not_called()
        (server / 'unrelated.txt').unlink()
        actual = self.root / 'outside-server'
        server.rename(actual)
        server.symlink_to(actual, target_is_directory=True)
        with patch.object(fixture, 'ROOT', self.root), patch.object(fixture.subprocess, 'run') as runner:
            with self.assertRaises(ValueError):
                fixture.prepare(self.fixture_root, old, new)
            runner.assert_not_called()


if __name__ == '__main__':
    unittest.main()
