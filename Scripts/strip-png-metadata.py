#!/usr/bin/env python3
"""Remove PNG text, EXIF and timestamp chunks without changing image pixels."""
from pathlib import Path
import struct
import sys
import zlib

PRIVATE_METADATA = {b'eXIf', b'tEXt', b'zTXt', b'iTXt', b'tIME'}


def clean(path: Path) -> None:
    data = path.read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f'Not a PNG: {path.name}')
    output = bytearray(data[:8])
    position = 8
    ended = False
    while position < len(data):
        if position + 12 > len(data):
            raise ValueError(f'Truncated PNG: {path.name}')
        length = struct.unpack_from('>I', data, position)[0]
        end = position + length + 12
        if end > len(data):
            raise ValueError(f'Truncated PNG chunk: {path.name}')
        kind = data[position + 4:position + 8]
        payload = data[position + 4:end - 4]
        crc = struct.unpack_from('>I', data, end - 4)[0]
        if zlib.crc32(payload) & 0xffffffff != crc:
            raise ValueError(f'Invalid PNG checksum: {path.name}')
        if kind not in PRIVATE_METADATA:
            output.extend(data[position:end])
        position = end
        if kind == b'IEND':
            ended = True
            break
    if not ended or position != len(data):
        raise ValueError(f'Invalid PNG ending: {path.name}')
    if output != data:
        path.write_bytes(output)


if __name__ == '__main__':
    for filename in sys.argv[1:]:
        clean(Path(filename))
