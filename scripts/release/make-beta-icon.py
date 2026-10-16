#!/usr/bin/env python3
"""Generate Apple icon sizes from the shared retro keyboard artwork (macOS sips)."""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
source = root / 'apps/apple/Artwork/retro-keyboard.png'
catalog = root / 'apps/apple/Resources/Assets.xcassets'
icons = catalog / 'AppIcon.appiconset'
icons.mkdir(parents=True, exist_ok=True)
entries = []


def resize(filename, size):
    subprocess.run(['sips', '-z', str(size), str(size), str(source),
                    '--out', str(icons / filename)], check=True, stdout=subprocess.DEVNULL)


for points in [16, 32, 128, 256, 512]:
    for scale in [1, 2]:
        filename = f'mac-{points}@{scale}x.png'
        resize(filename, points * scale)
        entries.append(dict(idiom='mac', size=f'{points}x{points}', scale=f'{scale}x', filename=filename))
resize('ios-1024.png', 1024)
entries.append(dict(idiom='universal', platform='ios', size='1024x1024', filename='ios-1024.png'))
info = dict(author='xcode', version=1)
(catalog / 'Contents.json').write_text(json.dumps(dict(info=info), indent=2)+'\n')
(icons / 'Contents.json').write_text(json.dumps(dict(images=entries, info=info), indent=2)+'\n')
