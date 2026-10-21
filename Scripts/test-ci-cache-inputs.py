#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location('ci_cache_inputs', Path(__file__).with_name('ci_cache_inputs.py'))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
CONTEXT = 'a' * 64
ORIGINAL = 1_700_000_000_123_456_789
FRESH = ORIGINAL + 10_000_000_000


class InputTimestampTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='gitpier-ci-inputs-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ, GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
        subprocess.run(['git', 'init', '-q', str(self.root)], env=self.environment, check=True)
        self.source = self.root / 'Sources' / 'Example.swift'
        self.source.parent.mkdir()
        self.source.write_text('original')
        os.utime(self.source, ns=(ORIGINAL, ORIGINAL))
        subprocess.run(['git', '--literal-pathspecs', '-C', str(self.root), 'add', '--', 'Sources'], env=self.environment, check=True)

    @property
    def snapshot(self):
        return self.root / '.cache' / 'swiftpm' / cache.SNAPSHOT

    def saved(self):
        self.assertEqual(cache.capture(self.root, CONTEXT), 1)
        os.utime(self.source, ns=(FRESH, FRESH))

    def edit_snapshot(self, change):
        value = json.loads(self.snapshot.read_text())
        change(value)
        self.snapshot.write_text(json.dumps(value))

    def test_restores_matching_contents_after_checkout_replaces_inode(self):
        self.saved()
        fresh = self.source.with_suffix('.fresh')
        fresh.write_bytes(self.source.read_bytes())
        os.utime(fresh, ns=(FRESH, FRESH))
        os.replace(fresh, self.source)
        self.assertEqual(cache.restore(self.root, CONTEXT), 1)
        self.assertEqual(self.source.stat().st_mtime_ns, ORIGINAL)
        self.assertEqual(self.source.read_text(), 'original')

    def test_changed_same_length_contents_keep_fresh_timestamp(self):
        self.saved()
        self.source.write_text('modified')
        os.utime(self.source, ns=(FRESH, FRESH))
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, FRESH)

    def test_other_toolchain_context_never_restores(self):
        self.saved()
        self.assertEqual(cache.restore(self.root, 'b' * 64), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, FRESH)

    def test_changed_mode_keeps_fresh_timestamp(self):
        self.saved()
        self.source.chmod(0o755)
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, FRESH)

    def test_missing_or_invalid_snapshot_is_optional(self):
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.saved()
        for content in ('{', '[]', 'null', '{"version": 1}', 'x' * (cache.MAX_SNAPSHOT_BYTES + 1)):
            with self.subTest(size=len(content)):
                self.snapshot.write_text(content)
                self.assertEqual(cache.restore(self.root, CONTEXT), 0)
                self.assertEqual(self.source.stat().st_mtime_ns, FRESH)

    def test_invalid_record_timestamp_digest_and_version_are_ignored(self):
        for bad in (True, -1, 2**63, '123', None):
            with self.subTest(timestamp=bad):
                self.saved()
                self.edit_snapshot(lambda v: v['files']['Sources/Example.swift'].update(mtime_ns=bad))
                self.assertEqual(cache.restore(self.root, CONTEXT), 0)
                self.assertEqual(self.source.stat().st_mtime_ns, FRESH)
        self.saved()
        self.edit_snapshot(lambda v: v['files']['Sources/Example.swift'].update(sha256='not-a-hash'))
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.saved()
        self.edit_snapshot(lambda v: v.update(version=True))
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)

    def test_cache_paths_cannot_add_untracked_or_outside_inputs(self):
        self.saved()
        untracked = self.root / 'Sources' / 'Untracked.swift'
        untracked.write_text('original')
        os.utime(untracked, ns=(FRESH, FRESH))
        def inject(value):
            record = value['files']['Sources/Example.swift']
            for path in ('Sources/Untracked.swift', '../outside', '/tmp/outside', 'Sources/../outside'):
                value['files'][path] = record
        self.edit_snapshot(inject)
        self.assertEqual(cache.restore(self.root, CONTEXT), 1)
        self.assertEqual(untracked.stat().st_mtime_ns, FRESH)

    def test_source_symlink_is_not_followed(self):
        self.saved()
        victim = self.root / 'victim'
        victim.write_text('original')
        os.utime(victim, ns=(FRESH, FRESH))
        self.source.unlink()
        self.source.symlink_to(victim)
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual(victim.stat().st_mtime_ns, FRESH)
        self.assertEqual(cache.capture(self.root, CONTEXT), 0)

    def test_source_parent_symlink_is_not_followed(self):
        self.saved()
        moved = self.root / 'moved'
        self.source.parent.rename(moved)
        (self.root / 'Sources').symlink_to(moved, target_is_directory=True)
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual((moved / 'Example.swift').stat().st_mtime_ns, FRESH)

    def test_metadata_and_cache_directory_symlinks_are_not_followed(self):
        self.saved()
        payload = self.snapshot.read_bytes()
        victim = self.root / 'victim.json'
        victim.write_bytes(payload)
        self.snapshot.unlink()
        self.snapshot.symlink_to(victim)
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.snapshot.unlink()
        shutil.rmtree(self.snapshot.parent)
        self.snapshot.parent.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            cache.capture(self.root, CONTEXT)
        self.assertEqual(victim.read_bytes(), payload)

    def test_capture_atomic_replace_does_not_follow_existing_metadata_symlink(self):
        self.saved()
        victim = self.root / 'victim'
        victim.write_text('keep')
        self.snapshot.unlink()
        self.snapshot.symlink_to(victim)
        self.assertEqual(cache.capture(self.root, CONTEXT), 1)
        self.assertFalse(self.snapshot.is_symlink())
        self.assertEqual(victim.read_text(), 'keep')

    def test_hard_linked_input_never_changes_another_alias(self):
        self.saved()
        alias = self.root / 'alias'
        os.link(self.source, alias)
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual(alias.stat().st_mtime_ns, FRESH)
        self.assertEqual(cache.capture(self.root, CONTEXT), 0)

    def test_nonregular_cached_snapshot_and_input_do_not_block(self):
        self.saved()
        self.snapshot.unlink()
        os.mkfifo(self.snapshot)
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.snapshot.unlink()
        cache.capture(self.root, CONTEXT)
        self.source.unlink()
        os.mkfifo(self.source)
        self.assertEqual(cache.restore(self.root, CONTEXT), 0)

    def test_input_changed_during_hash_is_not_restored(self):
        self.saved()
        identity = self.source.stat()
        original_read = os.read
        def changing_read(fd, count):
            data = original_read(fd, count)
            info = os.fstat(fd)
            if data and (info.st_dev, info.st_ino) == (identity.st_dev, identity.st_ino):
                os.utime(self.source, ns=(FRESH + 1, FRESH + 1))
            return data
        with mock.patch.object(cache.os, 'read', side_effect=changing_read):
            self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, FRESH + 1)

    def test_same_length_write_during_hash_cannot_hide_by_restoring_mtime(self):
        self.saved()
        identity = self.source.stat()
        original_read = os.read
        def changing_read(fd, count):
            data = original_read(fd, count)
            info = os.fstat(fd)
            if data and (info.st_dev, info.st_ino) == (identity.st_dev, identity.st_ino):
                self.source.write_text('modified')
                os.utime(self.source, ns=(FRESH, FRESH))
            return data
        with mock.patch.object(cache.os, 'read', side_effect=changing_read):
            self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual(self.source.read_text(), 'modified')
        self.assertEqual(self.source.stat().st_mtime_ns, FRESH)

    def test_invalid_context_is_rejected_before_writing(self):
        for context in ('', 'a' * 63, 'A' * 64, '../outside', None):
            with self.subTest(context=context):
                with self.assertRaises(ValueError):
                    cache.capture(self.root, context)
                with self.assertRaises(ValueError):
                    cache.restore(self.root, context)
        self.assertFalse(self.snapshot.exists())

    def test_change_after_hash_before_restore_is_rejected(self):
        self.saved()
        original_fingerprint = cache.fingerprint
        def changed_after_hash(fd):
            result = original_fingerprint(fd)
            self.source.write_text('modified')
            os.utime(self.source, ns=(FRESH, FRESH))
            return result
        with mock.patch.object(cache, 'fingerprint', side_effect=changed_after_hash):
            self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual(self.source.read_text(), 'modified')
        self.assertEqual(self.source.stat().st_mtime_ns, FRESH)

    def test_mode_change_after_hash_before_restore_is_rejected(self):
        self.saved()
        original_fingerprint = cache.fingerprint
        def changed_after_hash(fd):
            result = original_fingerprint(fd)
            self.source.chmod(0o755)
            return result
        with mock.patch.object(cache, 'fingerprint', side_effect=changed_after_hash):
            self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertEqual(self.source.stat().st_mtime_ns, FRESH)

    def test_change_at_timestamp_write_does_not_leave_a_stale_cache_timestamp(self):
        self.saved()
        original_utime = os.utime
        injected = False
        def changing_utime(fd, *args, **kwargs):
            nonlocal injected
            if isinstance(fd, int) and kwargs.get('ns') and not injected:
                injected = True
                self.source.write_text('modified')
            return original_utime(fd, *args, **kwargs)
        with mock.patch.object(cache.os, 'utime', side_effect=changing_utime):
            self.assertEqual(cache.restore(self.root, CONTEXT), 0)
        self.assertTrue(injected)
        self.assertEqual(self.source.read_text(), 'modified')
        self.assertNotEqual(self.source.stat().st_mtime_ns, ORIGINAL)


if __name__ == '__main__':
    unittest.main()
