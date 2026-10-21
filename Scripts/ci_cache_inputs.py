#!/usr/bin/env python3
"""Restore portable SwiftPM input timestamps only for identical tracked contents."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import uuid


SNAPSHOT = 'gitpier-input-timestamps-v1.json'
MAX_SNAPSHOT_BYTES = 2 * 1024 * 1024
MAX_TIMESTAMP = 2**63 - 1
ROOT = Path(__file__).resolve().parent.parent


def tracked_inputs(root):
    output = subprocess.check_output(
        ['git', '--literal-pathspecs', 'ls-files', '-z', '--',
         'Sources', 'Tests', 'Resources', 'Package.swift', 'Package.resolved'],
        cwd=root, timeout=30,
    )
    return sorted(set(os.fsdecode(path) for path in output.split(b'\0') if path))


def open_directory(parent, components, create=False):
    fd = os.dup(parent)
    try:
        for component in components:
            if component in ('', '.', '..') or '/' in component:
                raise ValueError('Invalid directory component')
            if create:
                try:
                    os.mkdir(component, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def input_descriptor(root_fd, path):
    components = path.split('/')
    if any(part in ('', '.', '..') for part in components) or path.startswith('/'):
        raise ValueError('Invalid input path')
    parent = open_directory(root_fd, components[:-1])
    try:
        return os.open(components[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=parent)
    finally:
        os.close(parent)


def fingerprint(fd):
    before = os.fstat(fd)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError('Input is not an independent regular file')
    digest = hashlib.sha256()
    for chunk in iter(lambda: os.read(fd, 256 * 1024), b''):
        digest.update(chunk)
    after = os.fstat(fd)
    identity = lambda value: (value.st_dev, value.st_ino, value.st_nlink, value.st_mode,
                              value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if identity(before) != identity(after):
        raise ValueError('Input changed while hashing')
    return digest.hexdigest(), before


def valid_context(context):
    return isinstance(context, str) and re.fullmatch(r'[0-9a-f]{64}', context) is not None


def capture(root, context):
    if not valid_context(context):
        raise ValueError('Invalid toolchain context')
    files = {}
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        for path in tracked_inputs(root):
            try:
                fd = input_descriptor(root_fd, path)
                try:
                    digest, info = fingerprint(fd)
                    files[path] = {'sha256': digest, 'mtime_ns': info.st_mtime_ns, 'mode': stat.S_IMODE(info.st_mode)}
                finally:
                    os.close(fd)
            except (OSError, ValueError):
                continue
        payload = json.dumps({'version': 1, 'context': context, 'files': files}, sort_keys=True).encode()
        if len(payload) > MAX_SNAPSHOT_BYTES:
            raise ValueError('Input snapshot exceeds limit')
        cache_fd = open_directory(root_fd, ['.cache', 'swiftpm'], create=True)
        temporary = '.' + SNAPSHOT + '.' + uuid.uuid4().hex
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=cache_fd)
            with os.fdopen(fd, 'wb') as output:
                output.write(payload)
            os.replace(temporary, SNAPSHOT, src_dir_fd=cache_fd, dst_dir_fd=cache_fd)
        finally:
            try:
                os.unlink(temporary, dir_fd=cache_fd)
            except FileNotFoundError:
                pass
            os.close(cache_fd)
    finally:
        os.close(root_fd)
    return len(files)


def restore(root, context):
    if not valid_context(context):
        raise ValueError('Invalid toolchain context')
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        try:
            cache_fd = open_directory(root_fd, ['.cache', 'swiftpm'])
            try:
                fd = os.open(SNAPSHOT, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=cache_fd)
                with os.fdopen(fd, 'rb') as source:
                    info = os.fstat(source.fileno())
                    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                        return 0
                    payload = source.read(MAX_SNAPSHOT_BYTES + 1)
            finally:
                os.close(cache_fd)
            if len(payload) > MAX_SNAPSHOT_BYTES:
                return 0
            snapshot = json.loads(payload)
        except (OSError, ValueError, UnicodeError):
            return 0
        if (not isinstance(snapshot, dict) or type(snapshot.get('version')) is not int
                or snapshot['version'] != 1 or snapshot.get('context') != context
                or not isinstance(snapshot.get('files'), dict)):
            return 0
        restored = 0
        # Iteration comes from the current Git index, never from cached path names.
        for path in tracked_inputs(root):
            record = snapshot['files'].get(path)
            if not isinstance(record, dict):
                continue
            timestamp, digest, mode = record.get('mtime_ns'), record.get('sha256'), record.get('mode')
            if (type(timestamp) is not int or not 0 <= timestamp <= MAX_TIMESTAMP
                    or type(mode) is not int or not 0 <= mode <= 0o7777
                    or not isinstance(digest, str) or re.fullmatch(r'[0-9a-f]{64}', digest) is None):
                continue
            try:
                fd = input_descriptor(root_fd, path)
                try:
                    current, info = fingerprint(fd)
                    if current == digest and stat.S_IMODE(info.st_mode) == mode:
                        os.utime(fd, ns=(info.st_atime_ns, timestamp))
                        restored += 1
                finally:
                    os.close(fd)
            except (OSError, ValueError):
                continue
        return restored
    finally:
        os.close(root_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('capture', 'restore'))
    parser.add_argument('--context', required=True)
    args = parser.parse_args()
    operation = capture if args.operation == 'capture' else restore
    count = operation(ROOT, args.context)
    print('SwiftPM input timestamps: {} {} files'.format(args.operation, count))


if __name__ == '__main__':
    main()
