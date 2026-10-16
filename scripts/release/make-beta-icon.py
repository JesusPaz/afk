#!/usr/bin/env python3
"""Provisional AFK pixel wordmark, generated without third-party dependencies."""
import json
from pathlib import Path
import struct
import zlib

catalog = Path('apps/apple/Resources/Assets.xcassets')
icons = catalog / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
glyphs = ['01110 11111 10001', '11011 11000 10010', '11011 11000 10100',
          '11111 11110 11000', '11011 11000 10100', '11011 11000 10010', '11011 11000 10001']


def png(size):
    unit = size / 23
    left, top = (size - 17 * unit) / 2, (size - 7 * unit) / 2
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            col, row = int((x-left)//unit), int((y-top)//unit)
            on = 0 <= row < 7 and 0 <= col < 17 and glyphs[row][col] == '1'
            rows.extend((255, 255, 255) if on else (10, 107, 237))
    def chunk(kind, data):
        return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind+data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('!2I5B', size, size, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


entries = []
for points in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        filename = f'mac-{points}@{scale}x.png'
        (icons / filename).write_bytes(png(points * scale))
        entries.append(dict(idiom='mac', size=f'{points}x{points}', scale=f'{scale}x', filename=filename))
(icons / 'ios-1024.png').write_bytes(png(1024))
entries.append(dict(idiom='universal', platform='ios', size='1024x1024', filename='ios-1024.png'))
info = dict(author='xcode', version=1)
(catalog / 'Contents.json').write_text(json.dumps(dict(info=info), indent=2)+'\n')
(icons / 'Contents.json').write_text(json.dumps(dict(images=entries, info=info), indent=2)+'\n')
