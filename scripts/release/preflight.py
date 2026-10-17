#!/usr/bin/env python3
"""Fail before signing or publishing when release configuration is incomplete."""
import ipaddress
import json
import os
from pathlib import Path
import sys
from urllib.parse import urlparse
from urllib.request import Request, urlopen
from version import parse

mode = sys.argv[1]
parse(os.environ.get('RELEASE_TAG', ''))
required = ['APPLE_TEAM_ID', 'P12_BASE64', 'P12_PASSWORD', 'ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_KEY_BASE64', 'AFK_RELAY_URL']
if mode == 'ios':
    required += ['IOS_PROFILE_BASE64']
missing = [key for key in required if not os.environ.get(key)]
if missing:
    sys.exit('Missing release configuration: ' + ', '.join(missing))
url = urlparse(os.environ['AFK_RELAY_URL'])
if url.scheme != 'https' or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ('', '/'):
    sys.exit('AFK_RELAY_URL must be an HTTPS origin without credentials.')
try:
    local = not ipaddress.ip_address(url.hostname).is_global
except ValueError:
    local = url.hostname == 'localhost' or url.hostname.endswith('.localhost')
if local:
    sys.exit('Release builds require a reachable relay, not localhost.')
# Do not upload an app with a missing/empty icon catalog.
catalog = Path('apps/apple/Resources/Assets.xcassets/AppIcon.appiconset')
if not (catalog / 'Contents.json').is_file():
    sys.exit('Missing AppIcon asset catalog. Add the approved AFK icon before distribution.')
images = json.loads((catalog / 'Contents.json').read_text()).get('images', [])
idiom = 'mac' if mode == 'mac' else 'universal'
if not any(item.get('idiom') == idiom and item.get('filename') and (catalog / item['filename']).is_file() for item in images):
    sys.exit(f'Missing {idiom} AppIcon images.')
if '--check-relay' in sys.argv:
    try:
        request = Request(os.environ['AFK_RELAY_URL'].rstrip('/') + '/readyz', headers={'User-Agent': 'AFK-Release/1.0'})
        with urlopen(request, timeout=15) as response:
            if response.status != 200 or json.load(response).get('ready') is not True:
                sys.exit('Relay readiness failed.')
    except Exception:
        sys.exit('Cannot reach a ready relay over HTTPS. Check AFK_RELAY_URL, DNS and PostgreSQL.')
print('Release configuration present. Apple will validate credentials during signing/upload.')
